import SwiftUI
import AVFoundation
import Vision
import CoreMotion
import ScanMath

/// Close-up photos of the rock's surface for pattern and texture work (secondary to the dimensions).
/// Unlike Object Capture, this camera is the app's own, so it can use all the back lenses: the virtual
/// multi-lens camera switches between ultra-wide (macro), main and telephoto by itself, the rock is found in
/// the picture and kept in focus and framed by automatic zoom, and a tap on the screen tells it where the rock is.
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
    @Published var autoFrame = true
    @Published var count = 0
    @Published var message: String?
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
        case .builtInTripleCamera: names = ["Ultra-wide · macro", "Main", "Telephoto"]
        case .builtInDualWideCamera: names = ["Ultra-wide · macro", "Main"]
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
            dev.videoZoomFactor = min(max(mainFactor, dev.minAvailableVideoZoomFactor), dev.maxAvailableVideoZoomFactor)
            dev.unlockForConfiguration()
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
        DispatchQueue.main.async { self.autoFrame = false }
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
        guard now.timeIntervalSince(lastVision) > 0.4, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
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
        if !manual && hypot(poi.x - lastPoint.x, poi.y - lastPoint.y) > 0.06 { setPointOfInterest(poi) }
        let isFocused = !dev.isAdjustingFocus
        let lens = Self.lensName(dev)
        DispatchQueue.main.async {
            self.focused = isFocused
            self.lensName = lens
            self.zoomLabel = Self.format(dev.videoZoomFactor * self.displayMultiplier)
        }
        guard autoFrameOn(), !manual, Date().timeIntervalSince(lastZoomChange) > 1.2, !dev.isRampingVideoZoom else { return }
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

    // MARK: Taking photos

    /// Waits up to a second for the focus to settle, then takes a full-resolution photo.
    func capture() {
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
            return
        }
        let meta = photoMeta()
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
        guard (try? data.write(to: url, options: .atomic)) != nil else {
            DispatchQueue.main.async { self.busy = false; self.message = "Couldn't save the photo." }
            return
        }
        let s = ShotQuality.score(url)
        let typical = ScanMath.median(scores)
        if let s, scores.count >= 3, typical.isFinite, s < ShotQuality.blurRatio * typical {
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.busy = false
                self.message = "That one was blurred and wasn't kept. Hold still, tap the rock to focus, and take it again."
            }
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
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            "note": "Close-up photos for surface pattern and texture work. Not used to build the model. azimuth_deg counts round the rock from the first detail photo; look_down_deg is the camera tilt below the horizon; sharpness is relative (Laplacian variance of the centre).",
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
                Text(camera.message ?? "Tap the rock to focus on it. Move round it and take a close-up from every side and from above. Zoom follows the rock by itself.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                Spacer()
                VStack(spacing: 12) {
                    DirectionRing(counts: camera.directions).frame(width: 70, height: 70)
                    HStack(spacing: 8) {
                        ForEach(camera.lenses) { lens in
                            Button(lens.label) { camera.select(lens) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel(lens.name)
                        }
                        Toggle("Auto", isOn: $camera.autoFrame)
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
        .onAppear { camera.start(folder: scan.detailURL) }
        .onDisappear { camera.stop() }
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
