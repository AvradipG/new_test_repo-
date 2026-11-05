import SceneKit
import UIKit
import simd
import ScanMath

/// Sizes and positions the measuring overlays need, taken from the model exactly as it is displayed.
struct MeasureData: @unchecked Sendable {
    var minY: Double
    var maxY: Double
    /// Smallest rectangle round the footprint, in model x/z (metres).
    var footprint: FootprintRect
    /// Smallest circle round the footprint: the vertical cylinder the rock needs to turn (micro-CT).
    var circleCenter: SIMD2<Double>
    var circleRadius: Double
    var shape: ShapeFit?
    /// Caliper correction: true size = model size × this.
    var scaleFactor: Double
    // Values shown in labels, millimetres, caliper-corrected.
    var heightMM: Double
    var lengthMM: Double
    var widthMM: Double
    var fitsDiameterMM: Double

    var height: Double { maxY - minY }
    /// Rough overall size (metres) used to size lines and labels.
    var extent: Double { Swift.max(height, circleRadius * 2, 0.01) }

    static func compute(points: [SIMD3<Float>], scan: Scan) -> MeasureData? {
        guard points.count >= 20 else { return nil }
        let ys = points.map { Double($0.y) }.sorted()
        let lo = ys[Int(Double(ys.count - 1) * 0.0005)], hi = ys[Int(Double(ys.count - 1) * 0.9995)]
        let flat = points.map { SIMD2<Double>(Double($0.x), Double($0.z)) }
        let hull = ScanMath.convexHull(flat)
        guard let rect = ScanMath.footprintRect(hull) else { return nil }
        let circle = ScanMath.enclosingCircle(hull)
        let k = scan.scaleFactor
        let u = scan.stats?.upright
        return MeasureData(
            minY: lo, maxY: hi, footprint: rect, circleCenter: circle.center, circleRadius: circle.radius,
            shape: ScanMath.fitShape(points), scaleFactor: k,
            heightMM: (u?.heightMM ?? (hi - lo) * 1000) * k,
            lengthMM: (u?.lengthMM ?? rect.long * 1000) * k,
            widthMM: (u?.widthMM ?? rect.short * 1000) * k,
            fitsDiameterMM: (u?.cylinderDiameterMM ?? circle.radius * 2000) * k)
    }

    /// One line per automatically found measure, for the panel next to the 3D view.
    var summary: [String] {
        var out: [String] = []
        if let s = shape {
            switch s.kind {
            case .cylinder:
                out.append(String(format: "Cylinder: Ø %.1f mm, length %.1f mm (radius %.2f mm)", s.diameter * 1000 * scaleFactor, s.length * 1000 * scaleFactor, s.radius * 1000 * scaleFactor))
                out.append(String(format: "Axis %.1f° from vertical · fit within %.2f mm · %.0f%% of the surface on the cylinder", s.tiltDegrees, s.residual * 1000 * scaleFactor, s.inlierShare * 100))
            case .sphere:
                out.append(String(format: "Sphere: Ø %.1f mm (radius %.2f mm), fit within %.2f mm", s.diameter * 1000 * scaleFactor, s.radius * 1000 * scaleFactor, s.residual * 1000 * scaleFactor))
            case .irregular:
                out.append("Irregular shape: no cylinder or sphere fits within 3 %")
            }
        }
        out.append(String(format: "Height %.1f mm · footprint %.1f × %.1f mm", heightMM, lengthMM, widthMM))
        out.append(String(format: "Turns inside a vertical cylinder of Ø %.1f mm (micro-CT clearance)", fitsDiameterMM))
        out.append(scaleFactor == 1 ? "Scale: LiDAR (add a caliper check to correct it)" : String(format: "Scale: caliper-corrected (× %.4f)", scaleFactor))
        return out
    }
}

