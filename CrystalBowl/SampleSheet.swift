import SwiftUI
import SceneKit
import Metal
import ScanMath

/// Virtual sample-preparation images from the 3D model, in two templates:
/// - clean: the four sides, top and bottom on white with one scale bar, like the lab's photo slides but tidy;
/// - scientific: the same views with rulers, measured sizes, view angles counted from the reference mark,
///   a protractor round the top view, the unrolled 360° side image and a data box.
/// 0° is the reference mark (the red/black line facing the X-ray source) when one was found or set; otherwise
/// the protractor angle the user chose. + = the sample turned counter-clockwise seen from above (SliceLock).
/// Drawing helpers are not tied to the main thread (the Pieces pictures use them in the background).
enum SampleSheet {
    struct View3D {
        let id: String
        /// Signed angle from the reference (0, +90, ±180, −90), or nil for top/bottom.
        let offset: Double?
        let title: String
        let image: UIImage
        let pxPerMM: Double
        /// Pixel row of the sample's base (side views) or centre (top/bottom).
        let baseY: Double
        /// Silhouette in pixels.
        let box: CGRect
    }

    struct Output {
        let views: [View3D]
        /// Each view as a picture of its own, with ruler, scale and mark (3.8).
        let figures: [Figure]
        let options: SheetOptions
        let clean: UIImage
        let scientific: UIImage
        let unrolled: UIImage?
        let reference: Double
        let referenceIsMark: Bool
        let json: [String: Any]
    }

