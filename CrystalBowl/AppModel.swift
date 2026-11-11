import SwiftUI
import RealityKit
import UIKit
import ScanMath

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case home, capturing }
    enum Tab: Hashable { case scan, pieces, ar }
    enum CaptureStage { case initializing, ready, detecting, capturing, finishing, completed, failed }

    @Published var phase: Phase = .home
    @Published var scans: [Scan] = []
    @Published var path: [Scan] = []
    @Published var errorMessage: String? {
        didSet { if let m = errorMessage, m != oldValue { AppLog.error("alert", "Shown to the user: \(m)") } }
    }

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
    @Published var buildingID: String? {
        // The screen stays on while a model builds: an iPhone pauses the build when it locks.
        didSet { UIApplication.shared.isIdleTimerDisabled = buildingID != nil || phase == .capturing }
    }
    /// Shown on screen after iOS paused a build (phone locked or another app opened).
    @Published var buildPausedNote: String?
    private var buildStarted = Date()
    private var loggedStage = ""
    private var loggedTenth = -1
    @Published var progress: Double = 0
    @Published var progressNote = ""
    @Published var readyNotice: ReadyNotice?
    /// Blurred photos found on the current side during capture.
    @Published var blurryShots = 0
    @Published var quickCapture = false
    /// Capturing broken pieces (no flipping inside one capture: every piece is turned over between two captures).
    @Published var piecesCapture = false
    /// 1 or 2: which side of the pieces is being captured.
    @Published var captureSide = 1

    // Drive folder chosen through the Files app
    @Published var folderLinked = false
    @Published var folderName: String?
    @Published var folderStatus: [String: String] = [:]
    var isFolderSyncing = false
    var uploadingLog = false
    /// Photos in the capture folder before this capture started, and the count on disk last seen.
    var photosBefore = 0
    var photoFiles: Int?
    var lastRefusalLog = Date.distantPast
    /// The rock was flipped during this capture, so the underside was photographed.
    var flippedThisCapture = false
    var logUploadScheduled = false
    var savingToPhotos = false
    @Published var photosNote: String?
    /// Close-ups opened by themselves after a "dimensions + detail" capture, while the rock is still in place (3.13).
    @Published var detailAfterCapture: Scan?
    /// After those close-ups: offer to scan the rock upside down as its own, linked scan (3.13).
    @Published var offerUpsideDown: Scan?
    /// Short message across the top of the screen (screen saved for a report, …).
    @Published var toast: String?
    /// A new pass was asked for; Object Capture's "pass completed" flag is ignored until it clears (3.13).
    var newPassAsked: Date?
    var newPassRetried = false
    var lastPassDiagnostic = Date.distantPast

    let guide = CaptureGuide()

    var currentScan: Scan?
    private var pollTask: Task<Void, Never>?
    private var cancelling = false
    var buildQueue: [String] = []
    var photoSession: PhotogrammetrySession?
    var backgroundedDuringBuild = false
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
            piecesCapture = false
            captureSide = 1
            beginCapture(scan, images: scan.imagesURL, checkpoint: scan.checkpointURL, quick: quick)
        } catch {
            errorMessage = "Couldn't create the scan folder: \(error.localizedDescription)"
        }
    }

    /// The same rock turned upside down, as a scan of its own linked to the first one (3.13). The two can be kept
    /// apart or merged later on the computer.
    func startUpsideDownScan(of original: Scan) {
        guard isCaptureSupported else { return }
        do {
            var scan = try ScanStore.create(name: original.name)
            scan.quick = original.quick
            scan.pairedScanID = original.id
            scan.orientation = "upside_down"
            try? ScanStore.save(scan)
            if var first = scans.first(where: { $0.id == original.id }) {
                first.pairedScanID = scan.id
                if first.orientation == nil { first.orientation = "upright" }
                try? ScanStore.save(first)
            }
            AppLog.info("capture", "Upside-down scan of \(original.name) (\(original.id)) started as \(scan.id)", scan: scan)
            piecesCapture = false
            captureSide = 1
            beginCapture(scan, images: scan.imagesURL, checkpoint: scan.checkpointURL, quick: original.quick ?? false)
        } catch {
            errorMessage = "Couldn't create the scan folder: \(error.localizedDescription)"
        }
    }

    /// Broken pieces: all of them in one capture, spread out on a table or in a dish.
    func startPiecesScan(name: String, target: TargetShape) {
        guard isCaptureSupported else {
            errorMessage = "This iPhone can't run 3D object capture. It needs a LiDAR iPhone (12 Pro or later Pro model) on iOS 17 or later."
            return
        }
        do {
            var scan = try ScanStore.create(name: name.isEmpty ? "Broken pieces" : name)
            scan.kind = "pieces"
            scan.pieceTarget = target
            try? ScanStore.save(scan)
            piecesCapture = true
            captureSide = 1
            beginCapture(scan, images: scan.imagesURL, checkpoint: scan.checkpointURL, quick: false)
        } catch {
            errorMessage = "Couldn't create the scan folder: \(error.localizedDescription)"
        }
    }

    /// The same pieces after each was turned over where it lay.
    func startSecondSide(_ scan: Scan) {
        guard isCaptureSupported, buildingID != scan.id else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: scan.images2URL)
        try? fm.removeItem(at: scan.checkpoint2URL)
        try? fm.removeItem(at: scan.model2URL)
        try? fm.createDirectory(at: scan.images2URL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: scan.checkpoint2URL, withIntermediateDirectories: true)
        piecesCapture = true
        captureSide = 2
        beginCapture(scan, images: scan.images2URL, checkpoint: scan.checkpoint2URL, quick: false)
    }

    private func beginCapture(_ scan: Scan, images: URL, checkpoint: URL, quick: Bool) {
        currentScan = scan
        quickCapture = quick
        shotScores = [:]
        blurryShots = 0
        pollCount = 0
        let session = ObjectCaptureSession()
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = checkpoint
        session.start(imagesDirectory: images, configuration: config)
        captureSession = session
        captureStage = .initializing
        passCompleted = false
        newPassAsked = nil
        newPassRetried = false
        passNumber = 1
        shotCount = 0
        feedbackText = nil
        requestedShots = 0
        // Photos already in the folder (adding photos to an earlier capture) are not this capture's coverage.
        photosBefore = ShotQuality.photos(in: images).count
        flippedThisCapture = false
        photoFiles = nil
        lightOn = false
        lightDeclined = false
        darkSince = nil
        cancelling = false
        phase = .capturing
        UIApplication.shared.isIdleTimerDisabled = true
        let kind: String = piecesCapture ? "pieces, side \(captureSide)" : (quick ? "dimensions only" : "dimensions + detail")
        AppLog.info("capture", "Capture started: " + kind, scan: scan)
        AppLog.setActivity("capturing \(scan.name)")
        guide.start()
        startPolling(session)
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
        // 3.13: on iOS 27 the "pass completed" flag stayed set after a new pass was started, so the app kept
        // showing the pass summary: no camera view, no shutter, no photos on the gap-filling pass (seen in the
        // log: "2 passes", no photo added). After a new pass is asked for, the flag is ignored until it clears.
        let sessionDone = session.userCompletedScanPass
        if let asked = newPassAsked {
            if !sessionDone {
                newPassAsked = nil
                AppLog.info("capture", "Pass \(passNumber) is running (Object Capture cleared its pass flag after \(String(format: "%.1f", Date().timeIntervalSince(asked))) s)")
            } else if Date().timeIntervalSince(asked) > 3 && !newPassRetried {
                newPassRetried = true
                AppLog.warn("capture", "Object Capture still reports the last pass as done 3 s after pass \(passNumber) was started; asking again (state \(String(describing: session.state)), can take photos \(session.canRequestImageCapture))")
                session.beginNewScanPass()
            }
            passCompleted = false
        } else {
            passCompleted = sessionDone
        }
        if passNumber > 1 && !passCompleted && Date().timeIntervalSince(lastPassDiagnostic) > 10 {
            lastPassDiagnostic = Date()
            AppLog.info("capture", "Pass \(passNumber): \(session.numberOfShotsTaken) photos in the session, files \(photoFiles.map { String($0 - photosBefore) } ?? "?"), can take photos \(session.canRequestImageCapture), pass flag \(sessionDone), state \(String(describing: session.state))")
        }
        feedbackText = Self.describe(session.feedback)
        guide.update(sessionShots: session.numberOfShotsTaken, files: photoFiles.map { max(0, $0 - photosBefore) },
                     capturing: captureStage == .capturing && !passCompleted, feedback: feedbackText)
        shotCount = guide.photoTotal
        if guide.wantsShot {
            if session.canRequestImageCapture {
                session.requestImageCapture()
                requestedShots += 1
                guide.noteRequest(manual: false)
            } else if Date().timeIntervalSince(lastRefusalLog) > 10 {
                lastRefusalLog = Date()
                AppLog.info("capture", "Wanted a photo on an empty spot, but the camera was not ready (canRequestImageCapture false)")
            }
        }
        if captureStage == .capturing || captureStage == .detecting { autoLight(session.feedback) }
        if passCompleted && !wasCompleted {
            guide.passCompleted()
            markBlurryOnRing()
            let cov = guide.bandCoverage.map { Int(($0 * 100).rounded()) }
            AppLog.info("capture", "Pass \(passNumber) done: \(shotCount) photos (session \(session.numberOfShotsTaken), files \(photoFiles.map { String($0 - photosBefore) } ?? "?")), "
                        + "requests \(guide.requestSummary), coverage low/middle/high \(cov[0])/\(cov[1])/\(cov[2]) %, gaps \(guide.gaps().count)", scan: currentScan)
        }
        pollCount += 1
        if pollCount % 15 == 0 && captureStage == .capturing && !passCompleted { checkNewShots() }
        if captureStage == .completed && previous != .completed { captureFinished() }
    }

    static func describe(_ feedback: Set<ObjectCaptureSession.Feedback>) -> String? {
        let text: [String: String] = [
            "objectTooClose": "Move back a little",
            "objectTooFar": "Move a little closer, but stay about 20 cm away: the 3D camera can't focus nearer. Sharp close-ups come next, with the macro lens",
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
        let dir = captureSide == 2 ? scan.images2URL : scan.imagesURL
        let known = Set(shotScores.keys)
        Task { [weak self] in
            let fresh = await Task.detached { ShotQuality.scoreNew(in: dir, known: known) }.value
            let onDisk = await Task.detached { ShotQuality.photos(in: dir).count }.value
            guard let self else { return }
            self.scoringShots = false
            self.photoFiles = onDisk
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
        let dir = captureSide == 2 ? scan.images2URL : scan.imagesURL
        let known = Set(shotScores.keys)
        Task { [weak self] in
            let fresh = await Task.detached { ShotQuality.scoreNew(in: dir, known: known, limit: 2000) }.value
            let ordered = await Task.detached { ShotQuality.photos(in: dir).map { $0.lastPathComponent } }.value
            guard let self else { return }
            self.shotScores.merge(fresh) { a, _ in a }
            // Only this capture's photos (the folder may hold earlier ones when photos are added to a scan).
            let mine = Array(ordered.dropFirst(min(self.photosBefore, ordered.count)))
            let values = mine.map { self.shotScores[$0] ?? .nan }
            let bad = ScanMath.blurryIndices(values, relative: ShotQuality.blurRatio, maxFraction: ShotQuality.maxSetAside)
            self.photoFiles = ordered.count
            self.blurryShots = self.guide.markBlurry(global: Set(bad), photoCount: mine.count)
        }
    }

    /// Shutter button: a photo from exactly here, whatever Object Capture thinks it already has.
    func takePhotoNow() {
        guard let s = captureSession else { return }
        guard s.canRequestImageCapture else {
            AppLog.info("capture", "Shutter tapped, but the camera was not ready")
            guide.noteRequest(manual: true) // counts as ignored, so the advice moves on to stepping back
            return
        }
        s.requestImageCapture()
        requestedShots += 1
        guide.noteRequest(manual: true)
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
        flippedThisCapture = true
        passNumber += 1
        newPassStarted()
    }

    func anotherPass() {
        captureSession?.beginNewScanPass()
        guide.newPass(flipped: false)
        passNumber += 1
        newPassStarted()
    }

    /// Back to the live camera at once: the summary goes away, the shutter and automatic photos are back.
    private func newPassStarted() {
        newPassAsked = Date()
        newPassRetried = false
        passCompleted = false
        if let s = captureSession {
            AppLog.info("capture", "Pass \(passNumber) started (state \(String(describing: s.state)), pass flag \(s.userCompletedScanPass), can take photos \(s.canRequestImageCapture), \(s.numberOfShotsTaken) photos so far)")
        }
    }

    func finishCapture() { captureSession?.finish() }

    func cancelCapture() {
        AppLog.info("capture", "Capture cancelled by the user after \(shotCount) photos")
        cancelling = true
        captureSession?.cancel()
        endCapture()
        if let scan = currentScan {
            if captureSide == 2 {
                try? FileManager.default.removeItem(at: scan.images2URL)
                try? FileManager.default.removeItem(at: scan.checkpoint2URL)
            } else {
                ScanStore.delete(scan)
            }
        }
        captureSide = 1
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
        UIApplication.shared.isIdleTimerDisabled = buildingID != nil
        AppLog.setActivity(buildingID == nil ? "idle" : "building")
    }

    private func captureFailed(_ error: Error) {
        endCapture()
        captureSide = 1
        if cancelling { return }
        AppLog.error("capture", "Capture failed after \(shotCount) photos", error, scan: currentScan)
        errorMessage = "Capture stopped: \(error.localizedDescription). Photos taken so far are kept, and you can build a model from them in the scan list."
        if var scan = currentScan {
            scan.photoCount = ScanStore.countPhotos(in: scan.imagesURL)
            try? ScanStore.save(scan)
        }
        phase = .home
        reload()
    }

    /// A few of this capture's photos, kept as scale photos (3.10), off the main thread.
    private func keepScalePhotos(_ scan: Scan, side: Int) {
        let dir = side == 2 ? scan.images2URL : scan.imagesURL
        let scores = shotScores
        Task.detached(priority: .utility) {
            let files = ScalePhotos.make(scan: scan, from: dir, side: side, scores: scores)
            AppLog.info("capture", "Kept \(files.count) scale photo(s) of side \(side) in model/scale-photos", scan: scan)
            // Did the rock stand out from what it lay on? (3.11) Middle of the photos against their edges.
            let measured = files.compactMap { ScalePhotos.load($0, maxPixel: 400).flatMap { RockTone.measure($0) } }
            guard !measured.isEmpty else { return }
            let rock = RockTone.median(measured.map { $0.rock }), round = RockTone.median(measured.map { $0.surround })
            let tip = MatAdvisor.checkContrast(rockLuma: rock, surroundLuma: round)
            AppLog.info("mat", String(format: "Side %d: rock brightness %.2f, surroundings %.2f%@", side, rock, round,
                                      tip == nil ? " (good contrast)" : ": too alike, tip shown on the scan page"), scan: scan)
            await MainActor.run { self.setMatTip(scan.id, tip: tip, rockLuma: scan.isPieces ? nil : rock) }
        }
    }

    /// Stores the mat advice of a capture. The rock's own brightness from its model, when known, is kept.
    func setMatTip(_ id: String, tip: String?, rockLuma: Double?) {
        guard var s = ScanStore.loadAll().first(where: { $0.id == id }) else { return }
        s.matTip = tip
        if s.rockLuma == nil, let l = rockLuma { s.rockLuma = l }
        try? ScanStore.save(s)
        reload()
    }

    private func captureFinished() {
        endCapture()
        guard var scan = currentScan else { phase = .home; return }
        AppLog.info("capture", "Capture finished: \(shotCount) photos (\(requestedShots) asked for by the app), \(passNumber) pass(es), side \(captureSide), blurred \(blurryShots)", scan: scan)
        keepScalePhotos(scan, side: captureSide)
        if captureSide == 2 {
            scan = scans.first { $0.id == scan.id } ?? scan
            scan.side2PhotoCount = ScanStore.countPhotos(in: scan.images2URL)
            scan.piecesSplit = 3
            scan.buildRequested = true
            scan.buildAttempts = 0
            scan.pauses = 0
            try? ScanStore.save(scan)
            currentScan = nil
            captureSide = 1
            phase = .home
            tab = .pieces
            reload()
            reconstruct(scan)
            return
        }
        scan.photoCount = ScanStore.countPhotos(in: scan.imagesURL)
        scan.passes = passNumber
        scan.coverage = guide.bandCoverage
        if flippedThisCapture { scan.underside = true } else if scan.underside == nil { scan.underside = false }
        if scan.isPieces { scan.piecesSplit = 3 }
        scan.buildRequested = true
        scan.buildAttempts = 0
        scan.pauses = 0
        ShotQuality.saveScores(shotScores, for: scan)
        try? ScanStore.save(scan)
        currentScan = nil
        phase = .home
        reload()
        if scan.isPieces { tab = .pieces } else { path = [scan] }
        reconstruct(scan)
        // 3.13: the close-ups follow straight away, while the rock is still where it was scanned.
        if !scan.isPieces && !quickCapture { detailAfterCapture = scan }
    }

    /// Closing the close-ups that followed a capture: offer the upside-down scan of the same rock.
    func closeDetailAfterCapture() {
        let scan = detailAfterCapture
        detailAfterCapture = nil
        reload()
        Task { await syncAllPending() }
        if let scan, scans.first(where: { $0.id == scan.id })?.pairedScanID == nil { offerUpsideDown = scan }
    }

    func showToast(_ text: String) {
        toast = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.toast == text { self?.toast = nil }
        }
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
            s.pauses = 0
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

    func enqueueBuild(_ id: String) { enqueue(id) }

    func appMovedToBackground() {
        if buildingID != nil {
            backgroundedDuringBuild = true
            AppLog.warn("build", "App left the screen during the build at \(Int(progress * 100))% (\(progressNote))")
        }
        if driveSignedIn && scans.contains(where: { $0.hasModel && $0.drive?.complete != true }) {
            AppDelegate.scheduleUploadTask()
        }
        Task { await uploadAppLog() }
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
            buildStarted = Date()
            loggedStage = ""
            loggedTenth = -1
            let where_ = UIApplication.shared.applicationState == .active ? "on screen" : "in the background"
            let photos = scan.photoCount ?? ScanStore.countPhotos(in: scan.imagesURL)
            AppLog.info("build", "Build started (attempt \((scan.buildAttempts ?? 0) + 1), \(photos) photos, app \(where_), "
                        + "heat \(AppLog.thermal()), memory \(AppLog.memoryInUseMB()) MB, free space \(AppInfo.freeSpace()))", scan: scan)
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

    func setProgress(_ fraction: Double, _ note: String) {
        progress = fraction
        progressNote = note
        BackgroundBuild.shared.update(fraction: fraction, note: note)
        // The log gets each new stage and every 10 %, not every tick.
        let stage = note.components(separatedBy: "…").first ?? note
        let tenth = Int(fraction * 10)
        if stage != loggedStage || tenth != loggedTenth {
            loggedStage = stage
            loggedTenth = tenth
            let scan = scans.first { $0.id == buildingID }
            let state = UIApplication.shared.applicationState == .active ? "" : " (app in the background)"
            AppLog.info("build", "\(Int(fraction * 100))% \(note)\(state)", scan: scan)
            AppLog.setActivity("building \(scan?.name ?? "") \(Int(fraction * 100))% \(stage)")
        }
    }

    /// Minutes since the build started, for the log.
    var buildMinutes: String { String(format: "%.1f min", Date().timeIntervalSince(buildStarted) / 60) }

    /// What to do after a build stopped with an error; shared by sample and pieces builds.
    /// Returns true when the build is paused (to carry on later) rather than failed.
    func buildStopped(_ scan: inout Scan, _ error: Error) -> Bool {
        BackgroundBuild.shared.end(success: false)
        let active = UIApplication.shared.applicationState == .active
        let interrupted = backgroundedDuringBuild || BackgroundBuild.shared.expired || !active
        let place = active ? "on screen" : "in the background"
        AppLog.error("build", "Build stopped at \(Int(progress * 100))% after \(buildMinutes) (\(progressNote)); app \(place), "
                     + "left the screen during the build: \(backgroundedDuringBuild), iOS took the background time back: \(BackgroundBuild.shared.expired), "
                     + "phone unlocked: \(UIApplication.shared.isProtectedDataAvailable), heat \(AppLog.thermal()), memory \(AppLog.memoryInUseMB()) MB",
                     error, scan: scan)
        let ns = error as NSError
        let kind = BuildStop.classify(interrupted: interrupted, domain: ns.domain, code: ns.code, pausesSoFar: scan.pauses ?? 0)
        guard kind == .pause else {
            if interrupted { AppLog.warn("build", "Stopped while off screen, but counted as a real failure (\(ns.domain) \(ns.code))", scan: scan) }
            return false
        }
        // A pause isn't a failed attempt: only real failures count towards giving up.
        scan.buildAttempts = max(0, (scan.buildAttempts ?? 1) - 1)
        scan.pauses = (scan.pauses ?? 0) + 1
        try? ScanStore.save(scan)
        buildPausedNote = "\(scan.name) paused at \(Int(progress * 100))% when the phone locked or another app opened. It carries on from its last checkpoint while Crystal Bowl is on screen."
        AppLog.info("build", "Paused (pause \(scan.pauses ?? 0)); it carries on when the app is on screen again", scan: scan)
        Notifier.post(id: "paused-\(scan.id)", title: "\(scan.name): build paused",
                      body: "An iPhone stops 3D building when it locks. Open Crystal Bowl and it carries on from where it stopped.")
        if active { buildQueue.append(scan.id) }
        return true
    }

    private func runBuild(_ original: Scan) async {
        if original.isPieces {
            await runPiecesBuild(original)
            return
        }
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
            buildPausedNote = nil
            AppLog.info("build", "Build finished in \(buildMinutes), \(scan.pauses ?? 0) pause(s)", scan: scan)
            queueSectionsForPhotos(scan, scan.sections ?? [])
            BackgroundBuild.shared.end(success: true)
            Task { await upgradeScans() } // shape fit and sample sheet for the new scan
            Notifier.post(id: "built-\(scan.id)", title: "\(scan.name): 3D model ready",
                          body: "Model, lab files and slices are saved\(driveSignedIn || folderLinked ? " and going to Google Drive" : "").")
            Task { await syncAllPending() }
        } catch {
            if buildStopped(&scan, error) {
                // Still requested: it resumes from the checkpoint as soon as the app is in front again.
            } else if (scan.blurrySetAside ?? 0) > 0 {
                AppLog.info("build", "Trying again with the blurred photos put back", scan: scan)
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
        try await photogrammetry(input: scan.imagesURL, checkpoint: scan.checkpointURL, output: scan.modelURL, from: 0, to: 0.88, label: "Building the model")
    }

    /// Builds one model from a folder of photos; progress runs from `from` to `to`.
    func photogrammetry(input: URL, checkpoint: URL, output: URL, from: Double, to: Double, label: String) async throws {
        setProgress(from + 0.01, "Preparing \(ScanStore.countPhotos(in: input)) photos…")
        var config = PhotogrammetrySession.Configuration()
        config.checkpointDirectory = checkpoint
        // Guided capture saves photos in the order they were taken, which lets matching start from neighbours.
        config.sampleOrdering = .sequential
        let resuming = ((try? FileManager.default.contentsOfDirectory(atPath: checkpoint.path))?.isEmpty == false)
        AppLog.info("build", "\(label): photogrammetry starting\(resuming ? " from a saved checkpoint" : "")")
        let session = try PhotogrammetrySession(input: input, configuration: config)
        photoSession = session
        try session.process(requests: [.modelFile(url: output)])
        var failure: Error?
        var invalid = 0
        var skipped = 0
        defer {
            if invalid + skipped > 0 { AppLog.warn("build", "\(label): \(invalid) photo(s) unusable, \(skipped) skipped by photogrammetry") }
        }
        // The outputs stream stays open after the last request finishes, so leave it on
        // processingComplete; waiting for the stream to end hangs at 100%.
        outputs: for try await output in session.outputs {
            switch output {
            case .requestProgress(_, let fraction):
                setProgress(from + fraction * (to - from), "\(label)… \(Int(fraction * 100))%")
            case .requestError(_, let error):
                AppLog.error("build", "\(label): photogrammetry reported an error", error)
                failure = error
            case .processingCancelled:
                AppLog.warn("build", "\(label): photogrammetry was cancelled")
                failure = NSError(domain: "CrystalBowl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Processing was stopped"])
                break outputs
            case .processingComplete:
                AppLog.info("build", "\(label): photogrammetry complete")
                break outputs
            case .inputComplete:
                AppLog.info("build", "\(label): photos read")
            case .automaticDownsampling:
                AppLog.warn("build", "\(label): photogrammetry is using smaller images (memory)")
            case .invalidSample:
                invalid += 1
            case .skippedSample:
                skipped += 1
            default:
                break
            }
        }
        if let failure { throw failure }
        guard FileManager.default.fileExists(atPath: output.path) else {
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
        return t + " (\(scan.scaleSource == "LiDAR" ? "LiDAR scale" : scan.scaleSource))"
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
            AppLog.info("sections", "Cut \(series.title) every \(SectionSeries.format(spacingMM)) mm: \(series.rows.count) slices", scan: updated)
            queueSectionsForPhotos(updated, [series])
            Task { await syncAllPending() }
        } catch {
            AppLog.error("sections", "Cutting \(axis)-axis every \(spacingMM) mm failed", error, scan: scan)
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
