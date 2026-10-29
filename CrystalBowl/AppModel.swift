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

    // Reconstruction
    @Published var progress: Double = 0
    @Published var progressNote = ""

    private(set) var currentScan: Scan?
    private var pollTask: Task<Void, Never>?
    private var cancelling = false

    var isCaptureSupported: Bool { ObjectCaptureSession.isSupported }

    init() { reload() }

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
            startPolling(session)
        } catch {
            errorMessage = "Couldn't create the scan folder: \(error.localizedDescription)"
        }
    }

    /// Mirrors the session's state into published properties a few times a second.
    private func startPolling(_ session: ObjectCaptureSession) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sync(session)
                if self.captureStage == .completed || self.captureStage == .failed { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
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
        passCompleted = session.userCompletedScanPass
        shotCount = session.numberOfShotsTaken
        feedbackText = Self.describe(session.feedback)
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
        passNumber += 1
    }

    func anotherPass() {
        captureSession?.beginNewScanPass()
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
            let session = try PhotogrammetrySession(input: scan.imagesURL, configuration: config)
            try session.process(requests: [.modelFile(url: scan.modelURL)])
            var failure: Error?
            for try await output in session.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    progress = fraction
                    progressNote = "Building the model… \(Int(fraction * 100))%"
                case .requestError(_, let error):
                    failure = error
                case .processingCancelled:
                    failure = NSError(domain: "CrystalBowl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Processing was cancelled"])
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
            progressNote = "Cutting cross-sections…"
            let measured = done
            if let series = try? await Task.detached(operation: {
                try CrossSectionMaker.make(scan: measured, axis: 0, spacingMM: AppModel.defaultSpacingMM)
            }).value {
                done.sections = [series]
            }
            if !UserDefaults.standard.bool(forKey: AppModel.keepPhotosKey) {
                ScanStore.deletePhotos(done)
            }
            try? ScanStore.save(done)
            reload()
            phase = .home
            path = [done]
        } catch {
            errorMessage = "Building the model failed: \(error.localizedDescription). Your photos are kept. Open the scan and tap Build model to try again."
            reload()
            phase = .home
        }
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
        } catch {
            errorMessage = "Couldn't cut cross-sections: \(error.localizedDescription)"
        }
    }

    func delete(_ scan: Scan) {
        ScanStore.delete(scan)
        path.removeAll { $0.id == scan.id }
        reload()
    }
}