    static let pixels: CGFloat = 1000
    static let ink = UIColor(white: 0.1, alpha: 1)
    static let accent = UIColor(red: 0.12, green: 0.3, blue: 0.75, alpha: 1)
    static let markRed = UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)

    // MARK: Rendering

    @MainActor
    static func renderViews(rig: SampleRig, reference: Double) -> [View3D] {
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
        var out: [View3D] = []
        let sideScale = Swift.max(H, 2 * Rc) * 0.6
        let pxPerUnit = Double(pixels) / (2 * sideScale)
        for v in [0.0, 90, 180, -90] {
            holder.simdOrientation = simd_quatf(angle: Float((reference + v) * .pi / 180), axis: SIMD3(0, 1, 0))
            cam.simdPosition = SIMD3(0, Float(H / 2), 2)
            cam.simdOrientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
            cam.camera?.orthographicScale = sideScale
            let shot = renderer.snapshot(atTime: 0, with: CGSize(width: pixels, height: pixels), antialiasingMode: .multisampling4X)
            let title = v == 0 ? "0°" : (v == 180 ? "180°" : String(format: "%+.0f°", v))
            out.append(View3D(id: "side" + Rotation.token(v).replacingOccurrences(of: "Rot_", with: ""), offset: v, title: title, image: shot,
                              pxPerMM: pxPerUnit * unitPerMM, baseY: Double(pixels) / 2 + H / 2 * pxPerUnit, box: silhouette(shot)))
        }
        holder.simdOrientation = simd_quatf(angle: Float(reference * .pi / 180), axis: SIMD3(0, 1, 0))
        let flatScale = Rc * 1.25
        let flatPx = Double(pixels) / (2 * flatScale)
        for (id, title, y, tilt) in [("top", "Top", H + 2, -Double.pi / 2), ("bottom", "Bottom", -2.0, Double.pi / 2)] {
            cam.simdPosition = SIMD3(0, Float(y), 0)
            cam.simdOrientation = simd_quatf(angle: Float(tilt), axis: SIMD3(1, 0, 0))
            cam.camera?.orthographicScale = flatScale
            let shot = renderer.snapshot(atTime: 0, with: CGSize(width: pixels, height: pixels), antialiasingMode: .multisampling4X)
            out.append(View3D(id: id, offset: nil, title: title, image: shot, pxPerMM: flatPx * unitPerMM,
                              baseY: Double(pixels) / 2, box: silhouette(shot)))
        }
        return out
    }

    /// Bounding box of the non-white pixels.
    static func silhouette(_ img: UIImage) -> CGRect {
        guard let cg = img.cgImage else { return .zero }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return .zero }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var x0 = w, x1 = -1, y0 = h, y1 = -1
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let o = (y * w + x) * 4
                if Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2]) < 735 {
                    x0 = Swift.min(x0, x); x1 = Swift.max(x1, x)
                    y0 = Swift.min(y0, y); y1 = Swift.max(y1, y)
                }
            }
        }
        guard x1 >= x0, y1 >= y0 else { return .zero }
        let s = CGFloat(pixels) / CGFloat(w)
        return CGRect(x: CGFloat(x0) * s, y: CGFloat(y0) * s, width: CGFloat(x1 - x0 + 2) * s, height: CGFloat(y1 - y0 + 2) * s)
    }

    // MARK: Building both sheets

    @MainActor
    static func make(rig: SampleRig, scan: Scan, reference: Double, referenceIsMark: Bool, unrolled: Unroller.Result?,
                     options: SheetOptions = .current) -> Output {
        var views = renderViews(rig: rig, reference: reference)
        // No bottom view when the underside was never photographed: it would only show a guessed flat face (3.7).
        if !showsBottom(scan, views.first { $0.id == "bottom" }) { views.removeAll { $0.id == "bottom" } }
        // Only the views ticked in "What to include" (3.8).
        views.removeAll { v in
            if let off = v.offset { return !options.has(SheetItem.side(off)) }
            return !options.has(v.id == "top" ? .top : .bottom)
        }
        let unit = UnitPref.unit
        let ref = Rotation.normalized(reference)
        let unrolledImage = unrolled.map { centred($0, on: ref) }
        let figures = self.figures(views, scan: scan, rig: rig, unit: unit, reference: ref, referenceIsMark: referenceIsMark,
                                   unrolled: unrolled, unrolledImage: unrolledImage, opt: options)
        let clean = cleanSheet(views, scan: scan, unit: unit, referenceIsMark: referenceIsMark, opt: options)
        let sci = scientificSheet(figures, scan: scan, unit: unit, reference: ref, referenceIsMark: referenceIsMark, opt: options)
        var sides: [[String: Any]] = []
        for v in views {
            sides.append(["id": v.id, "title": v.title, "angle_from_reference_deg": v.offset ?? NSNull(),
                          "px_per_mm": v.pxPerMM, "width_mm": Double(v.box.width) / v.pxPerMM, "height_mm": Double(v.box.height) / v.pxPerMM])
        }
        var json: [String: Any] = [
            "schema": "crystal-bowl.sample-sheet/1",
            "reference_protractor_deg": ref, "reference": referenceIsMark ? "mark" : "chosen angle",
            "convention": "view angle = how far the sample is turned from the reference, + = counter-clockwise seen from above",
            "views": sides, "display_unit": unit.rawValue,
        ]
        if let u = unrolled {
            json["unrolled"] = ["px_per_mm": u.pxPerMM, "height_mm": u.heightMM, "circumference_mm": u.circumferenceMM,
                                "columns": "centre = reference; angle decreases left to right (the surface as seen from outside)"]
        }
        if let m = scan.mark { json["mark"] = m.json() }
        json["included"] = SheetItem.allCases.filter { options.has($0) }.map(\.rawValue)
        return Output(views: views, figures: figures, options: options, clean: clean, scientific: sci, unrolled: unrolledImage, reference: ref,
                      referenceIsMark: referenceIsMark, json: json)
    }

    /// The unrolled image turned so the reference sits in the middle.
    static func centred(_ u: Unroller.Result, on ref: Double) -> UIImage {
        guard let cg = u.image.cgImage else { return u.image }
        let w = cg.width, h = cg.height
        var r = ref
        if r < 0 { r += 360 }
        // Column of the reference angle (angles decrease left to right from 360 at x = 0).
        let xRef = Int((Double(w) - r / 360 * Double(w)).rounded())
        let shift = w / 2 - xRef
        let size = CGSize(width: w, height: h)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            for k in [-1, 0, 1] {
                u.image.draw(at: CGPoint(x: CGFloat(shift + k * w), y: 0))
            }
        }
    }

    // MARK: Drawing helpers

    static func text(_ s: String, at p: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = ink,
                     align: NSTextAlignment = .left, mono: Bool = false) {
        let font = mono ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : UIFont.systemFont(ofSize: size, weight: weight)
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = s as NSString
        let sz = str.size(withAttributes: a)
        var o = p
        if align == .center { o.x -= sz.width / 2 }
        if align == .right { o.x -= sz.width }
        str.draw(at: o, withAttributes: a)
    }

    /// Vertical ruler in the chosen unit, 0 at `baseY`, drawn to `pxPerMM`.
    static func ruler(_ g: CGContext, x: CGFloat, baseY: CGFloat, pxPerMM: CGFloat, mm: Double, unit: LengthUnit, width: CGFloat = 70) {
        let ticks = RulerTicks.ticks(coveringMM: mm, unit: unit)
        guard let total = ticks.last?.mm else { return }
        let top = baseY - CGFloat(total) * pxPerMM
        g.setFillColor(UIColor(white: 0.97, alpha: 1).cgColor)
        g.fill(CGRect(x: x, y: top - 8, width: width, height: baseY - top + 16))
        g.setStrokeColor(ink.cgColor)
        g.setLineWidth(1.5)
        g.stroke(CGRect(x: x, y: top - 8, width: width, height: baseY - top + 16))
        let fine = pxPerMM * CGFloat(unit.mmPerUnit == 25.4 ? 2.54 : 1) >= 3
        for t in ticks where fine || t.level > 0 {
            let y = baseY - CGFloat(t.mm) * pxPerMM
            let len = width * [0.2, 0.35, 0.5][t.level]
            g.setLineWidth(t.level == 2 ? 2 : 1)
            g.move(to: CGPoint(x: x + width - len, y: y))
            g.addLine(to: CGPoint(x: x + width, y: y))
            g.strokePath()
            if let label = t.label {
                text(label, at: CGPoint(x: x + 4, y: y - 11), size: 18, weight: .medium, mono: true)
            }
        }
        text(unit.rulerCaption, at: CGPoint(x: x + 4, y: baseY + 10), size: 18, weight: .bold, color: accent)
    }

    /// Horizontal scale bar of a round length in the unit.
    static func scaleBar(_ g: CGContext, at p: CGPoint, pxPerMM: CGFloat, unit: LengthUnit, maxWidth: CGFloat) {
        let candidates: [Double] = unit == .inch ? [0.25, 0.5, 1, 2] : (unit == .m ? [0.005, 0.01, 0.02, 0.05] : [0.5, 1, 2, 5, 10])
        // Lengths in the unit; metric bars counted in cm for cm/m, mm for mm.
        let inMM: [Double] = candidates.map { unit == .mm ? $0 * 10 : unit.mm($0) }
        var pick: (Double, Double) = (candidates[0], inMM[0])
        for (c, m) in zip(candidates, inMM) where CGFloat(m) * pxPerMM <= maxWidth { pick = (c, m) }
        let w = CGFloat(pick.1) * pxPerMM
        g.setFillColor(ink.cgColor)
        g.fill(CGRect(x: p.x, y: p.y, width: w, height: 6))
        g.fill(CGRect(x: p.x, y: p.y - 8, width: 3, height: 22))
        g.fill(CGRect(x: p.x + w - 3, y: p.y - 8, width: 3, height: 22))
        let label = unit == .mm ? String(format: "%.0f mm", pick.1) : unit.format(pick.1, decimals: pick.0 < 1 ? 2 : 0)
        text(label, at: CGPoint(x: p.x + w / 2, y: p.y + 12), size: 22, weight: .semibold, align: .center)
    }

    /// Dimension line with end bars and its value.
    static func dimension(_ g: CGContext, from a: CGPoint, to b: CGPoint, label: String, color: UIColor, labelOffset: CGPoint) {
        g.setStrokeColor(color.cgColor)
        g.setLineWidth(2.5)
        g.move(to: a)
        g.addLine(to: b)
        g.strokePath()
        let dx = b.x - a.x, dy = b.y - a.y
        let l = Swift.max(1, (dx * dx + dy * dy).squareRoot())
        let nx = -dy / l * 10, ny = dx / l * 10
        for p in [a, b] {
            g.move(to: CGPoint(x: p.x - nx, y: p.y - ny))
            g.addLine(to: CGPoint(x: p.x + nx, y: p.y + ny))
            g.strokePath()
        }
        let mid = CGPoint(x: (a.x + b.x) / 2 + labelOffset.x, y: (a.y + b.y) / 2 + labelOffset.y)
        text(label, at: mid, size: 22, weight: .bold, color: color, align: .center, mono: true)
    }

    /// Small dial: the reference mark in red at the bottom, the camera direction for this view as an arrow.
    static func miniDial(_ g: CGContext, centre c: CGPoint, radius r: CGFloat, viewOffset v: Double) {
        g.setStrokeColor(ink.withAlphaComponent(0.7).cgColor)
        g.setLineWidth(2)
        g.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        for k in 0..<12 {
            let a = CGFloat(k) * .pi / 6
            g.move(to: CGPoint(x: c.x + r * sin(a), y: c.y + r * cos(a)))
            g.addLine(to: CGPoint(x: c.x + r * 0.85 * sin(a), y: c.y + r * 0.85 * cos(a)))
            g.strokePath()
        }
        // Mark at 6 o'clock (it faces the viewer at 0°).
        g.setFillColor(markRed.cgColor)
        g.fillEllipse(in: CGRect(x: c.x - 6, y: c.y + r - 6, width: 12, height: 12))
        // The camera for a +v view sits v clockwise from the mark on this top-down dial.
        let a = CGFloat(v) * .pi / 180
        let dir = CGPoint(x: -sin(a), y: cos(a))
        let tail = CGPoint(x: c.x + dir.x * r * 1.35, y: c.y + dir.y * r * 1.35)
        let tip = CGPoint(x: c.x + dir.x * r * 0.45, y: c.y + dir.y * r * 0.45)
        g.setStrokeColor(accent.cgColor)
        g.setLineWidth(3.5)
        g.move(to: tail)
        g.addLine(to: tip)
        g.strokePath()
        let back = CGPoint(x: dir.x * 12, y: dir.y * 12), side = CGPoint(x: -dir.y * 8, y: dir.x * 8)
        g.setFillColor(accent.cgColor)
        g.move(to: tip)
        g.addLine(to: CGPoint(x: tip.x + back.x + side.x, y: tip.y + back.y + side.y))
        g.addLine(to: CGPoint(x: tip.x + back.x - side.x, y: tip.y + back.y - side.y))
        g.closePath()
        g.fillPath()
    }

    /// Where the mark sits in a side view: across the silhouette, solid when facing the camera.
    static func markTick(_ g: CGContext, view v: View3D, in rect: CGRect, scale s: CGFloat) {
        guard let off = v.offset else { return }
        let a = off * .pi / 180
        let cx = rect.minX + (v.box.midX) * s
        let half = v.box.width / 2 * s
        let x = cx + CGFloat(sin(a)) * half
        let facing = cos(a) > 0.05
        let y = rect.minY + v.box.minY * s - 8
        g.setFillColor(markRed.cgColor)
        g.setStrokeColor(markRed.cgColor)
        g.setLineWidth(2.5)
        g.move(to: CGPoint(x: x, y: y))
        g.addLine(to: CGPoint(x: x - 11, y: y - 20))
        g.addLine(to: CGPoint(x: x + 11, y: y - 20))
        g.closePath()
        if facing && abs(sin(a)) < 0.95 { g.fillPath() } else { g.strokePath() }
    }

    // MARK: Text that fits

    static func font(_ size: CGFloat, _ weight: UIFont.Weight, mono: Bool = false) -> UIFont {
        mono ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : UIFont.systemFont(ofSize: size, weight: weight)
    }

    static func width(_ s: String, size: CGFloat, weight: UIFont.Weight = .regular, mono: Bool = false) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font(size, weight, mono: mono)]).width
    }

    /// The largest size up to `size` at which the text fits in `maxWidth` (never below 12 pt).
    static func fitted(_ s: String, size: CGFloat, weight: UIFont.Weight = .regular, maxWidth: CGFloat, mono: Bool = false) -> CGFloat {
        var z = size
        while z > 12 && width(s, size: z, weight: weight, mono: mono) > maxWidth { z -= 1 }
        return z
    }

    /// Splits text into lines no wider than `maxWidth`.
    static func wrapped(_ s: String, size: CGFloat, weight: UIFont.Weight = .regular, maxWidth: CGFloat) -> [String] {
        var lines: [String] = [], line = ""
        for word in s.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            let candidate = line.isEmpty ? word : line + " " + word
            if !line.isEmpty && width(candidate, size: size, weight: weight) > maxWidth {
                lines.append(line)
                line = word
            } else {
                line = candidate
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    // MARK: Figures (one picture each, with its own ruler and scale; 3.8)

    /// One picture of the sample sheet, complete on its own.
    struct Figure {
        let id: String
        let image: UIImage
    }

    static let figurePad: CGFloat = 28
    static let sideSize: CGFloat = 640

    static func sideTitle(_ v: View3D, referenceIsMark: Bool) -> String {
        guard let off = v.offset else { return v.title }
        if off == 0 { return referenceIsMark ? "0° · the mark facing you" : "0°" }
        return v.title + " from 0°"
    }

    /// A side view: title strip on top, ruler in its own column on the left, height on the right, width and the
    /// scale bar underneath. Nothing is drawn over the rock except the thin mark arrow above it.
    static func sideFigure(_ v: View3D, scan: Scan, rig: SampleRig, unit: LengthUnit, reference: Double,
                           referenceIsMark: Bool, opt: SheetOptions) -> UIImage {
        let pad = figurePad, S = sideSize
        let s = S / pixels
        let d = rig.data
        let ppm = CGFloat(v.pxPerMM) * s
        let rulerW: CGFloat = opt.has(.rulers) ? 96 : 0
        let rightW: CGFloat = opt.has(.sizeLines) ? 180 : pad
        let headerH: CGFloat = opt.has(.angleCaptions) || opt.has(.dials) ? 124 : pad
        let baseInImage = CGFloat(v.baseY) * s
        let box = CGRect(x: v.box.minX * s, y: v.box.minY * s, width: v.box.width * s, height: v.box.height * s)
        // The ruler may reach above the picture: the picture moves down so it stays on the figure.
        var rulerTop: CGFloat = 0
        if opt.has(.rulers), let total = RulerTicks.ticks(coveringMM: d.heightMM + 3, unit: unit).last?.mm {
            rulerTop = baseInImage - CGFloat(total) * ppm - 24
        }
        let arrowTop: CGFloat = opt.has(.markArrows) ? box.minY - 34 : box.minY
        let imgY = Swift.max(headerH, headerH - Swift.min(rulerTop, arrowTop) + 6)
        let img = CGRect(x: pad + rulerW, y: imgY, width: S, height: S)
        var y = img.maxY
        let widthLineY = img.minY + box.maxY + 30
        if opt.has(.sizeLines) { y = Swift.max(y, widthLineY + 44) }
        let barY = y + 34
        let height = (opt.has(.scaleBars) ? barY + 64 : y + 16) + pad
        let size = CGSize(width: img.maxX + rightW, height: height)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let g = ctx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            v.image.draw(in: img)
            if opt.has(.angleCaptions) {
                let maxW = size.width - img.minX - (opt.has(.dials) ? 130 : pad)
                let title = sideTitle(v, referenceIsMark: referenceIsMark)
                text(title, at: CGPoint(x: img.minX, y: pad - 6), size: fitted(title, size: 32, weight: .bold, maxWidth: maxW), weight: .bold)
                var sub = "protractor " + Rotation.text(reference + (v.offset ?? 0))
                if opt.has(.header) { sub += " · " + scan.name }
                text(sub, at: CGPoint(x: img.minX, y: pad + 40), size: fitted(sub, size: 21, maxWidth: maxW), color: .darkGray, mono: true)
            }
            if opt.has(.dials) {
                miniDial(g, centre: CGPoint(x: size.width - pad - 50, y: pad + 46), radius: 40, viewOffset: v.offset ?? 0)
            }
            if opt.has(.rulers) {
                ruler(g, x: pad, baseY: img.minY + baseInImage, pxPerMM: ppm, mm: d.heightMM + 3, unit: unit, width: 64)
            }
            let b = box.offsetBy(dx: img.minX, dy: img.minY)
            if opt.has(.sizeLines) {
                let hMM = Double(v.box.height) / v.pxPerMM, wMM = Double(v.box.width) / v.pxPerMM
                let hx = b.maxX + 26
                let hc = SampleRig.Palette.height.darker()
                dimension(g, from: CGPoint(x: hx, y: b.minY), to: CGPoint(x: hx, y: b.maxY), label: "", color: hc, labelOffset: .zero)
                text(unit.format(hMM), at: CGPoint(x: hx + 16, y: b.midY - 14), size: 24, weight: .bold, color: hc, mono: true)
                dimension(g, from: CGPoint(x: b.minX, y: widthLineY), to: CGPoint(x: b.maxX, y: widthLineY), label: "", color: accent, labelOffset: .zero)
                text(unit.format(wMM), at: CGPoint(x: b.midX, y: widthLineY + 12), size: 24, weight: .bold, color: accent, align: .center, mono: true)
            }
            if opt.has(.markArrows) { markTick(g, view: v, in: img, scale: s) }
            if opt.has(.scaleBars) {
                scaleBar(g, at: CGPoint(x: img.minX, y: barY), pxPerMM: ppm, unit: unit, maxWidth: S * 0.45)
            }
        }
    }

    /// Top or bottom: the protractor ring (top), the mark direction, diameter and scale bar below.
    static func endFigure(_ v: View3D, scan: Scan, rig: SampleRig, unit: LengthUnit, opt: SheetOptions) -> UIImage {
        let pad = figurePad
        let isTop = v.id == "top"
        let area: CGFloat = 720, inner: CGFloat = 480
        let headerH: CGFloat = opt.has(.angleCaptions) ? 112 : pad
        let region = CGRect(x: pad, y: headerH, width: area, height: area)
        let img = CGRect(x: region.midX - inner / 2, y: region.midY - inner / 2, width: inner, height: inner)
        let s = inner / pixels
        let ppm = CGFloat(v.pxPerMM) * s
        let d = rig.data
        let k = scan.scaleFactor
        let barY = region.maxY + 30
        let size = CGSize(width: region.maxX + pad, height: (opt.has(.scaleBars) || opt.has(.sizeLines) ? barY + 70 : region.maxY) + pad)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let g = ctx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            v.image.draw(in: img)
            let c = CGPoint(x: img.midX, y: img.midY)
            if opt.has(.angleCaptions) {
                let title = isTop ? "Top (seen from above)" : "Bottom (seen from below)"
                text(title, at: CGPoint(x: pad, y: pad - 6), size: 32, weight: .bold)
                var sub = isTop ? "0° (the mark) at the bottom · + = counter-clockwise" : "0° (the mark) at the top edge"
                if opt.has(.header) { sub += " · " + scan.name }
                text(sub, at: CGPoint(x: pad, y: pad + 40), size: fitted(sub, size: 21, maxWidth: area), color: .darkGray)
            }
            if isTop && opt.has(.protractor) {
                let R = CGFloat(d.circleRadius * 1000 * k) * ppm * 1.06
                protractor(g, centre: c, radius: R)
            } else if opt.has(.markArrows) {
                // Where the mark is: bottom edge from above, top edge from below.
                let yTip: CGFloat = isTop ? img.maxY + 10 : img.minY - 10
                let dir: CGFloat = isTop ? 1 : -1
                g.setFillColor(markRed.cgColor)
                g.move(to: CGPoint(x: c.x, y: yTip))
                g.addLine(to: CGPoint(x: c.x - 13, y: yTip + dir * 24))
                g.addLine(to: CGPoint(x: c.x + 13, y: yTip + dir * 24))
                g.closePath()
                g.fillPath()
                text("0°", at: CGPoint(x: c.x + 20, y: yTip + (isTop ? 0 : -24)), size: 22, weight: .bold, color: markRed)
            }
            if opt.has(.sizeLines) {
                let dia = d.shape?.kind == .cylinder ? d.shape!.diameter * 1000 * k : d.fitsDiameterMM
                text("Ø " + unit.format(dia), at: CGPoint(x: region.maxX, y: barY - 4), size: 26, weight: .bold, color: accent, align: .right, mono: true)
            }
            if opt.has(.scaleBars) {
                scaleBar(g, at: CGPoint(x: region.minX, y: barY + 6), pxPerMM: ppm, unit: unit, maxWidth: area * 0.4)
            }
        }
    }

    /// The unrolled side with its ruler, angle axis (0° = the mark in the middle) and captions.
    static func unrolledFigure(_ img0: UIImage, _ u: Unroller.Result, scan: Scan, unit: LengthUnit, opt: SheetOptions) -> UIImage {
        let pad = figurePad
        let k = Swift.min(1.4, 1400 / Swift.max(1, img0.size.width))
        let rulerW: CGFloat = opt.has(.rulers) ? 100 : 0
        let headerH: CGFloat = opt.has(.angleCaptions) ? 112 : pad + (opt.has(.markArrows) ? 30 : 0)
        let img = CGRect(x: pad + rulerW, y: headerH + 10, width: img0.size.width * k, height: img0.size.height * k)
        let ppm = img.height / CGFloat(u.heightMM)
        var rulerTop: CGFloat = img.minY
        if opt.has(.rulers), let total = RulerTicks.ticks(coveringMM: u.heightMM, unit: unit).last?.mm {
            rulerTop = img.maxY - CGFloat(total) * ppm - 24
        }
        let shift = Swift.max(0, headerH - rulerTop)
        let r = img.offsetBy(dx: 0, dy: shift)
        let captionY = r.maxY + (opt.has(.angleCaptions) ? 52 : 16)
        let size = CGSize(width: r.maxX + pad + 20, height: captionY + (opt.has(.angleCaptions) ? 64 : 0) + pad)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let g = ctx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            img0.draw(in: r)
            g.setStrokeColor(UIColor(white: 0.7, alpha: 1).cgColor)
            g.setLineWidth(1.5)
            g.stroke(r)
            if opt.has(.angleCaptions) {
                text("Unrolled side, 360°", at: CGPoint(x: r.minX, y: pad - 6), size: 32, weight: .bold)
                var sub = "0° = the mark, in the middle · + to the left · circumference " + unit.format(u.circumferenceMM)
                if opt.has(.header) { sub += " · " + scan.name }
                text(sub, at: CGPoint(x: r.minX, y: pad + 40), size: fitted(sub, size: 21, maxWidth: size.width - r.minX - pad), color: .darkGray)
            }
            if opt.has(.rulers) { ruler(g, x: pad, baseY: r.maxY, pxPerMM: ppm, mm: u.heightMM, unit: unit, width: 64) }
            if opt.has(.angleCaptions) {
                for a in stride(from: -180, through: 180, by: 30) {
                    let x = r.midX - CGFloat(a) / 360 * r.width
                    g.setStrokeColor((a == 0 ? markRed : UIColor(white: 0.25, alpha: 0.35)).cgColor)
                    g.setLineWidth(a == 0 ? 2.5 : 1)
                    g.setLineDash(phase: 0, lengths: a == 0 ? [] : [8, 8])
                    g.move(to: CGPoint(x: x, y: r.minY))
                    g.addLine(to: CGPoint(x: x, y: r.maxY))
                    g.strokePath()
                    g.setLineDash(phase: 0, lengths: [])
                    if a % 90 == 0 {
                        text(a == 0 ? "0°" : (abs(a) == 180 ? "180°" : String(format: "%+d°", a)), at: CGPoint(x: x, y: r.maxY + 12),
                             size: 22, weight: .bold, color: a == 0 ? markRed : ink, align: .center)
                    }
                }
                let note = "Seen from outside: angles decrease left to right; the strip under +90° is what the +90° view faces."
                text(note, at: CGPoint(x: r.minX, y: captionY), size: fitted(note, size: 20, maxWidth: r.width), color: .darkGray)
            }
            if opt.has(.markArrows) {
                g.setFillColor(markRed.cgColor)
                g.move(to: CGPoint(x: r.midX, y: r.minY - 4))
                g.addLine(to: CGPoint(x: r.midX - 12, y: r.minY - 26))
                g.addLine(to: CGPoint(x: r.midX + 12, y: r.minY - 26))
                g.closePath()
                g.fillPath()
            }
        }
    }

    /// Measurements and orientation as a picture of its own, every line wrapped to fit.
    static func measurementsFigure(scan: Scan, rig: SampleRig, unit: LengthUnit, reference: Double, opt: SheetOptions) -> UIImage {
        let pad = figurePad + 8
        let w: CGFloat = 1100
        let d = rig.data
        let k = scan.scaleFactor
        var lines: [(String, Bool)] = [("Measurements", true)]
        lines.append(("Height " + unit.format(d.heightMM) + " · footprint " + unit.formatList([d.lengthMM, d.widthMM]), false))
        if let sh = scan.shape { lines.append((sh.text(scale: k), false)) }
        lines.append(("Fits an upright cylinder of Ø " + unit.format(d.fitsDiameterMM) + " (micro-CT clearance)", false))
        if let st = scan.stats {
            lines.append(("Volume " + unit.formatVolume(cm3: st.volumeCM3 * k * k * k) + (st.isClosed ? "" : " (approximate: mesh has gaps)"), false))
            lines.append(("Smallest box a × b × c " + unit.formatList([st.axisA * k, st.axisB * k, st.axisC * k]), false))
        }
        lines.append(("Scale: " + (scan.caliper == nil ? "LiDAR" : String(format: "caliper-corrected × %.4f", k)), false))
        lines.append(("Orientation", true))
        if let m = scan.mark {
            lines.append((m.summary, false))
            if !m.isTrusted { lines.append(("Low confidence: check that the 0° view shows the mark, or set it by hand in Measure in 3D.", false)) }
        } else {
            lines.append(("No reference mark found. Views count from protractor " + Rotation.text(reference) + ". Set the mark by hand in Measure in 3D.", false))
        }
        lines.append(("0° is the side that faced the X-ray source. File token for this orientation: " + Rotation.token(reference), false))
        lines.append(("About these images", true))
        lines.append(("Orthographic renders of the photogrammetry model (surface only, not CT). Every side view shares one scale; rulers and sizes are true size; silhouette sizes are measured on each view.", false))
        var rows: [(String, Bool)] = []
        for (l, bold) in lines {
            for part in wrapped(l, size: bold ? 30 : 24, weight: bold ? .bold : .regular, maxWidth: w - 2 * pad) { rows.append((part, bold)) }
        }
        var h = pad
        for (i, r) in rows.enumerated() { h += r.1 ? (i == 0 ? 44 : 56) : 34 }
        let size = CGSize(width: w, height: h + pad)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor(white: 0.965, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            var y = pad
            for (i, r) in rows.enumerated() {
                if r.1 && i > 0 { y += 12 }
                text(r.0, at: CGPoint(x: pad, y: y), size: r.1 ? 30 : 24, weight: r.1 ? .bold : .regular, color: r.1 ? accent : ink)
                y += r.1 ? 44 : 34
            }
        }
    }

    @MainActor
    static func figures(_ views: [View3D], scan: Scan, rig: SampleRig, unit: LengthUnit, reference: Double, referenceIsMark: Bool,
                        unrolled: Unroller.Result?, unrolledImage: UIImage?, opt: SheetOptions) -> [Figure] {
        var out: [Figure] = []
        for v in views where v.offset != nil {
            out.append(Figure(id: v.id, image: sideFigure(v, scan: scan, rig: rig, unit: unit, reference: reference,
                                                          referenceIsMark: referenceIsMark, opt: opt)))
        }
        for v in views where v.offset == nil {
            out.append(Figure(id: v.id, image: endFigure(v, scan: scan, rig: rig, unit: unit, opt: opt)))
        }
        if opt.has(.unrolled), let img = unrolledImage, let u = unrolled {
            out.append(Figure(id: "unrolled", image: unrolledFigure(img, u, scan: scan, unit: unit, opt: opt)))
        }
        if opt.has(.measurements) {
            out.append(Figure(id: "measurements", image: measurementsFigure(scan: scan, rig: rig, unit: unit, reference: reference, opt: opt)))
        }
        return out
    }

    // MARK: Clean template

    static func cleanSheet(_ views: [View3D], scan: Scan, unit: LengthUnit, referenceIsMark: Bool, opt: SheetOptions) -> UIImage {
        let panel: CGFloat = 560, gap: CGFloat = 36
        let headLines = opt.has(.header)
        let head: CGFloat = headLines ? 160 : 40
        let n = Swift.max(1, views.count)
        let size = CGSize(width: CGFloat(n) * (panel + gap) + gap, height: head + panel + (opt.has(.scaleBars) ? 190 : 90))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let g = ctx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if headLines {
                text(scan.name, at: CGPoint(x: gap, y: 32), size: fitted(scan.name, size: 54, weight: .semibold, maxWidth: size.width - 2 * gap), weight: .semibold)
                let sub = (referenceIsMark ? "0° = reference mark (side facing the X-ray source)" : "0° = chosen start angle")
                    + " · + = turned counter-clockwise seen from above · virtual views, true scale"
                text(sub, at: CGPoint(x: gap, y: 100), size: fitted(sub, size: 24, maxWidth: size.width - 2 * gap), color: .darkGray)
            }
            let s = panel / pixels
            for (i, v) in views.enumerated() {
                let r = CGRect(x: gap + CGFloat(i) * (panel + gap), y: head, width: panel, height: panel)
                v.image.draw(in: r)
                if v.offset != nil && opt.has(.markArrows) { markTick(g, view: v, in: r, scale: s) }
                if opt.has(.angleCaptions) {
                    let caption = v.offset == 0 && referenceIsMark ? "0° · mark" : v.title
                    text(caption, at: CGPoint(x: r.midX, y: r.maxY + 14), size: 30, weight: .semibold, align: .center)
                }
            }
            if opt.has(.scaleBars) {
                if let first = views.first(where: { $0.offset != nil }) {
                    scaleBar(g, at: CGPoint(x: gap, y: head + panel + 90), pxPerMM: CGFloat(first.pxPerMM) * s, unit: unit, maxWidth: panel * 0.6)
                    text("side views", at: CGPoint(x: gap, y: head + panel + 136), size: 18, color: .gray)
                }
                if let idx = views.firstIndex(where: { $0.offset == nil }) {
                    let end = views[idx]
                    let x = gap + CGFloat(idx) * (panel + gap)
                    scaleBar(g, at: CGPoint(x: x, y: head + panel + 90), pxPerMM: CGFloat(end.pxPerMM) * s, unit: unit, maxWidth: panel * 0.6)
                    text(views.contains { $0.id == "bottom" } && views.contains { $0.id == "top" } ? "top and bottom" : end.title.lowercased(),
                         at: CGPoint(x: x, y: head + panel + 136), size: 18, color: .gray)
                }
            }
        }
    }

    // MARK: Scientific template: the figures laid out on one page

    static func scientificSheet(_ figures: [Figure], scan: Scan, unit: LengthUnit, reference: Double, referenceIsMark: Bool,
                                opt: SheetOptions) -> UIImage {
        let margin: CGFloat = 50, gap: CGFloat = 30
        let sides = figures.filter { $0.id.hasPrefix("side") }
        let ends = figures.filter { $0.id == "top" || $0.id == "bottom" }
        let rest = figures.filter { $0.id == "measurements" }
        let unrolled = figures.filter { $0.id == "unrolled" }
        let rows: [[Figure]] = [sides, ends + rest, unrolled].filter { !$0.isEmpty }
        func rowWidth(_ r: [Figure]) -> CGFloat { r.reduce(0) { $0 + $1.image.size.width } + gap * CGFloat(Swift.max(0, r.count - 1)) }
        let contentW = Swift.max(900, rows.map(rowWidth).max() ?? 900)
        let width = contentW + 2 * margin
        var headerLines: [(String, CGFloat, UIFont.Weight, UIColor)] = []
        if opt.has(.header) {
            headerLines.append((scan.name, fitted(scan.name, size: 64, weight: .bold, maxWidth: contentW), .bold, ink))
            let date = scan.created.formatted(date: .abbreviated, time: .shortened)
            let info = "Virtual sample sheet · scanned \(date) · Crystal Bowl \(AppInfo.version) (\(AppInfo.build)) · lengths in \(unit.name.lowercased())"
            for l in wrapped(info, size: 26, maxWidth: contentW) { headerLines.append((l, 26, .regular, .darkGray)) }
        }
        let refText = (referenceIsMark ? "0° = reference mark (the side that faced the X-ray source)" : "0° = start angle chosen by hand (no mark found)")
            + " · view angle = sample turned from 0°, + = counter-clockwise seen from above (SliceLock convention)"
        for l in wrapped(refText, size: 26, weight: .semibold, maxWidth: contentW) { headerLines.append((l, 26, .semibold, accent)) }
        var headH = margin
        for h in headerLines { headH += h.1 * 1.45 }
        headH += 24
        var height = headH + 20
        for r in rows { height += (r.map { $0.image.size.height }.max() ?? 0) + gap }
        height += 70
        let size = CGSize(width: width, height: height)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let g = ctx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            var y = margin
            for h in headerLines {
                text(h.0, at: CGPoint(x: margin, y: y), size: h.1, weight: h.2, color: h.3)
                y += h.1 * 1.45
            }
            g.setFillColor(accent.cgColor)
            g.fill(CGRect(x: margin, y: headH - 10, width: contentW, height: 4))
            y = headH + 20
            for r in rows {
                var x = margin
                for f in r {
                    let rect = CGRect(origin: CGPoint(x: x, y: y), size: f.image.size)
                    f.image.draw(in: rect)
                    g.setStrokeColor(UIColor(white: 0.82, alpha: 1).cgColor)
                    g.setLineWidth(1.5)
                    g.stroke(rect)
                    x += f.image.size.width + gap
                }
                y += (r.map { $0.image.size.height }.max() ?? 0) + gap
            }
            let foot = "Crystal Bowl Scanner · \(scan.id) · \(Rotation.token(reference)) · virtual images, not CT"
            text(foot, at: CGPoint(x: margin, y: size.height - 56), size: fitted(foot, size: 20, maxWidth: contentW), color: .gray)
        }
    }

    /// Protractor ring round the top view: 0° (the mark) at the bottom; labels give the view angle that looks at
    /// each side (+ clockwise on this top-down image); arrows show the four view directions.
    static func protractor(_ g: CGContext, centre c: CGPoint, radius R: CGFloat) {
        g.setStrokeColor(accent.withAlphaComponent(0.85).cgColor)
        g.setLineWidth(2.5)
        g.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        for a in stride(from: 0, to: 360, by: 5) {
            let t = CGFloat(a) * .pi / 180
            let dir = CGPoint(x: -sin(t), y: cos(t))
            let len: CGFloat = a % 30 == 0 ? 22 : (a % 10 == 0 ? 14 : 8)
            g.setLineWidth(a % 30 == 0 ? 2.5 : 1.2)
            g.move(to: CGPoint(x: c.x + dir.x * R, y: c.y + dir.y * R))
            g.addLine(to: CGPoint(x: c.x + dir.x * (R + len), y: c.y + dir.y * (R + len)))
            g.strokePath()
            if a % 30 == 0 {
                let v = a > 180 ? a - 360 : a
                let label = v == 0 ? "0°" : (v == 180 ? "180°" : String(format: "%+d°", v))
                let p = CGPoint(x: c.x + dir.x * (R + 46), y: c.y + dir.y * (R + 46) - 12)
                text(label, at: p, size: 20, weight: v % 90 == 0 ? .bold : .regular, color: v == 0 ? markRed : ink, align: .center, mono: true)
            }
        }
        // Mark.
        g.setFillColor(markRed.cgColor)
        g.fillEllipse(in: CGRect(x: c.x - 9, y: c.y + R - 9, width: 18, height: 18))
        // View arrows from outside towards the sample.
        for v in [0.0, 90, 180, -90] {
            let t = CGFloat(v) * .pi / 180
            let dir = CGPoint(x: -sin(t), y: cos(t))
            let tail = CGPoint(x: c.x + dir.x * (R + 110), y: c.y + dir.y * (R + 110))
            let tip = CGPoint(x: c.x + dir.x * (R + 70), y: c.y + dir.y * (R + 70))
            g.setStrokeColor(UIColor(red: 0.95, green: 0.55, blue: 0.1, alpha: 1).cgColor)
            g.setLineWidth(4)
            g.move(to: tail)
            g.addLine(to: tip)
            g.strokePath()
        }
    }

    // MARK: Saving

    /// Writes the sheets, the figures (each view with its ruler and scale), the plain views, the unrolled image and
    /// a JSON description into model/sheet (and so to Drive).
    static func save(_ o: Output, scan: Scan) throws -> [URL] {
        let dir = scan.exportsURL.appendingPathComponent("sheet", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tag = Rotation.token(o.reference)
        // Earlier sheets (other angles, other templates) are replaced; Drive copies go to the Drive bin (3.8).
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let n = old.lastPathComponent
            if n.contains("_sample-sheet") || n.contains("_view-") || n.contains("_unrolled_") || n.contains("_figure-") {
                try? FileManager.default.removeItem(at: old)
            }
        }
        var urls: [URL] = []
        func write(_ img: UIImage, _ name: String) throws {
            let u = dir.appendingPathComponent(name)
            try img.pngData()?.write(to: u, options: .atomic)
            urls.append(u)
        }
        try write(o.clean, "\(scan.fileStem)_sample-sheet-clean_\(tag).png")
        try write(o.scientific, "\(scan.fileStem)_sample-sheet-scientific_\(tag).png")
        if o.options.has(.figures) {
            for f in o.figures { try write(f.image, "\(scan.fileStem)_figure-\(f.id)_\(tag).png") }
        }
        if let u = o.unrolled, o.options.has(.unrolled) { try write(u, "\(scan.fileStem)_unrolled_\(tag).png") }
        if o.options.has(.plainViews) {
            for v in o.views { try write(v.image, "\(scan.fileStem)_view-\(v.id)_\(tag).png") }
        }
        let j = dir.appendingPathComponent("\(scan.fileStem)_sample-sheet.json")
        try JSONSerialization.data(withJSONObject: o.json, options: [.prettyPrinted, .sortedKeys]).write(to: j, options: .atomic)
        urls.append(j)
        return urls
    }

    /// Whether the sheet shows the bottom: yes when the rock was flipped; no when it wasn't, for a quick scan or a
    /// single pass. Older scans don't record a flip, so their bottom is kept only when it carries texture
    /// (an unphotographed underside is one flat grey).
    static func showsBottom(_ scan: Scan, _ bottom: View3D?) -> Bool {
        if scan.underside == true { return true }
        if scan.underside == false || scan.quick == true || (scan.passes ?? 1) <= 1 { return false }
        guard let img = bottom?.image else { return false }
        return !looksUntextured(img)
    }

    /// Spread of brightness over the rock's pixels (the white background left out) is tiny for a face
    /// Object Capture filled in without photos.
    static func looksUntextured(_ img: UIImage) -> Bool {
        guard let cg = img.cgImage else { return false }
        let n = 64
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var lumas: [Double] = []
        for i in 0..<(n * n) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            if r > 0.97 && g > 0.97 && b > 0.97 { continue } // background
            lumas.append(0.299 * r + 0.587 * g + 0.114 * b)
        }
        guard lumas.count > 200 else { return true }
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let sd = (lumas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lumas.count)).squareRoot()
        return sd < 0.03
    }

    /// The angle used as 0° for a scan: its trusted mark, else 0.
    static func reference(for scan: Scan) -> (Double, Bool) {
        if let m = scan.mark, m.isTrusted { return (m.angle, true) }
        return (0, false)
    }
}

