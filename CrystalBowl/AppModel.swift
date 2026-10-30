import SwiftUI
import RealityKit
import UIKit

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case home, capturing, reconstructing }
    enum CaptureStage { case initializing, ready, detecting, capturing, finishing, completed, failed }

    @Published var phase: Phase = .home
    @Published var scans: [Scan] = []
    @Published var path: [Scan] = []
    @Published var errorMessage: String?

    // Capture
    @Published var captureSession: ObjectCaptureSession?
    @Published var captureStage: CaptureStage = .initializing
    @Published var passCompleted = false
    @Published var passNumber = 1
    @Published var shotCount = 0
    @Published var feedbackText: String?

    // Google Drive
    @Published var driveSignedIn = false
    @Published var driveEmail: String?
    @Published var isSyncing = false
    @Published var driveStatus: [String: String] = [:]

    // Updates
    @Published var latestRemote: RemoteVersion?
    @Published var lastUpdateCheck: Date?

    // Reconstruction
    @Published var repairing: Set<String> = []
    @Published var progress: Double = 0
    @Published var progressNote = ""

    let guide = CaptureGuide()

    private(set) var currentScan: Scan?
    private var pollTask: Task<Void, Never>?
    private var cancelling = false

    var isCaptureSupported: Bool { ObjectCaptureSession.isSupported }

    init() {
        reload()
        refreshDriveAccount()
    }

    func reload() { scans = ScanStore.loadAll() }

    // MARK: Capture

    func startNewScan(name: String) {
        guard isCaptureSupported else {
            errorMessage = "This iPhone can't run 3D object capture. It needs a LiDAR iPhone (12 Pro or later Pro model) on iOS 17 or later."
            return
        }
        do {
            let scan = try ScanStore.create(name: name)
            currentScan = scan
            let session = ObjectCaptureSession()
            var config = ObjectCaptureSession.Configuration()
            config.checkpointDirectory = scan.checkpointURL
            session.start(imagesDirectory: scan.imagesURL, configuration: config)
            captureSession = session
            captureStage = .initializing
            passCompleted = false
            passNumber = 1
            shotCount = 0
            feedbackText = nil
            cancelling = false
            phase = .capturing
            UIApplication.shared.isIdleTimerDisabled = true
            guide.start()
            startPolling(session)
        } catch {
            errorMessage = "Couldn't create the scan folder: \(error.localizedDescription)"
        }
    }

    /// Mirrors the session's state into published properties ten times a second and drives the capture guide.
    private func startPolling(_ session: ObjectCaptureSession) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sync(session)
                if self.captureStage == .completed || self.captureStage == .failed { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func sync(_ session: ObjectCaptureSession) {
        let previous = captureStage
        switch session.state {
        case .initializing: captureStage = .initializing
        case .ready: captureStage = .ready
        case .detecting: captureStage = .detecting
        case .capturing: captureStage = .capturing
        case .finishing: captureStage = .finishing
        case .completed: captureStage = .completed
        case .failed(let error):
            captureStage = .failed
            if previous != .failed { captureFailed(error) }
            return
        @unknown default: break
        }
        let wasCompleted = passCompleted
        passCompleted = session.userCompletedScanPass
        shotCount = session.numberOfShotsTaken
        feedbackText = Self.describe(session.feedback)
        guide.update(shotCount: shotCount, capturing: captureStage == .capturing && !passCompleted, feedback: feedbackText)
        if passCompleted && !wasCompleted { guide.passCompleted() }
        if captureStage == .completed && previous != .completed { captureFinished() }
    }

    static func describe(_ feedback: Set<ObjectCaptureSession.Feedback>) -> String? {
        let text: [String: String] = [
            "objectTooClose": "Move back a little",
            "objectTooFar": "Move closer to the rock",
            "movingTooFast": "Slow down",
            "environmentLowLight": "More light needed",
            "environmentTooDark": "Too dark to scan",
            "outOfFieldOfView": "Keep the rock in view",
            "objectNotFlippable": "This rock may not flip well. Scan it upright again instead",
            "overCapturing": "Enough photos from here. Keep moving",
            "objectNotDetected": "Rock not found. Point at it",
        ]
        let lines = feedback.map { fb -> String in
            let key = String(describing: fb)
            return text[key] ?? key
        }
        return lines.isEmpty ? nil : lines.sorted().joined(separator: " · ")
    }

    func startDetecting() { _ = captureSession?.startDetecting() }
    func resetDetection() { captureSession?.resetDetection() }
    func startCapturing() { captureSession?.startCapturing() }

    func flipAndContinue() {
        captureSession?.beginNewScanPassAfterFlip()
        guide.newPass(flipped: true)
        passNumber += 1
    }

    func anotherPass() {
        captureSession?.beginNewScanPass()
        guide.newPass(flipped: false)
        passNumber += 1
    }

    func finishCapture() { captureSession?.finish() }

    func cancelCapture() {
        cancelling = true
        captureSession?.cancel()
        endCapture()
        if let scan = currentScan { ScanStore.delete(scan) }
        currentScan = nil
        phase = .home
        reload()
    }

    private func endCapture() {
        pollTask?.cancel()
        pollTask = nil
        captureSession = nil
        guide.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func captureFailed(_ error: Error) {
        endCapture()
        if cancelling { return }
        errorMessage = "Capture stopped: \(error.localizedDescription). Photos taken so far are kept, and you can build a model from them in the scan list."
        if var scan = currentScan {
            scan.photoCount = ScanStore.countPhotos(in: scan.imagesURL)
            try? ScanStore.save(scan)
        }
        phase = .home
        reload()
    }

    private func captureFinished() {
        endCapture()
        guard var scan = currentScan else { phase = .home; return }
        scan.photoCount = ScanStore.countPhotos(in: scan.imagesURL)
        scan.passes = passNumber
        scan.coverage = guide.bandCoverage
        try? ScanStore.save(scan)
        currentScan = scan
        reconstruct(scan)
    }

    // MARK: Reconstruction

    func reconstruct(_ scan: Scan) {
        guard PhotogrammetrySession.isSupported else {
            errorMessage = "This iPhone can't build 3D models on the device."
            return
        }
        currentScan = scan
        phase = .reconstructing
        progress = 0
        progressNote = "Preparing \(ScanStore.countPhotos(in: scan.imagesURL)) photos…"
        UIApplication.shared.isIdleTimerDisabled = true
        Task { [weak self] in
            await self?.runReconstruction(scan)
        }
    }

    private func runReconstruction(_ scan: Scan) async {
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            var config = PhotogrammetrySession.Configuration()
            config.checkpointDirectory = scan.checkpointURL
            // Guided capture saves photos in the order they were taken, which lets matching start from neighbours.
            config.sampleOrdering = .sequential
            let session = try PhotogrammetrySession(input: scan.imagesURL, configuration: config)
            try session.process(requests: [.modelFile(url: scan.modelURL)])
            var failure: Error?
            // The outputs stream stays open after the last request finishes, so leave it on
            // processingComplete; waiting for the stream to end hangs at 100%.
            outputs: for try await output in session.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    progress = fraction
                    progressNote = "Building the model… \(Int(fraction * 100))%"
                case .requestError(_, let error):
                    failure = error
                case .processingCancelled:
                    failure = NSError(domain: "CrystalBowl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Processing was cancelled"])
                    break outputs
                case .processingComplete:
                    break outputs
                default:
                    break
                }
            }
            if let failure { throw failure }
            guard FileManager.default.fileExists(atPath: scan.modelURL.path) else {
                throw NSError(domain: "CrystalBowl", code: 2, userInfo: [NSLocalizedDescriptionKey: "No model file was produced"])
            }
            progressNote = "Measuring…"
            var done = scan
            let url = scan.modelURL
            done.stats = await Task.detached { MeshTools.measure(url) }.value
            if done.photoCount == nil { done.photoCount = ScanStore.countPhotos(in: scan.imagesURL) }
            progressNote = "Cutting cross-sections and the height profile…"
            done.sections = await Self.cutStacks(done, specs: [(0, AppModel.defaultSpacingMM), (3, AppModel.defaultSpacingMM)])
            // Lab formats are written straight away so sharing and the Drive upload are ready when the scan opens.
            progressNote = "Writing STL, PLY and OBJ…"
            let finished = done
            _ = await Task.detached { MeshTools.exportAll(finished) }.value
            // Photos waiting for a Drive upload are deleted after that upload instead.
            let photosGoToDrive = uploadPhotos && driveSignedIn
            if !UserDefaults.standard.bool(forKey: AppModel.keepPhotosKey) && !photosGoToDrive {
                ScanStore.deletePhotos(done)
            }
            try? ScanStore.save(done)
            reload()
            phase = .home
            path = [done]
            Task { await syncAllPending() }
        } catch {
            errorMessage = "Building the model failed: \(error.localizedDescription). Your photos are kept. Open the scan and tap Build model to try again."
            reload()
            phase = .home
        }
    }

    /// Measures a scan whose model was built but never measured (version 1.3 could stop at 100% after writing it).
    func measure(_ scan: Scan) async {
        var done = scan
        let url = scan.modelURL
        done.stats = await Task.detached { MeshTools.measure(url) }.value
        try? ScanStore.save(done)
        reload()
    }

    /// Stores a caliper measurement of one principal axis; measurements and the report then show the corrected scale.
    func setCaliper(_ scan: Scan, axis: Int, measuredMM: Double?) {
        var updated = scans.first { $0.id == scan.id } ?? scan
        updated.caliper = measuredMM.map { CaliperCheck(axis: axis, measuredMM: $0, date: Date()) }
        try? ScanStore.save(updated)
        if updated.hasModel {
            let s = updated
            _ = MeshTools.writeReport(s)
        }
        reload()
        Task { await syncAllPending() }
    }

    static let keepPhotosKey = "keepPhotos"
    static let defaultSpacingMM = 2.0

    /// Cuts a new stack of cross-sections and stores it on the scan.
    func makeSections(_ scan: Scan, axis: Int, spacingMM: Double) async {
        do {
            let series = try await Task.detached {
                try CrossSectionMaker.make(scan: scan, axis: axis, spacingMM: spacingMM)
            }.value
            var updated = scans.first { $0.id == scan.id } ?? scan
            var list = (updated.sections ?? []).filter { $0.id != series.id }
            list.insert(series, at: 0)
            updated.sections = list
            try ScanStore.save(updated)
            reload()
            Task { await syncAllPending() }
        } catch {
            errorMessage = "Couldn't cut cross-sections: \(error.localizedDescription)"
        }
    }

    /// Cuts each (axis, spacing) stack in turn; stacks that fail are left out.
    static func cutStacks(_ scan: Scan, specs: [(Int, Double)]) async -> [SectionSeries] {
        var made: [SectionSeries] = []
        for (axis, spacing) in specs {
            let s = scan
            if let series = try? await Task.detached(operation: {
                try CrossSectionMaker.make(scan: s, axis: axis, spacingMM: spacing)
            }).value {
                made.append(series)
            }
        }
        return made
    }

    var scansNeedingRepair: [Scan] { scans.filter { $0.needsRepair } }

    /// Brings an older scan up to date from its saved model: measures again (now with the upright size),
    /// re-cuts every stack with the current slicer plus a height profile, rewrites the lab files and report,
    /// and uploads the result. Photos are not needed.
    func repair(_ original: Scan) async {
        guard original.hasModel, !repairing.contains(original.id) else { return }
        repairing.insert(original.id)
        defer { repairing.remove(original.id) }
        var scan = scans.first { $0.id == original.id } ?? original
        let url = scan.modelURL
        guard let stats = await Task.detached(operation: { MeshTools.measure(url) }).value else {
            errorMessage = "Couldn't read the model of \"\(scan.name)\" to repair it."
            return
        }
        scan.stats = stats
        var specs = (scan.sections ?? []).map { ($0.axis, $0.spacingMM) }
        if !specs.contains(where: { $0.0 == 0 }) { specs.insert((0, Self.defaultSpacingMM), at: 0) }
        if !specs.contains(where: { $0.0 == 3 }) { specs.append((3, Self.defaultSpacingMM)) }
        scan.sections = await Self.cutStacks(scan, specs: specs)
        try? ScanStore.save(scan)
        let done = scan
        _ = await Task.detached { MeshTools.exportAll(done) }.value
        reload()
        Task { await syncAllPending() }
    }

    func repairAll() async {
        for scan in scansNeedingRepair { await repair(scan) }
    }

    func delete(_ scan: Scan) {
        ScanStore.delete(scan)
        path.removeAll { $0.id == scan.id }
        reload()
    }
}
