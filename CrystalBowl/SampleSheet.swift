import SwiftUI
import SceneKit
import Metal
import ScanMath

/// Virtual sample-preparation photos: true-scale orthographic views of the textured model (four sides, top and
/// bottom), each with a millimetre ruler drawn to exactly the same scale as the rock, like the lab's photo
/// sheets with a ruler beside the plug. The side views follow the protractor angle chosen in the 3D view.
@MainActor
enum SampleSheet {
    struct Panel: Identifiable {
        let id: String
        let title: String
        let image: UIImage
    }

    static let pixels: CGFloat = 1200

    static func render(rig: SampleRig, scan: Scan, angle: Double) -> [Panel] {
        let d = rig.data
        let scene = SCNScene()
        scene.background.contents = UIColor.white
        let holder = SCNNode()
        let model = rig.modelNode.clone()
        model.simdPosition = rig.sample.simdPosition
        holder.addChildNode(model)
        scene.rootNode.addChildNode(holder)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 650
        scene.rootNode.addChildNode(ambient)

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.usesOrthographicProjection = true
        cam.camera?.zNear = 0.001
        cam.camera?.zFar = 10
        let head = SCNNode()
        head.light = SCNLight()
        head.light?.type = .directional
        head.light?.intensity = 700
        cam.addChildNode(head)
        scene.rootNode.addChildNode(cam)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = cam

        let H = d.height, Rc = d.circleRadius
        let unitPerMM = 0.001 / d.scaleFactor
        var panels: [Panel] = []

        // Sides: the camera looks from the front (+Z); the sample turns under it.
        let sideScale = Swift.max(H, 2 * Rc) * 0.62
        for v in [0.0, 90, 180, 270] {
            holder.simdOrientation = simd_quatf(angle: Float((angle + v) * .pi / 180), axis: SIMD3(0, 1, 0))
            cam.simdPosition = SIMD3(0, Float(H / 2), 2)
            cam.simdOrientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
            cam.camera?.orthographicScale = sideScale
            let shot = renderer.snapshot(atTime: 0, with: CGSize(width: pixels, height: pixels), antialiasingMode: .multisampling4X)
            let pxPerUnit = Double(pixels) / (2 * sideScale)
            let baseY = Double(pixels) / 2 + H / 2 * pxPerUnit
            let title = "Side \(Int(v))°"
            panels.append(Panel(id: "side\(String(format: "%03d", Int(v)))", title: title,
                                image: compose(shot, title: title, caption: "\(Rotation.text(angle + v)) · \(scan.name)",
                                               rulerFromY: baseY, pxPerMM: pxPerUnit * unitPerMM, rulerMM: d.heightMM + 5)))
        }
        // Top and bottom.
        holder.simdOrientation = simd_quatf(angle: Float(angle * .pi / 180), axis: SIMD3(0, 1, 0))
        let flatScale = Rc * 1.3
        let pxPerUnit = Double(pixels) / (2 * flatScale)
        for (id, title, y, tilt) in [("top", "Top", H + 2, -Double.pi / 2), ("bottom", "Bottom", -2.0, Double.pi / 2)] {
            cam.simdPosition = SIMD3(0, Float(y), 0)
            cam.simdOrientation = simd_quatf(angle: Float(tilt), axis: SIMD3(1, 0, 0))
            cam.camera?.orthographicScale = flatScale
            let shot = renderer.snapshot(atTime: 0, with: CGSize(width: pixels, height: pixels), antialiasingMode: .multisampling4X)
            let baseY = Double(pixels) / 2 + Rc * pxPerUnit
            panels.append(Panel(id: id, title: title,
                                image: compose(shot, title: title, caption: "\(Rotation.text(angle)) · \(scan.name)",
                                               rulerFromY: baseY, pxPerMM: pxPerUnit * unitPerMM, rulerMM: d.fitsDiameterMM + 5)))
        }
        return panels
    }