extension UIColor {
    func darker(_ f: CGFloat = 0.75) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * f, green: g * f, blue: b * f, alpha: a)
    }
}

struct SampleSheetView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let scan: Scan
    let rig: SampleRig
    /// Protractor angle used as 0°.
    let reference: Double
    let referenceIsMark: Bool
    @State private var output: SampleSheet.Output?
    @State private var saved: [URL] = []
    @State private var error: String?
    @State private var scientific = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(referenceIsMark
                         ? "0° is the reference mark. Views are counted from it; + = turned counter-clockwise seen from above."
                         : "0° is protractor \(Rotation.text(reference)). Views are counted from it; + = turned counter-clockwise seen from above.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Template", selection: $scientific) {
                        Text("Scientific").tag(true)
                        Text("Clean").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if let o = output {
                        Image(uiImage: scientific ? o.scientific : o.clean).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        if let u = o.unrolled {
                            Text("Unrolled side (360°)").font(.headline)
                            Image(uiImage: u).resizable().scaledToFit()
                        }
                    } else {
                        ProgressView("Rendering…").frame(maxWidth: .infinity)
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
                let u = Unroller.unroll(rig: rig)
                let o = SampleSheet.make(rig: rig, scan: scan, reference: reference, referenceIsMark: referenceIsMark, unrolled: u)
                output = o
                do {
                    saved = try SampleSheet.save(o, scan: scan)
                    Task { await model.syncAllPending() }
                } catch {
                    self.error = "Couldn't save: \(error.localizedDescription)"
                }
            }
        }
    }
}
