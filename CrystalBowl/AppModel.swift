import SwiftUI
import RealityKit
import UIKit
import ScanMath

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case home, capturing }
    enum Tab: Hashable { case scan, ar }
    enum CaptureStage { case initializing, ready, detecting, capturing, finishing, completed, failed }

    @Published var phase: Phase = .home
    @Published var scans: [Scan] = []
    @Published var path: [Scan] = []
    @Published var errorMessage: String?

    // Main tabs: scanning, and AR view of finished scans
    @Published var tab: Tab = .scan
    @Published var arSelection: Set<String> = []
    /// Older scans getting the newer extras added (shape, sample sheet, ruled sections).
    @Published var upgradeNote: String?
    var upgrading = false

    // Capture
    @Published var captureSession: ObjectCaptureSession?
    @Published var captureStage: CaptureStage = .initializing
    @Published var passCompleted = false
    @Published var passNumber = 1
    @Published var shotCount = 0
    @Published var feedbackText: String?
    /// Photos the app asked for itself on empty sectors (Object Capture had skipped them).
    @Published var requestedShots = 0
    @Published var lightOn = false
    /// The user switched the light off, so it isn't turned on again by itself during this scan.
    private var lightDeclined = false
    private var darkSince: Date?

    // Google Drive
    @Published var driveSignedIn = false
    @Published var driveEmail: String?
    @Published var isSyncing = false
    @Published var driveStatus: [String: String] = [:]

    // Updates
    @Published var latestRemote: RemoteVersion?
    @Published var lastUpdateCheck: Date?

    // Building (one scan at a time, in the background)
    @Published var repairing: Set<String> = []
    @Published var buildingID: String?
    @Published var progress: Double = 0
    @Published var progressNote = ""
    @Published var readyNotice: ReadyNotice?
    /// Blurred photos found on the current side during capture.
    @Published var blurryShots = 0
    @Published var quickCapture = false

    // Drive folder chosen through the Files app
    @Published var folderLinked = false
    @Published var folderName: String?
    @Published var folderStatus: [String: String] = [:]
    var isFolderSyncing = false

    let guide = CaptureGuide()

    private(set) var currentScan: Scan?
    private var pollTask: Task<Void, Never>?
    private var cancelling = false
    private var buildQueue: [String] = []
    private var photoSession: PhotogrammetrySession?
    private var backgroundedDuringBuild = false
    private var shotScores: [String: Double] = [:]
    private var scoringShots = false
    private var pollCount = 0

    var isCaptureSupported: Bool { ObjectCaptureSession.isSupported }

    /// The one model of the running app; background upload callbacks reach it through this.
    static weak var current: AppModel?

    init() {
        reload()
        refreshDriveAccount()
        refreshFolderLink()
        AppModel.current = self
        // When iOS launches the app in the background only to finish uploads, builds wait until it is opened.
        if UIApplication.shared.applicationState != .background { resumePendingBuilds() }
    }

    func reload() { scans = ScanStore.loadAll() }

    // MARK: Capture

    func startNewScan(name: String, quick: Bool) {
        guard isCaptureSupported else {
            errorMessage = "This iPhone can't run 3D object capture. It needs a LiDAR iPhone (12 Pro or later Pro model) on iOS 17 or later."
            return
        }
        do {
            var scan = try ScanStore.create(name: name)
            scan.quick = quick
            try? ScanStore.save(scan)
            currentScan = scan
            quickCapture = quick
            shotScores = [:]
            blurryShots = 0
            pollCount = 0
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
            requestedShots = 0
            lightOn = false
            lightDeclined = false
            darkSince = nil
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
        if guide.wantsShot && session.canRequestImageCapture {
            session.requestImageCapture()
            requestedShots += 1
        }
        if captureStage == .capturing || captureStage == .detecting { autoLight(session.feedback) }
        if passCompleted && !wasCompleted {
            guide.passCompleted()
            markBlurryOnRing()
        }
        pollCount += 1
        if pollCount % 15 == 0 && captureStage == .capturing && !passCompleted { checkNewShots() }
        if captureStage == .completed && previous != .completed { captureFinished() }
    }

    static func describe(_ feedback: Set<ObjectCaptureSession.Feedback>) -> String? {
        let text: [String: String] = [
            "objectTooClose": "Move back a little",
            "objectTooFar": "Move closer to the rock (the 3D camera doesn't zoom: zoom would spoil the true size)",
            "movingTooFast": "Slow down",
            "environmentLowLight": "Low light: the phone's light is coming on. More room light is better still",
            "environmentTooDark": "Too dark: turn on a lamp or tap the light button",
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

    /// Scores new photos about every 1.5 s; a clearly blurred one gets an immediate buzz and hint.
    private func checkNewShots() {
        guard !scoringShots, let scan = currentScan else { return }
        scoringShots = true
        let dir = scan.imagesURL
        let known = Set(shotScores.keys)
        Task { [weak self] in
            let fresh = await Task.detached { ShotQuality.scoreNew(in: dir, known: known) }.value
            guard let self else { return }
            self.scoringShots = false
            guard !fresh.isEmpty else { return }
            self.shotScores.merge(fresh) { a, _ in a }
            guard self.shotScores.count >= 8 else { return }
            let m = ScanMath.median(Array(self.shotScores.values))
            if fresh.values.contains(where: { $0 < ShotQuality.blurRatio * m }) { self.guide.flagBlurry() }
        }
    }

    /// After a pass, blurred photos no longer count as coverage, so their spots show up as gaps to fill.
    private func markBlurryOnRing() {
        guard let scan = currentScan else { return }
        let dir = scan.imagesURL
        let known = Set(shotScores.keys)
        Task { [weak self] in
            let fresh = await Task.detached { ShotQuality.scoreNew(in: dir, known: known, limit: 2000) }.value
            let ordered = await Task.detached { ShotQuality.photos(in: dir).map { $0.lastPathComponent } }.value
            guard let self else { return }
            self.shotScores.merge(fresh) { a, _ in a }
            let values = ordered.map { self.shotScores[$0] ?? .nan }
            let bad = ScanMath.blurryIndices(values, relative: ShotQuality.blurRatio, maxFraction: ShotQuality.maxSetAside)
            self.blurryShots = self.guide.markBlurry(global: Set(bad), photoCount: ordered.count)
        }
    }

    /// Shutter button: a photo from exactly here, whatever Object Capture thinks it already has.
    func takePhotoNow() {
        guard let s = captureSession, s.canRequestImageCapture else { return }
        s.requestImageCapture()
        requestedShots += 1
    }

    func toggleLight() {
        let on = !lightOn
        if CameraAssist.setLight(on) { lightOn = on }
        if !on { lightDeclined = true }
    }

    /// In poor light the phone's light comes on softly by itself after a moment (once per scan; the user can turn it off).
    private func autoLight(_ feedback: Set<ObjectCaptureSession.Feedback>) {
        let keys = Set(feedback.map { String(describing: $0) })
        let dark = keys.contains("environmentLowLight") || keys.contains("environmentTooDark")
        guard dark else { darkSince = nil; return }
        if darkSince == nil { darkSince = Date() }
        if !lightOn && !lightDeclined, let since = darkSince, Date().timeIntervalSince(since) > 1.5, CameraAssist.setLight(true) {
            lightOn = true
        }
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
        if lightOn { CameraAssist.setLight(false) }
        lightOn = false
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
        scan.buildRequested = true
        scan.buildAttempts = 0
        ShotQuality.saveScores(shotScores, for: scan)
        try? ScanStore.save(scan)
        currentScan = nil
        phase = .home
        reload()
        path = [scan]
        reconstruct(scan)
    }

    // MARK: Building the model (in the background)

    /// Queues a scan for building. The build runs while the app is used for anything else, and continues
    /// in the background when the user switches apps or locks the phone (see BackgroundBuild). If iOS stops it,
    /// it resumes from its checkpoint the next time the app is opened.
    func reconstruct(_ scan: Scan) {
        guard PhotogrammetrySession.isSupported else {
            errorMessage = "This iPhone can't build 3D models on the device."
            return
        }
        var s = scans.first { $0.id == scan.id } ?? scan
        if s.buildRequested != true {
            s.buildRequested = true
            s.buildAttempts = 0
            try? ScanStore.save(s)
            reload()
        }
        Notifier.requestPermission()
        enqueue(s.id)
    }

    /// Restarts builds that were interrupted (app closed, phone restarted, iOS took the background time back).
    func resumePendingBuilds() {
        for s in scans where s.buildRequested == true && (s.hasPhotos || s.hasModel) { enqueue(s.id) }
    }

    func appMovedToBackground() {
        if buildingID != nil { backgroundedDuringBuild = true }
        if driveSignedIn && scans.contains(where: { $0.hasModel && $0.drive?.complete != true }) {
            AppDelegate.scheduleUploadTask()
        }
    }

    var pendingBuilds: [Scan] { scans.filter { $0.buildRequested == true && $0.id != buildingID } }

    private func enqueue(_ id: String) {
        if buildingID != id && !buildQueue.contains(id) { buildQueue.append(id) }
        runNextBuild()
    }

    private func runNextBuild() {
        guard buildingID == nil else { return }
        while !buildQueue.isEmpty {
            let id = buildQueue.removeFirst()
            guard let scan = scans.first(where: { $0.id == id }), scan.buildRequested == true else { continue }
            buildingID = id
            progress = 0
            progressNote = "Preparing…"
            backgroundedDuringBuild = UIApplication.shared.applicationState == .background
            BackgroundBuild.shared.onExpire = { [weak self] in self?.photoSession?.cancel() }
            BackgroundBuild.shared.begin(title: "Building \(scan.name)")
            Task { [weak self] in
                await self?.runBuild(scan)
                self?.buildingID = nil
                self?.photoSession = nil
                self?.runNextBuild()
            }
            return
        }
    }

    private func setProgress(_ fraction: Double, _ note: String) {
        progress = fraction
        progressNote = note
        BackgroundBuild.shared.update(fraction: fraction, note: note)
    }

    private func runBuild(_ original: Scan) async {
        var scan = original
        scan.buildAttempts = (scan.buildAttempts ?? 0) + 1
        try? ScanStore.save(scan)
        do {
            if !scan.hasModel {
                if scan.blurrySetAside == nil {
                    setProgress(0, "Checking the photos for blur…")
                    let s = scan
                    scan.blurrySetAside = await Task.detached { ShotQuality.setAsideBlurry(s) }.value
                    try? ScanStore.save(scan)
                }
                try await photogrammetry(scan)
            }
            setProgress(0.9, "Measuring…")
            let url = scan.modelURL
            guard let stats = await Task.detached(operation: { MeshTools.measure(url) }).value else {
                throw NSError(domain: "CrystalBowl", code: 3, userInfo: [NSLocalizedDescriptionKey: "The model file couldn't be read"])
            }
            scan.stats = stats
            if scan.photoCount == nil { scan.photoCount = ScanStore.countPhotos(in: scan.imagesURL) }
            inheritCaliper(&scan)
            try? ScanStore.save(scan)
            reload()
            announceDimensions(scan)

            setProgress(0.93, "Cutting cross-sections and the height profile…")
            scan.sections = await Self.cutStacks(scan, specs: [(0, AppModel.defaultSpacingMM), (3, AppModel.defaultSpacingMM)])
            scan.sectionsRuled = true
            setProgress(0.97, "Writing STL, PLY and OBJ…")
            let finished = scan
            _ = await Task.detached { MeshTools.exportAll(finished) }.value
            scan.buildRequested = nil
            // Photos waiting for a Drive upload are deleted after that upload instead.
            let photosGoToDrive = uploadPhotos && (driveSignedIn || folderLinked)
            if !UserDefaults.standard.bool(forKey: AppModel.keepPhotosKey) && !photosGoToDrive {
                ScanStore.deletePhotos(scan)
            }
            try? ScanStore.save(scan)
            reload()
            setProgress(1, "Done")
            BackgroundBuild.shared.end(success: true)
            Task { await upgradeScans() } // shape fit and sample sheet for the new scan
            Notifier.post(id: "built-\(scan.id)", title: "\(scan.name): 3D model ready",
                          body: "Model, lab files and slices are saved\(driveSignedIn || folderLinked ? " and going to Google Drive" : "").")
            Task { await syncAllPending() }
        } catch {
            BackgroundBuild.shared.end(success: false)
            let interrupted = backgroundedDuringBuild || BackgroundBuild.shared.expired || UIApplication.shared.applicationState != .active
            if interrupted && (scan.buildAttempts ?? 0) < 8 {
                // Still requested: it resumes from the checkpoint as soon as the app is in front again.
                try? ScanStore.save(scan)
                Notifier.post(id: "paused-\(scan.id)", title: "\(scan.name): build paused",
                              body: "iOS paused the 3D build while the phone was busy. Open Crystal Bowl and it carries on from where it stopped.")
                if UIApplication.shared.applicationState == .active { buildQueue.append(scan.id) }
            } else if (scan.blurrySetAside ?? 0) > 0 {
                // Try once more with every photo.
                ShotQuality.restoreBlurry(scan)
                scan.blurrySetAside = 0
                try? ScanStore.save(scan)
                buildQueue.append(scan.id)
            } else {
                scan.buildRequested = nil
                try? ScanStore.save(scan)
                errorMessage = "Building the model of \"\(scan.name)\" failed: \(error.localizedDescription). Your photos are kept. Open the scan and tap Build model to try again."
            }
            reload()
        }
    }

    private func photogrammetry(_ scan: Scan) async throws {
        setProgress(0.01, "Preparing \(ScanStore.countPhotos(in: scan.imagesURL)) photos…")
        var config = PhotogrammetrySession.Configuration()
        config.checkpointDirectory = scan.checkpointURL
        // Guided capture saves photos in the order they were taken, which lets matching start from neighbours.
        config.sampleOrdering = .sequential
        let session = try PhotogrammetrySession(input: scan.imagesURL, configuration: config)
        photoSession = session
        try session.process(requests: [.modelFile(url: scan.modelURL)])
        var failure: Error?
        // The outputs stream stays open after the last request finishes, so leave it on
        // processingComplete; waiting for the stream to end hangs at 100%.
        outputs: for try await output in session.outputs {
            switch output {
            case .requestProgress(_, let fraction):
                setProgress(fraction * 0.88, "Building the model… \(Int(fraction * 100))%")
            case .requestError(_, let error):
                failure = error
            case .processingCancelled:
                failure = NSError(domain: "CrystalBowl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Processing was stopped"])
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
    }

    /// The first result the user is waiting for: enough to centre the rock in the micro-CT.
    private func announceDimensions(_ scan: Scan) {
        guard let u = scan.stats?.upright else { return }
        let f = scan.scaleFactor
        let text = String(format: "Height %.1f mm · footprint %.1f × %.1f mm · fits a cylinder Ø %.1f mm",
                          u.heightMM * f, u.lengthMM * f, u.widthMM * f, (u.cylinderDiameterMM ?? u.maxDiameterMM) * f)
        readyNotice = ReadyNotice(id: scan.id, name: scan.name, text: text)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Notifier.post(id: "dims-\(scan.id)", title: "\(scan.name): dimensions ready",
                      body: text + ". Enough to centre it in the micro-CT. The full model is still being finished.")
    }

    /// A scan of a sample that was caliper-checked before takes over that check, so repeat scans share one scale.
    /// The default name "Rock sample" is never matched, since it may be any rock.
    private func inheritCaliper(_ scan: inout Scan) {
        guard scan.caliper == nil, scan.sampleKey != "rock sample" else { return }
        let earlier = scans.filter { $0.id != scan.id && $0.sampleKey == scan.sampleKey && $0.caliper != nil }
            .sorted { ($0.caliper?.date ?? .distantPast) > ($1.caliper?.date ?? .distantPast) }
        guard let source = earlier.first, var c = source.caliper else { return }
        c.fromScanID = c.fromScanID ?? source.id
        scan.caliper = c
    }

    /// Scans of the same sample that were measured with the 1.8 method, oldest first.
    func repeats(of scan: Scan) -> [Scan] {
        scans.filter { $0.sampleKey == scan.sampleKey && $0.stats?.box != nil }.sorted { $0.created < $1.created }
    }

    /// One line with the sizes, for pasting into notes or a CT booking.
    func dimensionsText(_ scan: Scan) -> String {
        guard let s = scan.stats else { return "\(scan.name): not measured yet" }
        let f = scan.scaleFactor
        var t = scan.name + String(format: ": a × b × c %.1f × %.1f × %.1f mm", s.axisA * f, s.axisB * f, s.axisC * f)
        if let u = s.upright {
            t += String(format: "; height %.1f mm; footprint %.1f × %.1f mm; micro-CT cylinder Ø %.1f mm",
                        u.heightMM * f, u.lengthMM * f, u.widthMM * f, (u.cylinderDiameterMM ?? u.maxDiameterMM) * f)
        }
        t += String(format: "; volume %.2f cm³", s.volumeCM3 * f * f * f)
        return t + (scan.caliper == nil ? " (LiDAR scale)" : " (caliper-corrected)")
    }

    func rename(_ scan: Scan, to newName: String) {
        let t = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, var s = scans.first(where: { $0.id == scan.id }) else { return }
        if s.storedStem == nil { s.storedStem = s.fileStem }
        s.name = t
        try? ScanStore.save(s)
        if s.hasModel { _ = MeshTools.writeReport(s) }
        reload()
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
        scan.sectionsRuled = true
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
        buildQueue.removeAll { $0 == scan.id }
        if buildingID == scan.id { photoSession?.cancel() }
        ScanStore.delete(scan)
        path.removeAll { $0.id == scan.id }
        reload()
    }
}

struct ReadyNotice: Identifiable, Equatable {
    let id: String
    let name: String
    let text: String
}