    /// The render with a blue lab ruler on the left (0 at the base of the rock), a title and a caption.
    static func compose(_ shot: UIImage, title: String, caption: String, rulerFromY baseY: Double, pxPerMM: Double, rulerMM: Double) -> UIImage {
        let size = CGSize(width: pixels, height: pixels)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            shot.draw(in: CGRect(origin: .zero, size: size))
            drawRuler(ctx.cgContext, x: 0, baseY: CGFloat(baseY), pxPerMM: CGFloat(pxPerMM), mm: rulerMM)
            let t = title as NSString
            t.draw(at: CGPoint(x: 150, y: 24), withAttributes: [.font: UIFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: UIColor.black])
            let c = caption as NSString
            c.draw(at: CGPoint(x: 150, y: size.height - 64), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.darkGray])
            UIColor.black.setStroke()
            let frame = UIBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3))
            frame.lineWidth = 6
            frame.stroke()
        }
    }

    static func drawRuler(_ g: CGContext, x: CGFloat, baseY: CGFloat, pxPerMM: CGFloat, mm: Double) {
        let ticks = RulerTicks.ticks(coveringMM: mm)
        guard let total = ticks.last?.mm else { return }
        let width = Swift.max(110, pxPerMM * 22)
        let top = baseY - CGFloat(total) * pxPerMM
        g.setFillColor(UIColor(red: 0.1, green: 0.22, blue: 0.62, alpha: 1).cgColor)
        g.fill(CGRect(x: x, y: top - 12, width: width, height: baseY - top + 24))
        g.setFillColor(UIColor.white.cgColor)
        let font = UIFont.systemFont(ofSize: Swift.max(18, Swift.min(34, pxPerMM * 4)), weight: .semibold)
        let every1 = pxPerMM >= 3
        for t in ticks where every1 || t.level > 0 {
            let y = baseY - CGFloat(t.mm) * pxPerMM
            let len = width * [0.18, 0.3, 0.45][t.level]
            g.fill(CGRect(x: x + width - len, y: y - 1.2, width: len, height: 2.4))
            if let label = t.label {
                let s = label as NSString
                let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
                let sz = s.size(withAttributes: a)
                s.draw(at: CGPoint(x: x + 8, y: y - sz.height / 2), withAttributes: a)
            }
        }
        ("cm" as NSString).draw(at: CGPoint(x: x + 8, y: baseY + 14),
                                withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: UIColor(red: 0.1, green: 0.22, blue: 0.62, alpha: 1)])
    }

    /// All panels in one row under a title, like a slide.
    static func montage(_ panels: [Panel], title: String) -> UIImage {
        let w: CGFloat = 600, gap: CGFloat = 30, head: CGFloat = 130
        let size = CGSize(width: CGFloat(panels.count) * (w + gap) + gap, height: head + w + gap)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            (title as NSString).draw(at: CGPoint(x: gap, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 60, weight: .regular),
                                                                                  .foregroundColor: UIColor(red: 0.1, green: 0.2, blue: 0.85, alpha: 1)])
            for (i, p) in panels.enumerated() {
                p.image.draw(in: CGRect(x: gap + CGFloat(i) * (w + gap), y: head, width: w, height: w))
            }
        }
    }

    /// Saves the panels and the montage into the scan's model folder (so they also go to Google Drive).
    static func save(_ panels: [Panel], montage: UIImage, scan: Scan, angle: Double) throws -> [URL] {
        let dir = scan.exportsURL.appendingPathComponent("sheet", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tag = Rotation.token(angle)
        var urls: [URL] = []
        let m = dir.appendingPathComponent("\(scan.fileStem)_sample-sheet_\(tag).png")
        try montage.pngData()?.write(to: m, options: .atomic)
        urls.append(m)
        for p in panels {
            let u = dir.appendingPathComponent("\(scan.fileStem)_view-\(p.id)_\(tag).png")
            try p.image.pngData()?.write(to: u, options: .atomic)
            urls.append(u)
        }
        return urls
    }
}

struct SampleSheetView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let scan: Scan
    let rig: SampleRig
    let angle: Double
    @State private var panels: [SampleSheet.Panel] = []
    @State private var saved: [URL] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("True-scale views of the 3D model, each with a ruler drawn to the same scale. The side views start at the protractor angle \(Rotation.text(angle)).")
                        .font(.footnote).foregroundStyle(.secondary)
                    if panels.isEmpty { ProgressView("Rendering…").frame(maxWidth: .infinity) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(panels) { p in
                            Image(uiImage: p.image).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    if !saved.isEmpty {
                        Label("Saved in the scan's model/sheet folder; it goes to Google Drive with the scan.", systemImage: "checkmark.circle.fill")
                            .font(.footnote).foregroundStyle(.green)
                        ShareLink(items: saved) { Label("Share the images", systemImage: "square.and.arrow.up") }
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                .padding()
            }
            .navigationTitle("Sample sheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                let p = SampleSheet.render(rig: rig, scan: scan, angle: angle)
                panels = p
                let m = SampleSheet.montage(p, title: "\(scan.name) – Sample views (virtual, true scale)")
                do {
                    saved = try SampleSheet.save(p, montage: m, scan: scan, angle: angle)
                    Task { await model.syncAllPending() }
                } catch {
                    self.error = "Couldn't save: \(error.localizedDescription)"
                }
            }
        }
    }
}