/// Reads mesh vertices out of a SceneKit node tree, in world coordinates.
enum SceneGeometry {
    static func positions(in root: SCNNode, maxPoints: Int = 60_000) -> [SIMD3<Float>] {
        var nodes: [SCNNode] = [root]
        nodes += root.childNodes { _, _ in true }
        let sources = nodes.compactMap { n -> (SCNNode, SCNGeometrySource)? in
            guard let s = n.geometry?.sources(for: .vertex).first, s.usesFloatComponents, s.componentsPerVector >= 3 else { return nil }
            return (n, s)
        }
        let total = sources.reduce(0) { $0 + $1.1.vectorCount }
        let step = Swift.max(1, total / maxPoints)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(Swift.min(total, maxPoints + sources.count))
        for (node, s) in sources {
            let m = node.simdWorldTransform
            let stride = s.dataStride, offset = s.dataOffset, bpc = s.bytesPerComponent
            s.data.withUnsafeBytes { raw in
                var i = 0
                while i < s.vectorCount {
                    let base = offset + i * stride
                    guard base + bpc * 3 <= raw.count else { break }
                    let p: SIMD3<Float>
                    if bpc == 8 {
                        p = SIMD3(Float(raw.loadUnaligned(fromByteOffset: base, as: Double.self)),
                                  Float(raw.loadUnaligned(fromByteOffset: base + 8, as: Double.self)),
                                  Float(raw.loadUnaligned(fromByteOffset: base + 16, as: Double.self)))
                    } else {
                        p = SIMD3(raw.loadUnaligned(fromByteOffset: base, as: Float.self),
                                  raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                                  raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self))
                    }
                    let w = m * SIMD4(p, 1)
                    out.append(SIMD3(w.x, w.y, w.z))
                    i += step
                }
            }
        }
        return out
    }
}

/// A scanned sample set up for measuring: the model standing on a 360° protractor dial, with dimension marks
/// on it and a millimetre ruler beside it. Used by the 3D view, the AR view and the sample sheet.
///
/// stage (origin = centre of the base; ruler and dial are fixed here)
///  └ pivot (turns about the vertical: the protractor angle; the red needle turns with it)
///     └ sample (model coordinates: the model and its dimension marks)
@MainActor
final class SampleRig {
    let stage = SCNNode()
    let pivot = SCNNode()
    let sample = SCNNode()
    let dims = SCNNode()
    let ruler = SCNNode()
    let dial = SCNNode()
    let needle = SCNNode()
    /// The model alone, in model coordinates (for renders without overlays).
    let modelNode: SCNNode
    let data: MeasureData
    let name: String

    /// Degrees, counter-clockwise seen from above.
    var angle: Double = 0 {
        didSet { pivot.simdOrientation = simd_quatf(angle: Float(angle * .pi / 180), axis: SIMD3(0, 1, 0)) }
    }

    /// Radius of the dial (stage units): how much room the sample takes on a table.
    var footprintRadius: Float { Float(dialRadius) }
    private var dialRadius: Double { data.circleRadius * 1.45 + data.extent * 0.08 }

    /// Loads the model and measures it away from the main thread.
    static func load(_ scan: Scan) async -> (SCNScene, MeasureData)? {
        let url = scan.modelURL
        let s = scan
        return await Task.detached(priority: .userInitiated) { () -> (SCNScene, MeasureData)? in
            guard let scene = try? SCNScene(url: url, options: nil) else { return nil }
            let pts = SceneGeometry.positions(in: scene.rootNode)
            guard let data = MeasureData.compute(points: pts, scan: s) else { return nil }
            return (scene, data)
        }.value
    }

    init(scene: SCNScene, data: MeasureData, name: String) {
        self.data = data
        self.name = name
        let model = scene.rootNode.clone()
        modelNode = model
        sample.addChildNode(model)
        sample.simdPosition = SIMD3(Float(-data.circleCenter.x), Float(-data.minY), Float(-data.circleCenter.y))
        sample.addChildNode(dims)
        pivot.addChildNode(sample)
        pivot.addChildNode(needle)
        stage.addChildNode(pivot)
        stage.addChildNode(dial)
        stage.addChildNode(ruler)
        buildDimensions()
        buildRuler()
        buildDial()
    }

    func show(dimensions: Bool, ruler showRuler: Bool, protractor: Bool) {
        dims.isHidden = !dimensions
        ruler.isHidden = !showRuler
        dial.isHidden = !protractor
        needle.isHidden = !protractor
    }

    // MARK: Dimension marks

