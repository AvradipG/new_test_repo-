import SwiftUI
import AVFoundation
import Vision
import CoreMotion
import ScanMath

/// Close-up photos of the rock's surface for pattern and texture work: the sharp, full-resolution pictures the
/// patterns are read from (3D scan photos are taken from 20 cm or more and can't show them).
/// Unlike Object Capture, this camera is the app's own, so it can use all the back lenses. 3.13: it starts on the
/// macro lens (ultra-wide, focuses from 2 cm) at its own resolution, with no digital zoom (zoom only crops, it adds
/// no detail and can hand over to a lens that can't focus that close). An automatic shutter takes a full-resolution
/// photo each time the phone is held still on a new spot with the picture in focus and sharp; the user only
/// moves slowly over the rock. A tap focuses where tapped; the shutter button still works.
final class DetailCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Lens: Identifiable, Hashable {
        let name: String
        let label: String
        let factor: CGFloat
        var id: CGFloat { factor }
    }

    @Published var lenses: [Lens] = []
    @Published var lensName = ""
    @Published var zoomLabel = "1×"
    @Published var focused = false
    @Published var autoFrame = false
    @Published var count = 0
    @Published var message: String?
    /// Automatic shutter (3.13): a photo when the phone is still, the picture sharp and the spot new.
    @Published var autoShutter = true
    /// What the automatic shutter is waiting for, shown on screen.
    @Published var status = "Starting the camera…"
    @Published var steady = false
    @Published var macro = true
    @Published var busy = false
    @Published var unavailable: String?
    /// Photos per direction: eight around the rock (45° each, from the first photo) and one from above.
    @Published var directions = [Int](repeating: 0, count: 9)

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "detail.camera")
    private let visionQueue = DispatchQueue(label: "detail.vision")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var folder: URL?
    private var records: [[String: Any]] = []
    private var scores: [Double] = []
    private var lastVision = Date.distantPast
    private var lastZoomChange = Date.distantPast
    private var manualUntil = Date.distantPast
    private var lastPoint = CGPoint(x: 0.5, y: 0.5)
    private var maxAutoZoom: CGFloat = 1
    private var displayMultiplier: CGFloat = 1
    private let motion = CMMotionManager()
    private var startHeading: Double?
    private var configured = false
    private var pendingAuto = false
    private var pendingFrameSharpness: Double?
    // Automatic shutter state, on the vision queue.
    private var lastAnalysis = Date.distantPast
    private var stillSince: Date?
    private var recentSharp: [(Date, Double)] = []
    private var keptThumbs: [[Float]] = []
    private var lastAuto = Date.distantPast
    private var inFlight = false
    private var lastStatus = ""
    private var autoOn = true

    // MARK: Lifecycle

    func start(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        loadRecords()
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.1
            motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical)
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                DispatchQueue.main.async { self.unavailable = "Camera access is off. Turn it on in Settings › Crystal Bowl." }
                return
            }
            self.queue.async {
                if !self.configured { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        guard let dev = types.lazy.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first,
              let input = try? AVCaptureDeviceInput(device: dev) else {
            DispatchQueue.main.async { self.unavailable = "No back camera found." }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        // Full-range luma for the sharpness check (3.13).
        if videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        }
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        photoOutput.maxPhotoQualityPrioritization = .quality
        // Largest photos the camera offers (48 MP on recent Pro iPhones).
        if let best = dev.activeFormat.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = best
        }
        session.commitConfiguration()

        let switches = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        var multiplier: CGFloat = (dev.deviceType == .builtInTripleCamera || dev.deviceType == .builtInDualWideCamera) ? 0.5 : 1
        if #available(iOS 18.0, *) { multiplier = dev.displayVideoZoomFactorMultiplier }
        displayMultiplier = multiplier
        let mainFactor = dev.deviceType == .builtInDualCamera ? 1 : (switches.first ?? 1)
        // Automatic zoom goes up to the telephoto lens, never into digital zoom beyond it.
        maxAutoZoom = min(dev.maxAvailableVideoZoomFactor, max(switches.last ?? 1, mainFactor * 2))

        var lensList: [Lens] = []
        let names: [String]
        switch dev.deviceType {
        case .builtInTripleCamera: names = ["Macro (ultra-wide, 2–5 cm away)", "Main, 48 MP (20 cm or more)", "Telephoto"]
        case .builtInDualWideCamera: names = ["Macro (ultra-wide, 2–5 cm away)", "Main, 48 MP (20 cm or more)"]
        case .builtInDualCamera: names = ["Main", "Telephoto"]
        default: names = ["Main"]
        }
        let factors = [CGFloat(1)] + switches
        for (i, f) in factors.enumerated() where i < names.count {
            lensList.append(Lens(name: names[i], label: Self.format(f * multiplier), factor: f))
        }

        do {
            try dev.lockForConfiguration()
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            dev.isSubjectAreaChangeMonitoringEnabled = true
            // 3.13: start on the macro lens at its own resolution when there is one (zoom factor 1 of a
            // multi-lens camera with an ultra-wide), focusing near.
            let hasMacro = dev.deviceType == .builtInTripleCamera || dev.deviceType == .builtInDualWideCamera
            let start: CGFloat = hasMacro ? dev.minAvailableVideoZoomFactor : mainFactor
            dev.videoZoomFactor = min(max(start, dev.minAvailableVideoZoomFactor), dev.maxAvailableVideoZoomFactor)
            if dev.isAutoFocusRangeRestrictionSupported { dev.autoFocusRangeRestriction = hasMacro ? .near : .none }
            dev.unlockForConfiguration()
            DispatchQueue.main.async { self.macro = hasMacro }
        } catch {}
        device = dev
        configured = true
        DispatchQueue.main.async {
            self.lenses = lensList
            self.zoomLabel = Self.format(dev.videoZoomFactor * multiplier)
        }
    }

    static func format(_ f: CGFloat) -> String {
        let r = (f * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))×" : String(format: "%.1f×", Double(r))
    }

    // MARK: Focus and zoom

    /// The user tapped the rock: focus and expose there, and follow that spot for a while.
    func focus(at devicePoint: CGPoint) {
        manualUntil = Date().addingTimeInterval(8)
        queue.async { self.setPointOfInterest(devicePoint) }
        DispatchQueue.main.async { self.message = "Focusing where you tapped" }
    }

    func select(_ lens: Lens) {
        let near = lens.name.hasPrefix("Macro")
        DispatchQueue.main.async {
            self.autoFrame = false
            self.macro = near
        }
        queue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            if dev.isAutoFocusRangeRestrictionSupported { dev.autoFocusRangeRestriction = near ? .near : .none }
            dev.unlockForConfiguration()
        }
        setZoom(lens.factor)
    }

    func setZoom(_ factor: CGFloat) {
        queue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            let f = min(max(factor, dev.minAvailableVideoZoomFactor), dev.maxAvailableVideoZoomFactor)
            dev.ramp(toVideoZoomFactor: f, withRate: 4)
            dev.unlockForConfiguration()
            self.lastZoomChange = Date()
            DispatchQueue.main.async { self.zoomLabel = Self.format(f * self.displayMultiplier) }
        }
    }

    func currentZoom() -> CGFloat { device?.videoZoomFactor ?? 1 }

    private func setPointOfInterest(_ p: CGPoint) {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        if dev.isFocusPointOfInterestSupported {
            dev.focusPointOfInterest = p
            dev.focusMode = dev.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
        }
        if dev.isExposurePointOfInterestSupported {
            dev.exposurePointOfInterest = p
            dev.exposureMode = .continuousAutoExposure
        }
        dev.unlockForConfiguration()
        lastPoint = p
    }

    /// Finds the rock (the most salient object) a few times a second, keeps the focus on it and, with
    /// automatic framing on, zooms so it fills about 60 % of the picture.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if now.timeIntervalSince(lastAnalysis) > 0.12 {
            lastAnalysis = now
            autoShutterStep(pixels, now: now)
        }
        guard now.timeIntervalSince(lastVision) > 0.4 else { return }
        lastVision = now
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        // Sensor frames are landscape; the phone is held upright.
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right).perform([request])
        let boxes = request.results?.first?.salientObjects?.map { $0.boundingBox } ?? []
        guard let box = boxes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return }
        queue.async { self.track(box) }
    }

    private func track(_ box: CGRect) {
        guard let dev = device else { return }
        // Vision box: upright picture, origin bottom-left. Point of interest: sensor frame, origin top-left,
        // where the upright picture's top-left x/y map to sensor (y, 1 − x).
        let upright = CGPoint(x: box.midX, y: 1 - box.midY)
        let poi = CGPoint(x: upright.y, y: 1 - upright.x)
        let manual = Date() < manualUntil
        let following = autoFrameOn()
        // 3.13: the focus follows the rock only with automatic framing on; otherwise it stays in the middle (or
        // where tapped), so the macro lens doesn't keep refocusing while the user holds still.
        if following && !manual && hypot(poi.x - lastPoint.x, poi.y - lastPoint.y) > 0.06 { setPointOfInterest(poi) }
        let isFocused = !dev.isAdjustingFocus
        let lens = Self.lensName(dev)
        DispatchQueue.main.async {
            self.focused = isFocused
            self.lensName = lens
            self.zoomLabel = Self.format(dev.videoZoomFactor * self.displayMultiplier)
        }
        guard following, !manual, Date().timeIntervalSince(lastZoomChange) > 1.2, !dev.isRampingVideoZoom else { return }
        let fill = max(box.width, box.height)
        guard fill > 0.05 else { return }
        let current = dev.videoZoomFactor
        let wanted = min(max(current * 0.6 / fill, dev.minAvailableVideoZoomFactor), maxAutoZoom)
        let ratio = wanted / current
        if ratio > 1.25 || ratio < 0.8 { setZoom(wanted) }
    }

    private func autoFrameOn() -> Bool {
        var on = true
        if Thread.isMainThread { on = autoFrame } else { DispatchQueue.main.sync { on = self.autoFrame } }
        return on
    }

    static func lensName(_ dev: AVCaptureDevice) -> String {
        switch dev.activePrimaryConstituent?.deviceType {
        case .some(.builtInUltraWideCamera): return "Ultra-wide (macro)"
        case .some(.builtInTelephotoCamera): return "Telephoto"
        case .some(.builtInWideAngleCamera): return "Main"
        default: return dev.deviceType == .builtInWideAngleCamera ? "Main" : ""
        }
    }

    // MARK: Automatic shutter (3.13)

    /// Sharpness of the middle of the live picture at full sensor resolution, and a small grey thumbnail of the
    /// whole picture to tell a new spot from one already photographed.
    static func analyse(_ pixels: CVPixelBuffer) -> (sharpness: Double, thumb: [Float])? {
        guard CVPixelBufferGetPlaneCount(pixels) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let w: Int = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let h: Int = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride: Int = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        guard w > 64, h > 64 else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let cw: Int = min(480, w / 2), ch: Int = min(360, h / 2)
        let x0: Int = (w - cw) / 2, y0: Int = (h - ch) / 2
        var gray = [Float](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            let rowStart: Int = (y0 + y) * stride + x0
            let out: Int = y * cw
            for x in 0..<cw { gray[out + x] = Float(p[rowStart + x]) / 255 }
        }
        let sharp = ScanMath.sharpness(gray: gray, width: cw, height: ch)
        let tw = 32, th = 24
        var thumb = [Float](repeating: 0, count: tw * th)
        for j in 0..<th {
            let yy: Int = (j * h) / th + h / (2 * th)
            for i in 0..<tw {
                let xx: Int = (i * w) / tw + w / (2 * tw)
                let a = Float(p[yy * stride + xx])
                let b = Float(p[yy * stride + min(w - 1, xx + 2)])
                thumb[j * tw + i] = (a + b) / 510
            }
        }
        // Mean 0, spread 1, so a change of light doesn't count as a new spot.
        let mean: Float = thumb.reduce(0, +) / Float(thumb.count)
        var v: Float = 0
        for t in thumb { v += (t - mean) * (t - mean) }
        let sd: Float = max(0.02, (v / Float(thumb.count)).squareRoot())
        return (sharp, thumb.map { ($0 - mean) / sd })
    }

    static func difference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var s: Float = 0
        for i in a.indices { s += abs(a[i] - b[i]) }
        return s / Float(a.count)
    }

    private func setStatus(_ text: String, steady isSteady: Bool) {
        guard text != lastStatus else { return }
        lastStatus = text
        DispatchQueue.main.async {
            self.status = text
            self.steady = isSteady
        }
    }

    /// Runs on every few frames: is the phone still, the picture in focus and sharp, and the spot new? Then a
    /// full-resolution photo is taken by itself.
    private func autoShutterStep(_ pixels: CVPixelBuffer, now: Date) {
        guard let a = Self.analyse(pixels) else { return }
        recentSharp.append((now, a.sharpness))
        recentSharp.removeAll { now.timeIntervalSince($0.0) > 2.5 }
        guard autoOn else { setStatus("Automatic shutter off: tap the shutter", steady: false); return }
        guard !inFlight else { return }
        // Still: little turning and little shaking, for a third of a second.
        var still = true
        if let dm = motion.deviceMotion {
            let r = dm.rotationRate, u = dm.userAcceleration
            let turn: Double = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
            let shake: Double = (u.x * u.x + u.y * u.y + u.z * u.z).squareRoot()
            still = turn < 0.22 && shake < 0.05
        }
        if still {
            if stillSince == nil { stillSince = now }
        } else {
            stillSince = nil
        }
        guard let since = stillSince else { setStatus("Hold still…", steady: false); return }
        guard now.timeIntervalSince(since) > 0.35 else { setStatus("Hold still…", steady: true); return }
        guard device?.isAdjustingFocus != true else { setStatus("Focusing…", steady: true); return }
        // Sharp: close to the best the camera has shown in the last seconds, and some texture at all.
        let best: Double = recentSharp.map { $0.1 }.max() ?? 0
        guard a.sharpness > 1e-5 else { setStatus("Nothing in focus: point at the rock", steady: true); return }
        guard a.sharpness >= 0.8 * best else { setStatus("Focusing…", steady: true); return }
        // New spot: the picture differs from every photo already kept.
        let nearest: Float = keptThumbs.map { Self.difference(a.thumb, $0) }.min() ?? .infinity
        guard nearest > 0.45 else { setStatus("This spot is done: move on slowly over the rock", steady: true); return }
        guard now.timeIntervalSince(lastAuto) > 1.0 else { return }
        lastAuto = now
        inFlight = true
        keptThumbs.append(a.thumb)
        setStatus("Taking a sharp photo…", steady: true)
        capture(auto: true, frameSharpness: a.sharpness)
    }

    func setAutoShutter(_ on: Bool) {
        visionQueue.async {
            self.autoOn = on
            self.lastStatus = ""
        }
        DispatchQueue.main.async { self.autoShutter = on }
    }

    /// A photo is done (kept or dropped): the automatic shutter may go again.
    private func shotDone(kept: Bool, auto: Bool) {
        visionQueue.async {
            self.inFlight = false
            // A dropped automatic photo frees its spot again.
            if !kept, auto, !self.keptThumbs.isEmpty { self.keptThumbs.removeLast() }
            self.lastStatus = ""
        }
    }

    // MARK: Taking photos

    /// Waits up to a second for the focus to settle, then takes a full-resolution photo.
    func capture(auto: Bool = false, frameSharpness: Double? = nil) {
        pendingAuto = auto
        pendingFrameSharpness = frameSharpness
        DispatchQueue.main.async { self.busy = true; self.message = nil }
        queue.async {
            let deadline = Date().addingTimeInterval(1)
            while self.device?.isAdjustingFocus == true && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let folder else {
            DispatchQueue.main.async { self.busy = false; self.message = "The photo couldn't be taken. Try again." }
            shotDone(kept: false, auto: pendingAuto)
            return
        }
        var meta = photoMeta()
        meta["auto"] = pendingAuto
        let dims = photo.resolvedSettings.photoDimensions
        meta["pixels"] = "\(dims.width)x\(dims.height)"
        if let f = pendingFrameSharpness { meta["frame_sharpness"] = f }
        queue.async { self.store(data, folder: folder, meta: meta) }
    }

    private func photoMeta() -> [String: Any] {
        var m: [String: Any] = ["time_utc": ISO8601DateFormatter().string(from: Date())]
        if let dev = device {
            m["lens"] = Self.lensName(dev)
            m["zoom"] = Double(dev.videoZoomFactor * displayMultiplier)
            m["lens_position"] = Double(dev.lensPosition)
            m["iso"] = Double(dev.iso)
            m["exposure_s"] = CMTimeGetSeconds(dev.exposureDuration)
        }
        if let dm = motion.deviceMotion {
            let pose = CaptureGuide.pose(dm)
            if startHeading == nil { startHeading = pose.heading }
            m["azimuth_deg"] = CaptureGuide.positive(pose.heading - (startHeading ?? pose.heading))
            m["look_down_deg"] = pose.lookDown
        }
        return m
    }

    private func store(_ data: Data, folder: URL, meta: [String: Any]) {
        let index = (records.compactMap { ($0["index"] as? Int) }.max() ?? 0) + 1
        let name = String(format: "DETAIL_%04d.heic", index)
        let url = folder.appendingPathComponent(name)
        let wasAuto = (meta["auto"] as? Bool) == true
        guard (try? data.write(to: url, options: .atomic)) != nil else {
            DispatchQueue.main.async { self.busy = false; self.message = "Couldn't save the photo." }
            shotDone(kept: false, auto: wasAuto)
            return
        }
        let s = ShotQuality.score(url)
        // Compared with earlier close-ups through the same lens only: macro and main differ in sharpness (3.13).
        let lens = meta["lens"] as? String ?? ""
        let same = records.filter { ($0["lens"] as? String ?? "") == lens }.compactMap { $0["sharpness"] as? Double }
        let typical = ScanMath.median(same)
        if let s, same.count >= 3, typical.isFinite, s < ShotQuality.blurRatio * typical {
            try? FileManager.default.removeItem(at: url)
            AppLog.info("detail", String(format: "Close-up dropped as blurred (sharpness %.2g, typical %.2g)", s, typical))
            DispatchQueue.main.async {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.busy = false
                self.message = "That one was blurred and wasn't kept. Hold still, tap the rock to focus, and take it again."
            }
            shotDone(kept: false, auto: wasAuto)
            return
        }
        if let s { scores.append(s) }
        var rec = meta
        rec["index"] = index
        rec["file"] = name
        rec["sharpness"] = s.map { $0 as Any } ?? NSNull()
        records.append(rec)
        saveRecords()
        let dir = Self.direction(rec)
        let how = (rec["auto"] as? Bool) == true ? "automatic" : "shutter button"
        AppLog.info("detail", "Close-up \(name) kept: \(rec["lens"] as? String ?? "?"), \(rec["pixels"] as? String ?? "?") px, \(how)")
        shotDone(kept: true, auto: wasAuto)
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.message = "Sharp photo kept. Move on slowly to the next spot."
            self.count += 1
            if let dir { self.directions[dir] += 1 }
            self.busy = false
        }
    }

    /// 0–7 around the rock from the first photo, 8 from above.
    static func direction(_ rec: [String: Any]) -> Int? {
        guard let az = rec["azimuth_deg"] as? Double, let down = rec["look_down_deg"] as? Double else { return nil }
        if down > 60 { return 8 }
        return min(7, Int(CaptureGuide.positive(az + 22.5) / 45))
    }

    // MARK: Index file

    private var indexURL: URL? { folder?.appendingPathComponent("detail.json") }

    private func loadRecords() {
        guard let url = indexURL, let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photos = json["photos"] as? [[String: Any]] else { return }
        records = photos.filter { rec in
            guard let f = rec["file"] as? String, let folder else { return false }
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(f).path)
        }
        scores = records.compactMap { $0["sharpness"] as? Double }
        var dirs = [Int](repeating: 0, count: 9)
        for r in records { if let d = Self.direction(r) { dirs[d] += 1 } }
        let n = records.count
        DispatchQueue.main.async {
            self.count = n
            self.directions = dirs
        }
    }

    private func saveRecords() {
        guard let url = indexURL else { return }
        let json: [String: Any] = [
            "schema": "crystal-bowl.detail/1",
            "note": "Close-up photos for surface pattern and texture work, at the camera's full resolution. Not used to build the model. auto = taken by the automatic shutter (phone still, picture sharp, new spot); azimuth_deg counts round the rock from the first detail photo; look_down_deg is the camera tilt below the horizon; sharpness is relative (Laplacian variance of the centre); frame_sharpness is the live picture's at the moment of the shot.",
            "photos": records,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: Screen

struct DetailCaptureView: View {
    let scan: Scan
    /// Opened by itself straight after the 3D capture (3.13).
    var afterScan = false
    let onClose: () -> Void
    @StateObject private var camera = DetailCamera()
    @State private var pinchStart: CGFloat?
    @State private var tapPoint: CGPoint?

    var body: some View {
        ZStack {
            if let text = camera.unavailable {
                Text(text).padding().multilineTextAlignment(.center)
            } else {
                CameraPreview(session: camera.session) { layerPoint, devicePoint in
                    camera.focus(at: devicePoint)
                    tapPoint = layerPoint
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { tapPoint = nil }
                }
                .ignoresSafeArea()
                .gesture(MagnificationGesture()
                    .onChanged { scale in
                        if pinchStart == nil { pinchStart = camera.currentZoom(); camera.autoFrame = false }
                        camera.setZoom((pinchStart ?? 1) * scale)
                    }
                    .onEnded { _ in pinchStart = nil })
                if let p = tapPoint {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: 80, height: 80)
                        .position(p)
                        .allowsHitTesting(false)
                }
            }
            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    Button("Done") { onClose() }.buttonStyle(.borderedProminent)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Label(camera.focused ? "In focus" : "Focusing…", systemImage: camera.focused ? "checkmark.circle.fill" : "scope")
                            .foregroundStyle(camera.focused ? .green : .yellow)
                        Text("\(camera.lensName) · \(camera.zoomLabel)").monospacedDigit()
                        Text("\(camera.count) close-ups").monospacedDigit()
                    }
                    .font(.caption.bold())
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                Text(camera.message ?? introText)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                if camera.autoShutter {
                    Label(camera.status, systemImage: camera.steady ? "hand.raised.fill" : "hand.raised.slash")
                        .font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background((camera.steady ? Color.green : Color.orange).opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                VStack(spacing: 12) {
                    DirectionRing(counts: camera.directions).frame(width: 70, height: 70)
                    HStack(spacing: 8) {
                        ForEach(camera.lenses) { lens in
                            Button(lens.name.hasPrefix("Macro") ? "Macro" : lens.label) { camera.select(lens) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel(lens.name)
                        }
                        Toggle("Auto shutter", isOn: Binding(get: { camera.autoShutter }, set: { camera.setAutoShutter($0) }))
                            .toggleStyle(.button)
                            .buttonStyle(.bordered)
                    }
                    Button { camera.capture() } label: {
                        ZStack {
                            Circle().fill(.white).frame(width: 72, height: 72)
                            Circle().stroke(Theme.violet, lineWidth: 4).frame(width: 82, height: 82)
                            if camera.busy { ProgressView() }
                        }
                    }
                    .disabled(camera.busy)
                    .accessibilityLabel("Take close-up")
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding()
        }
        .onAppear {
            camera.start(folder: scan.detailURL)
            AppLog.info("detail", "Close-up camera opened" + (afterScan ? " after the 3D capture" : ""), scan: scan)
        }
        .onDisappear {
            camera.stop()
            AppLog.info("detail", "Close-up camera closed: \(camera.count) close-ups in the scan", scan: scan)
        }
    }

    private var introText: String {
        let start = afterScan ? "Now the close-ups, for the patterns. " : ""
        return start + (camera.macro
            ? "Macro: hold the phone 3–5 cm from the rock. Move slowly over the surface; hold still on each spot and a sharp full-resolution photo is taken by itself (you feel a tap). Cover every side and the top, then tap Done. Tap the screen to focus on a spot."
            : "Main lens: 20 cm or more from the rock, 48 MP. Hold still and the photo is taken by itself. For the finest detail use Macro and go close.")
    }
}

/// Eight directions round the rock and the top (centre dot); green once a close-up exists from there.
struct DirectionRing: View {
    let counts: [Int]
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 6
            for k in 0..<8 {
                var arc = Path()
                arc.addArc(center: c, radius: r, startAngle: .degrees(Double(k) * 45 - 90 - 20), endAngle: .degrees(Double(k) * 45 - 90 + 20), clockwise: false)
                ctx.stroke(arc, with: .color(counts[k] > 0 ? .green : .gray.opacity(0.5)), lineWidth: 8)
            }
            let d: CGFloat = 16
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)),
                     with: .color(counts.count > 8 && counts[8] > 0 ? .green : .gray.opacity(0.5)))
        }
        .accessibilityLabel("Directions photographed")
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onTap: (CGPoint, CGPoint) -> Void

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint, CGPoint) -> Void)?
        @objc func tapped(_ g: UITapGestureRecognizer) {
            let p = g.location(in: self)
            onTap?(p, previewLayer.captureDevicePointConverted(fromLayerPoint: p))
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.onTap = onTap
        v.addGestureRecognizer(UITapGestureRecognizer(target: v, action: #selector(PreviewView.tapped(_:))))
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) { uiView.onTap = onTap }
}
