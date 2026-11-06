import SceneKit
import UIKit
import Metal
import ScanMath

/// The reference mark kept with a scan: the protractor angle at which the marker line faces the viewer.
struct MarkRecord: Codable, Hashable {
    /// Protractor angle (degrees, + = counter-clockwise seen from above) that turns the mark to face the viewer.
    var angle: Double
    /// "red_black_line", "red_line", "black_line", "red_black_pair", "red_spot" or "manual".
    var kind: String
    var confidence: Double
    /// "top", "bottom" or "unknown": where the red part is in the scan as it stood.
    var redEnd: String
    /// "auto" or "manual".
    var source: String
    var date: Date

    var upsideDown: Bool { redEnd == "bottom" }
    var isTrusted: Bool { source == "manual" || confidence >= 0.35 }

    var kindText: String {
        switch kind {
        case "red_black_line": return "red/black line"
        case "red_black_pair": return "red and black lines"
        case "red_line": return "red line"
        case "black_line": return "black line"
        case "red_spot": return "red mark"
        default: return "set by hand"
        }
    }

    var summary: String {
        if source == "manual" { return "Reference mark set by hand: it is 0°" }
        var s = String(format: "Reference mark found: %@ (confidence %.0f%%). It is 0°%@", kindText, confidence * 100,
                       isTrusted ? "" : ", but check it: the 0° view should show the line")
        if upsideDown { s += ". The red end is at the bottom: the sample stood upside down in this scan" }
        return s
    }

    func json() -> [String: Any] {
        ["protractor_angle_deg": angle, "kind": kind, "confidence": confidence, "red_end": redEnd, "source": source,
         "upside_down_in_scan": upsideDown, "date_utc": ISO8601DateFormatter().string(from: date),
         "convention": "angle the sample is turned (+ = counter-clockwise seen from above) so the mark faces the viewer; views and the unrolled image count from it"]
    }
}

/// The side surface unrolled into one flat, true-scale image: the sample is turned in small steps under an
/// orthographic camera and the strip facing the camera is kept each time (like a core scanner's 360° image).
@MainActor
enum Unroller {
    struct Result {
        let image: UIImage
        /// Pixels per true millimetre, both directions (at the cylinder radius).
        let pxPerMM: Double
        let heightMM: Double
        let circumferenceMM: Double
        /// Protractor angle of each column (decreasing left to right: that is how the surface reads from outside).
        let angles: [Double]
        let mark: MarkDetection?
    }

    static func unroll(rig: SampleRig, steps: Int = 144, heightPixels: Double = 640) -> Result? {
        let d = rig.data
        let H = d.height
        let R = (d.shape?.kind == .cylinder ? d.shape!.radius : d.circleRadius)
        guard H > 0, R > 0 else { return nil }
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0, green: 1, blue: 0, alpha: 1)
        let holder = SCNNode()
        let model = rig.modelNode.clone()
        // Unlit copies of the materials: the texture's own colour, without shading.
        model.enumerateHierarchy { node, _ in
            guard let g = node.geometry, let copy = g.copy() as? SCNGeometry else { return }
            copy.materials = g.materials.map { m in
                let c = (m.copy() as? SCNMaterial) ?? m
                c.lightingModel = .constant
                return c
            }
            node.geometry = copy
        }
        model.simdPosition = rig.sample.simdPosition
        holder.addChildNode(model)
        scene.rootNode.addChildNode(holder)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.usesOrthographicProjection = true
        cam.camera?.zNear = 0.001
        cam.camera?.zFar = 10
        let half = H / 2 * 1.04
        cam.camera?.orthographicScale = half
        cam.simdPosition = SIMD3(0, Float(H / 2), 2)
        scene.rootNode.addChildNode(cam)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = cam