    private var lineRadius: Float { Float(data.extent * 0.0035) }
    private var labelHeight: Float { Float(data.extent * 0.075) }
    private var margin: Double { data.extent * 0.08 }

    private func buildDimensions() {
        let d = data
        let y0 = d.minY, y1 = d.maxY
        let c: SIMD2<Double> = d.footprint.center
        let ld: SIMD2<Double> = d.footprint.longDir
        let nd = SIMD2<Double>(-ld.y, ld.x)
        let halfL: SIMD2<Double> = ld * (d.footprint.long / 2)
        let halfS: SIMD2<Double> = nd * (d.footprint.short / 2)
        func p3(_ p: SIMD2<Double>, _ y: Double) -> SIMD3<Float> { SIMD3(Float(p.x), Float(y), Float(p.y)) }
        let kind = d.shape?.kind ?? .irregular

        // Height, beside the rock.
        let hx: SIMD2<Double> = c + halfL + ld * margin
        dims.addChildNode(Self.dimension(p3(hx, y0), p3(hx, y1), text: String(format: "H %.1f mm", d.heightMM),
                                         color: Palette.height, r: lineRadius, tick: SIMD3(Float(ld.x), 0, Float(ld.y)), label: labelHeight))

        if kind != .cylinder {
            // Footprint rectangle and its two sides.
            let corners: [SIMD2<Double>] = [c - halfL - halfS, c + halfL - halfS, c + halfL + halfS, c - halfL + halfS]
            for i in 0..<4 {
                dims.addChildNode(Self.line(p3(corners[i], y0), p3(corners[(i + 1) % 4], y0), r: lineRadius * 0.5, color: Palette.footprint))
            }
            let off: SIMD2<Double> = halfS + nd * margin
            let l0: SIMD2<Double> = c - halfL + off, l1: SIMD2<Double> = c + halfL + off
            dims.addChildNode(Self.dimension(p3(l0, y0), p3(l1, y0),
                                             text: String(format: "L %.1f mm", d.lengthMM), color: Palette.length, r: lineRadius,
                                             tick: SIMD3(Float(nd.x), 0, Float(nd.y)), label: labelHeight))
            let off2: SIMD2<Double> = -(halfL + ld * margin)
            let w0: SIMD2<Double> = c - halfS + off2, w1: SIMD2<Double> = c + halfS + off2
            dims.addChildNode(Self.dimension(p3(w0, y0), p3(w1, y0),
                                             text: String(format: "W %.1f mm", d.widthMM), color: Palette.width, r: lineRadius,
                                             tick: SIMD3(Float(ld.x), 0, Float(ld.y)), label: labelHeight))
        }

        if let s = d.shape, s.kind == .cylinder {
            let a = SIMD3<Float>(s.axis)
            let ctr = SIMD3<Float>(s.center)
            let r = Float(s.radius)
            let along: SIMD3<Float> = a * Float(s.length / 2)
            let top: SIMD3<Float> = ctr + along
            let bottom: SIMD3<Float> = ctr - along
            for end in [top, bottom] { dims.addChildNode(Self.ring(center: end, axis: a, radius: r, pipe: lineRadius * 0.8, color: Palette.cylinder)) }
            let ext: SIMD3<Float> = a * (Float(margin) * 0.5)
            dims.addChildNode(Self.line(bottom - ext, top + ext, r: lineRadius * 0.4, color: Palette.cylinder.withAlphaComponent(0.7)))
            // Diameter across the top face.
            let side: SIMD3<Float> = Self.perpendicular(a)
            let across: SIMD3<Float> = side * r
            let dText = String(format: "Ø %.1f mm", s.diameter * 1000 * d.scaleFactor)
            let up: SIMD3<Float> = a * (labelHeight * 1.2)
            dims.addChildNode(Self.dimension(top - across, top + across, text: dText, color: Palette.cylinder,
                                             r: lineRadius, tick: a, label: labelHeight, labelOffset: up))
            // Length along the side.
            let off: SIMD3<Float> = side * (r + Float(margin))
            let lText = String(format: "L %.1f mm", s.length * 1000 * d.scaleFactor)
            dims.addChildNode(Self.dimension(bottom + off, top + off, text: lText, color: Palette.length,
                                             r: lineRadius, tick: side, label: labelHeight))
        } else if let s = d.shape, s.kind == .sphere {
            let ctr = SIMD3<Float>(s.center)
            let r = Float(s.radius)
            let dx = SIMD3<Float>(r, 0, 0)
            let upY = SIMD3<Float>(0, 1, 0)
            dims.addChildNode(Self.ring(center: ctr, axis: upY, radius: r, pipe: lineRadius * 0.8, color: Palette.cylinder))
            let sText = String(format: "Ø %.1f mm (r %.1f)", s.diameter * 1000 * d.scaleFactor, s.radius * 1000 * d.scaleFactor)
            let up: SIMD3<Float> = upY * (labelHeight * 1.2)
            dims.addChildNode(Self.dimension(ctr - dx, ctr + dx, text: sText, color: Palette.cylinder,
                                             r: lineRadius, tick: upY, label: labelHeight, labelOffset: up))
        }

        // Micro-CT clearance: the smallest vertical cylinder the rock turns in.
        let cc = d.circleCenter, cr = Float(d.circleRadius)
        for y in [y0, y1] {
            dims.addChildNode(Self.ring(center: p3(cc, y), axis: SIMD3(0, 1, 0), radius: cr, pipe: lineRadius * 0.45, color: Palette.clearance))
        }
        let lab = Self.label(String(format: "turns in Ø %.1f mm", d.fitsDiameterMM), color: Palette.clearance, height: labelHeight * 0.85)
        let labAt: SIMD2<Double> = cc - nd * d.circleRadius
        lab.simdPosition = p3(labAt, y1) + SIMD3<Float>(0, labelHeight, 0)
        dims.addChildNode(lab)
    }

