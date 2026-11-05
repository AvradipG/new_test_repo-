import Foundation
import ScanMath
import simd

/// One LiDAR depth map from ARKit, copied out of the frame so it can be measured later off the main thread.
/// Pixel (0, 0) is the top-left of the sensor's landscape image.
public struct DepthFrame: Sendable {
    public var width: Int
    public var height: Int
    /// Metres from the camera, row-major.
    public var depth: [Float]
    /// ARKit confidence per pixel (0 low, 1 medium, 2 high); nil if unavailable.
    public var confidence: [UInt8]?
    /// Camera intrinsics already scaled to the depth map's resolution.
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float
    /// Camera pose in the AR world (y up, gravity aligned).
    public var cameraToWorld: simd_float4x4

    public init(width: Int, height: Int, depth: [Float], confidence: [UInt8]?, fx: Float, fy: Float, cx: Float, cy: Float,
                cameraToWorld: simd_float4x4) {
        self.width = width
        self.height = height
        self.depth = depth
        self.confidence = confidence
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.cameraToWorld = cameraToWorld
    }
}

/// Rough real-world size of one thing, from the side the camera saw.
public struct MeasuredSize: Codable, Equatable, Sendable {
    /// Longer side of the footprint seen from above, then the shorter one, then the height, in centimetres.
    public var lengthCM: Double
    public var widthCM: Double
    public var heightCM: Double
    /// Middle of the measured surface in the AR world (metres).
    public var centerX: Double
    public var centerY: Double
    public var centerZ: Double
    public var pointCount: Int
}

/// Measures things in a photo with the LiDAR depth taken at the same moment, using Crystal Bowl's
/// tested ScanMath (smallest footprint rectangle and height of the upright point cloud).
public enum DepthMeasure {
    /// Part of the box kept on each side, so edges and background in a loose box count less.
    static let inset = 0.05

    /// A box in the upright (portrait) photo, as a rectangle of the landscape depth map, normalised.
    /// The portrait photo is the sensor image turned a quarter clockwise: landscape x = portrait y,
    /// landscape y = 1 - portrait x.
    public static func landscapeRect(_ b: PhotoBox) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        (b.y, 1 - (b.x + b.w), b.y + b.h, 1 - b.x)
    }

    /// 3D points (AR world) of the thing inside `box`, with the background behind it removed.
    public static func points(for box: PhotoBox, in f: DepthFrame) -> [SIMD3<Float>] {
        var r = landscapeRect(box)
        let dx = (r.x1 - r.x0) * inset, dy = (r.y1 - r.y0) * inset
        r = (r.x0 + dx, r.y0 + dy, r.x1 - dx, r.y1 - dy)
        let i0 = max(0, Int((r.x0 * Double(f.width)).rounded(.down)))
        let i1 = min(f.width - 1, Int((r.x1 * Double(f.width)).rounded(.up)))
        let j0 = max(0, Int((r.y0 * Double(f.height)).rounded(.down)))
        let j1 = min(f.height - 1, Int((r.y1 * Double(f.height)).rounded(.up)))
        guard i1 > i0, j1 > j0 else { return [] }

        var samples: [(i: Int, j: Int, d: Float)] = []
        var central: [Double] = []
        let ci0 = i0 + (i1 - i0) * 3 / 10, ci1 = i1 - (i1 - i0) * 3 / 10
        let cj0 = j0 + (j1 - j0) * 3 / 10, cj1 = j1 - (j1 - j0) * 3 / 10
        for j in j0...j1 {
            for i in i0...i1 {
                let k = j * f.width + i
                if let c = f.confidence, c[k] < 1 { continue }
                let d = f.depth[k]
                guard d.isFinite, d > 0.1, d < 6 else { continue }
                samples.append((i, j, d))
                if i >= ci0 && i <= ci1 && j >= cj0 && j <= cj1 { central.append(Double(d)) }
            }
        }
        guard !samples.isEmpty else { return [] }
        let dMed = Float(ScanMath.median(central.isEmpty ? samples.map { Double($0.d) } : central))
        // How big the box is at that distance, to decide how much depth variation still belongs to the thing.
        let spanM = Float(max(i1 - i0, j1 - j0)) * dMed / max(f.fx, 1)
        let tolerance = min(max(0.4 * spanM, 0.04), 0.5)

        var out: [SIMD3<Float>] = []
        out.reserveCapacity(samples.count)
        for s in samples where abs(s.d - dMed) <= tolerance {
            let x = (Float(s.i) - f.cx) * s.d / f.fx
            let y = -(Float(s.j) - f.cy) * s.d / f.fy
            let p = f.cameraToWorld * SIMD4<Float>(x, y, -s.d, 1)
            out.append(SIMD3<Float>(p.x, p.y, p.z))
        }
        return out
    }

    public static func measure(_ box: PhotoBox, in f: DepthFrame) -> MeasuredSize? {
        let pts = points(for: box, in: f)
        guard pts.count >= 12, let u = ScanMath.uprightSize(positions: pts, up: 1, unitToMM: 1000) else { return nil }
        var c = SIMD3<Double>(0, 0, 0)
        for p in pts { c += SIMD3<Double>(p) }
        c /= Double(pts.count)
        func cm(_ mm: Double) -> Double { (mm / 10 * 10).rounded() / 10 }
        return MeasuredSize(lengthCM: cm(u.lengthMM), widthCM: cm(u.widthMM), heightCM: cm(u.heightMM),
                            centerX: c.x, centerY: c.y, centerZ: c.z, pointCount: pts.count)
    }

    /// "40 × 30 × 25 cm" style text, largest first, dropping a side under 1 cm (only one face was visible).
    public static func label(length: Double, width: Double, height: Double) -> String {
        let sides = [length, width, height].filter { $0 >= 1 }.sorted(by: >)
        guard !sides.isEmpty else { return "" }
        return sides.map { $0 >= 100 ? String(format: "%.0f", $0) : String(format: "%.0f", $0.rounded()) }
            .joined(separator: " × ") + " cm"
    }
}