        let imgH = Int(heightPixels)
        let pxPerUnit = Double(imgH) / (2 * half)
        let unitPerMM = 0.001 / d.scaleFactor
        let pxPerMM = pxPerUnit * unitPerMM
        let totalW = Int((2 * Double.pi * R * pxPerUnit).rounded())
        guard totalW >= 24 else { return nil }
        let rowTop = Int(((half - H / 2) * pxPerUnit).rounded())
        let rows = Swift.max(8, Int((H * pxPerUnit).rounded()))

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: totalW, height: rows, bitsPerComponent: 8, bytesPerRow: totalW * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(UIColor(red: 0, green: 1, blue: 0, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: rows))
        let stepDeg = 360.0 / Double(steps)
        for i in 0..<steps {
            let alpha = Double(i) * stepDeg
            holder.simdOrientation = simd_quatf(angle: Float(alpha * .pi / 180), axis: SIMD3(0, 1, 0))
            // Column range of this strip (alpha decreases left to right; strip i is centred on alpha).
            let x0 = Int((Double(steps - i) - 0.5) / Double(steps) * Double(totalW))
            let x1 = Int((Double(steps - i) + 0.5) / Double(steps) * Double(totalW))
            let lo = ((x0 % totalW) + totalW) % totalW
            let w = Swift.max(1, x1 - x0)
            let shotW = w + 4
            let shot = renderer.snapshot(atTime: 0, with: CGSize(width: shotW, height: imgH), antialiasingMode: .multisampling4X)
            guard let cg = shot.cgImage else { continue }
            let sx = CGFloat(cg.width) / CGFloat(shotW), sy = CGFloat(cg.height) / CGFloat(imgH)
            guard let strip = cg.cropping(to: CGRect(x: 2 * sx, y: CGFloat(rowTop) * sy, width: CGFloat(w) * sx, height: CGFloat(rows) * sy)) else { continue }
            // CGContext's origin is bottom-left: draw the strip into its column band; wrap at the right edge.
            for dx in [0, -totalW] where lo + dx + w > 0 && lo + dx < totalW {
                ctx.draw(strip, in: CGRect(x: lo + dx, y: 0, width: w, height: rows))
            }
        }
        guard let out = ctx.makeImage() else { return nil }

        // Pixels for the mark finder (row 0 = top of the sample).
        var rgb = [SIMD3<Float>](repeating: .zero, count: totalW * rows)
        var valid = [Bool](repeating: false, count: totalW * rows)
        if let data = ctx.data {
            let p = data.bindMemory(to: UInt8.self, capacity: totalW * rows * 4)
            for y in 0..<rows {
                for x in 0..<totalW {
                    let o = (y * totalW + x) * 4
                    let r = Float(p[o]) / 255, g = Float(p[o + 1]) / 255, b = Float(p[o + 2]) / 255
                    rgb[y * totalW + x] = SIMD3(r, g, b)
                    valid[y * totalW + x] = !(g > 0.9 && r < 0.15 && b < 0.15)
                }
            }
        }
        let angles = (0..<totalW).map { x in Rotation.normalized((Double(totalW - x) - 0.5) / Double(totalW) * 360) }
        let positive = angles.map { $0 < 0 ? $0 + 360 : $0 }
        let mark = MarkFinder.detect(rgb: rgb, width: totalW, height: rows, valid: valid, columnAngles: positive,
                                     circumferenceMM: 2 * .pi * R / unitPerMM)
        // Background to white for display.
        let shown = whitened(out)
        return Result(image: shown, pxPerMM: pxPerMM, heightMM: H / unitPerMM, circumferenceMM: 2 * .pi * R / unitPerMM,
                      angles: angles, mark: mark)
    }

    static func whitened(_ cg: CGImage) -> UIImage {
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return UIImage(cgImage: cg) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in 0..<(w * h) {
            let o = i * 4
            if p[o + 1] > 230 && p[o] < 40 && p[o + 2] < 40 {
                p[o] = 255
                p[o + 1] = 255
                p[o + 2] = 255
            }
        }
        return ctx.makeImage().map { UIImage(cgImage: $0) } ?? UIImage(cgImage: cg)
    }

    /// Finds the mark and stores it on the scan, unless one was set by hand.
    static func detectMark(rig: SampleRig, scan: inout Scan) -> Result? {
        let r = unroll(rig: rig)
        if scan.mark?.source != "manual" {
            if let m = r?.mark {
                scan.mark = MarkRecord(angle: Rotation.normalized(m.angle), kind: m.kind.rawValue, confidence: m.confidence,
                                       redEnd: m.redEnd.rawValue, source: "auto", date: Date())
            } else {
                scan.mark = nil
            }
        }
        return r
    }
}