    // MARK: Ruler

    private func buildRuler() {
        let mm = data.heightMM + 10
        guard let img = Self.rulerImage(coveringMM: mm) else { return }
        let ticks = RulerTicks.ticks(coveringMM: mm)
        let lengthMM = ticks.last?.mm ?? mm
        let unit = 0.001 / data.scaleFactor // model metres per true millimetre
        let h = lengthMM * unit, w = 22 * unit
        let plane = SCNPlane(width: CGFloat(w), height: CGFloat(h))
        plane.firstMaterial = Self.flatMaterial(img)
        let node = SCNNode(geometry: plane)
        node.simdPosition = SIMD3(0, Float(h / 2), 0)
        ruler.addChildNode(node)
        ruler.simdPosition = SIMD3(Float(-(dialRadius + w)), 0, 0)
        let b = SCNBillboardConstraint()
        b.freeAxes = .Y
        ruler.constraints = [b]
    }

    // MARK: Protractor

    private func buildDial() {
        let r = dialRadius
        if let img = Self.dialImage() {
            let plane = SCNPlane(width: CGFloat(r * 2), height: CGFloat(r * 2))
            plane.firstMaterial = Self.flatMaterial(img)
            plane.firstMaterial?.writesToDepthBuffer = false
            let face = SCNNode(geometry: plane)
            face.eulerAngles.x = -.pi / 2
            face.renderingOrder = -1
            // 0° faces the viewer (+Z); angles count counter-clockwise seen from above.
            let holder = SCNNode()
            holder.eulerAngles.y = .pi
            holder.simdPosition = SIMD3(0, Float(data.extent * 0.002), 0)
            holder.addChildNode(face)
            dial.addChildNode(holder)
        }
        let tip = SIMD3<Float>(0, Float(data.extent * 0.004), Float(r * 0.97))
        needle.addChildNode(Self.line(SIMD3(0, Float(data.extent * 0.004), 0), tip, r: lineRadius * 1.1, color: Palette.needle))
        let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(lineRadius * 4), height: CGFloat(lineRadius * 10))
        cone.firstMaterial = Self.flatMaterial(Palette.needle)
        let head = SCNNode(geometry: cone)
        head.simdPosition = tip
        head.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: SIMD3(0, 0, 1))
        needle.addChildNode(head)
    }

    // MARK: Building blocks

    enum Palette {
        static let height = UIColor(red: 1.0, green: 0.62, blue: 0.1, alpha: 1)
        static let length = UIColor(red: 0.2, green: 0.85, blue: 1.0, alpha: 1)
        static let width = UIColor(red: 1.0, green: 0.35, blue: 0.75, alpha: 1)
        static let footprint = UIColor(white: 1, alpha: 0.6)
        static let cylinder = UIColor(red: 0.35, green: 1.0, blue: 0.45, alpha: 1)
        static let clearance = UIColor(red: 1.0, green: 0.92, blue: 0.3, alpha: 0.85)
        static let needle = UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1)
    }

    static func flatMaterial(_ contents: Any) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = contents
        m.isDoubleSided = true
        return m
    }

    static func perpendicular(_ a: SIMD3<Float>) -> SIMD3<Float> {
        let helper: SIMD3<Float> = abs(a.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        return simd_normalize(simd_cross(a, helper))
    }

    static func orient(_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> simd_quatf {
        let t = simd_normalize(to)
        if simd_dot(from, t) < -0.9999 { return simd_quatf(angle: .pi, axis: perpendicular(from)) }
        return simd_quatf(from: from, to: t)
    }

    static func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, r: Float, color: UIColor) -> SCNNode {
        let d = b - a, len = simd_length(d)
        let cyl = SCNCylinder(radius: CGFloat(r), height: CGFloat(len))
        cyl.radialSegmentCount = 8
        cyl.firstMaterial = flatMaterial(color)
        let n = SCNNode(geometry: cyl)
        n.simdPosition = (a + b) / 2
        if len > 0 { n.simdOrientation = orient(SIMD3(0, 1, 0), d) }
        return n
    }

    static func ring(center: SIMD3<Float>, axis: SIMD3<Float>, radius: Float, pipe: Float, color: UIColor) -> SCNNode {
        let t = SCNTorus(ringRadius: CGFloat(radius), pipeRadius: CGFloat(pipe))
        t.ringSegmentCount = 96
        t.pipeSegmentCount = 8
        t.firstMaterial = flatMaterial(color)
        let n = SCNNode(geometry: t)
        n.simdPosition = center
        n.simdOrientation = orient(SIMD3(0, 1, 0), axis)
        return n
    }

    /// Caliper-style mark: a line with end bars and its value in the middle.
    static func dimension(_ a: SIMD3<Float>, _ b: SIMD3<Float>, text: String, color: UIColor, r: Float,
                          tick: SIMD3<Float>, label h: Float, labelOffset: SIMD3<Float>? = nil) -> SCNNode {
        let g = SCNNode()
        g.addChildNode(line(a, b, r: r, color: color))
        let bar = simd_normalize(tick) * h * 0.35
        g.addChildNode(line(a - bar, a + bar, r: r, color: color))
        g.addChildNode(line(b - bar, b + bar, r: r, color: color))
        let l = label(text, color: color, height: h)
        l.simdPosition = (a + b) / 2 + (labelOffset ?? simd_normalize(tick) * h * 0.9)
        g.addChildNode(l)
        return g
    }

    /// Text that always faces the camera and stays readable through the model.
    static func label(_ text: String, color: UIColor, height: Float) -> SCNNode {
        let img = labelImage(text, color: color)
        let plane = SCNPlane(width: CGFloat(height) * img.size.width / img.size.height, height: CGFloat(height))
        let m = flatMaterial(img)
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        plane.firstMaterial = m
        let n = SCNNode(geometry: plane)
        n.renderingOrder = 100
        n.constraints = [SCNBillboardConstraint()]
        return n
    }

    static func labelImage(_ text: String, color: UIColor) -> UIImage {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 44, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 18
        let box = CGSize(width: ceil(size.width) + pad * 2, height: ceil(size.height) + pad)
        return UIGraphicsImageRenderer(size: box).image { _ in
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: box).insetBy(dx: 2, dy: 2), cornerRadius: box.height / 2)
            UIColor(white: 0.05, alpha: 0.82).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = 4
            path.stroke()
            (text as NSString).draw(at: CGPoint(x: pad, y: pad / 2), withAttributes: attrs)
        }
    }

    /// Blue lab ruler, 22 mm wide, white millimetre marks and centimetre numbers, 0 at the bottom.
    static func rulerImage(coveringMM mm: Double) -> UIImage? {
        let ticks = RulerTicks.ticks(coveringMM: mm)
        guard let total = ticks.last?.mm, total > 0 else { return nil }
        let pxPerMM = CGFloat(Swift.min(16, 4000 / total))
        let size = CGSize(width: 22 * pxPerMM, height: CGFloat(total) * pxPerMM)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.1, green: 0.22, blue: 0.62, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            let font = UIFont.systemFont(ofSize: pxPerMM * 4.2, weight: .semibold)
            for t in ticks {
                let y = size.height - CGFloat(t.mm) * pxPerMM
                let len = pxPerMM * [3.5, 6, 9][t.level]
                ctx.fill(CGRect(x: 0, y: y - pxPerMM * 0.12, width: len, height: pxPerMM * 0.24))
                if let label = t.label, t.mm > 0 {
                    let s = label as NSString
                    let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
                    let sz = s.size(withAttributes: a)
                    s.draw(at: CGPoint(x: len + pxPerMM * 1.5, y: y - sz.height / 2), withAttributes: a)
                }
            }
            let unit = "cm" as NSString
            unit.draw(at: CGPoint(x: pxPerMM * 12, y: size.height - pxPerMM * 5),
                      withAttributes: [.font: UIFont.systemFont(ofSize: pxPerMM * 3, weight: .bold), .foregroundColor: UIColor.white])
        }
    }

    /// 360° protractor seen from above: 1° marks, labels every 30° counter-clockwise (outer) and clockwise (inner),
    /// 0° at the top of the image. Transparent outside the ring.
    static func dialImage(size: CGFloat = 2048) -> UIImage? {
        let c = CGPoint(x: size / 2, y: size / 2), R = size / 2 - 8
        func pt(_ a: CGFloat, _ r: CGFloat) -> CGPoint {
            CGPoint(x: c.x - r * sin(a * .pi / 180), y: c.y - r * cos(a * .pi / 180))
        }
        let accent = UIColor(red: 0.35, green: 0.7, blue: 1, alpha: 1)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: fmt).image { ctx in
            let g = ctx.cgContext
            g.setFillColor(accent.withAlphaComponent(0.13).cgColor)
            g.fillEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
            g.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
            g.setLineWidth(5)
            g.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
            let inner = R * 0.68
            g.setLineWidth(2)
            g.setStrokeColor(accent.withAlphaComponent(0.4).cgColor)
            g.strokeEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
            for a in 0..<360 {
                let L: CGFloat = a % 10 == 0 ? 60 : (a % 5 == 0 ? 40 : 22)
                g.setStrokeColor((a % 10 == 0 ? UIColor.white : accent).withAlphaComponent(a % 10 == 0 ? 0.95 : 0.7).cgColor)
                g.setLineWidth(a % 30 == 0 ? 6 : 2.5)
                g.move(to: pt(CGFloat(a), R - 2))
                g.addLine(to: pt(CGFloat(a), R - 2 - L))
                g.strokePath()
            }
            let big = UIFont.monospacedDigitSystemFont(ofSize: 56, weight: .bold)
            let small = UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .regular)
            for a in stride(from: 0, to: 360, by: 30) {
                for (text, r, font, color) in [("\(a)", R - 110, big, UIColor.white), ("\((360 - a) % 360)", R - 175, small, accent)] {
                    let s = text as NSString
                    let at: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                    let sz = s.size(withAttributes: at)
                    let p = pt(CGFloat(a), r)
                    s.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2), withAttributes: at)
                }
            }
            // Zero reference arm.
            g.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
            g.setLineWidth(4)
            g.setLineDash(phase: 0, lengths: [18, 12])
            g.move(to: pt(0, inner))
            g.addLine(to: pt(0, R - 64))
            g.strokePath()
            g.setLineDash(phase: 0, lengths: [])
            let note = "0° start · + = counter-clockwise" as NSString
            let at: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: UIColor.white.withAlphaComponent(0.85)]
            let sz = note.size(withAttributes: at)
            note.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - inner + 16), withAttributes: at)
        }
    }
}
