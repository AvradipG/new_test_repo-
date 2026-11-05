import Foundation
import simd

/// What simple solid the rock is closest to, found automatically from the model's points.
public struct ShapeFit: Equatable, Sendable {
    public enum Kind: String, Sendable { case cylinder, sphere, irregular }

    public var kind: Kind
    /// Cylinder: unit axis direction. Sphere and irregular: +Y.
    public var axis: SIMD3<Double>
    /// Cylinder: a point on the axis at the middle of the fitted length. Sphere: centre.
    public var center: SIMD3<Double>
    /// Fitted radius (input units).
    public var radius: Double
    /// Cylinder: length along the axis of the side surface. Sphere: diameter.
    public var length: Double
    /// Median distance of the fitted surface points from the ideal surface (input units).
    public var residual: Double
    /// Share of points lying on the fitted surface (0…1).
    public var inlierShare: Double

    public var diameter: Double { radius * 2 }
    /// Angle between the cylinder axis and vertical (+Y), degrees.
    public var tiltDegrees: Double { acos(min(1, abs(axis.y))) * 180 / .pi }
}

/// Footprint seen from above: the smallest rectangle around it, with where it is and which way it points.
public struct FootprintRect: Equatable, Sendable {
    public var center: SIMD2<Double>
    /// Unit direction of the longer side.
    public var longDir: SIMD2<Double>
    public var long: Double
    public var short: Double
}

extension ScanMath {
    /// Smallest-area rectangle around 2D points (rotating calipers on the convex hull).
    public static func footprintRect(_ points: [SIMD2<Double>]) -> FootprintRect? {
        let hull = convexHull(points)
        guard hull.count >= 2 else { return nil }
        let c = hullCalipers(hull)
        let d = c.longDir, n = SIMD2(-d.y, d.x)
        var aLo = Double.infinity, aHi = -Double.infinity, bLo = Double.infinity, bHi = -Double.infinity
        for q in hull {
            let a = q.x * d.x + q.y * d.y, b = q.x * n.x + q.y * n.y
            aLo = Swift.min(aLo, a); aHi = Swift.max(aHi, a)
            bLo = Swift.min(bLo, b); bHi = Swift.max(bHi, b)
        }
        let center = d * ((aLo + aHi) / 2) + n * ((bLo + bHi) / 2)
        return FootprintRect(center: center, longDir: d, long: aHi - aLo, short: bHi - bLo)
    }

    /// Least-squares circle through 2D points (Kåsa). Nil when the points are degenerate.
    static func circleFit(_ p: [SIMD2<Double>]) -> (center: SIMD2<Double>, radius: Double)? {
        guard p.count >= 3 else { return nil }
        var m = simd_double3x3(0), r = SIMD3<Double>.zero
        for q in p {
            let row = SIMD3(q.x, q.y, 1)
            let rhs = -(q.x * q.x + q.y * q.y)
            m += simd_double3x3(columns: (row * row.x, row * row.y, row * row.z))
            r += row * rhs
        }
        guard abs(m.determinant) > 1e-30 else { return nil }
        let s = m.inverse * r
        let c = SIMD2(-s.x / 2, -s.y / 2)
        let rr = c.x * c.x + c.y * c.y - s.z
        return rr > 0 ? (c, rr.squareRoot()) : nil
    }

    /// Least-squares sphere through 3D points. Nil when degenerate.
    static func sphereFit(_ p: [SIMD3<Double>]) -> (center: SIMD3<Double>, radius: Double)? {
        guard p.count >= 4 else { return nil }
        var m = simd_double4x4(0), r = SIMD4<Double>.zero
        for q in p {
            let row = SIMD4(q.x, q.y, q.z, 1)
            let rhs = -(q.x * q.x + q.y * q.y + q.z * q.z)
            m += simd_double4x4(columns: (row * row.x, row * row.y, row * row.z, row * row.w))
            r += row * rhs
        }
        guard abs(m.determinant) > 1e-30 else { return nil }
        let s = m.inverse * r
        let c = SIMD3(-s.x / 2, -s.y / 2, -s.z / 2)
        let rr = simd_length_squared(c) - s.w
        return rr > 0 ? (c, rr.squareRoot()) : nil
    }

    /// Robust circle: refits on the points close to the circle, so cap faces, a base or a chip don't pull it.
    static func robustCircle(_ p: [SIMD2<Double>]) -> (center: SIMD2<Double>, radius: Double, residual: Double, inliers: [Bool])? {
        guard var fit = circleFit(p) else { return nil }
        var inl = [Bool](repeating: true, count: p.count)
        var res = 0.0
        for _ in 0..<5 {
            let r = p.map { abs(simd_length($0 - fit.center) - fit.radius) }
            let med = median(r)
            let tol = Swift.max(3 * 1.4826 * med, fit.radius * 0.004)
            inl = r.map { $0 <= tol }
            let kept = zip(p, inl).filter { $0.1 }.map { $0.0 }
            guard let f = circleFit(kept) else { break }
            fit = f
            res = median(kept.map { abs(simd_length($0 - f.center) - f.radius) })
        }
        return (fit.center, fit.radius, res, inl)
    }

    /// Cylinder fit about `axis`: (fit, score = residual / radius).
    static func cylinder(_ pts: [SIMD3<Double>], axis a: SIMD3<Double>) -> (ShapeFit, Double)? {
        let (u, v) = planeBasis(a)
        let flat = pts.map { SIMD2(vdot($0, u), vdot($0, v)) }
        guard let c = robustCircle(flat), c.radius > 0 else { return nil }
        // Side-surface points: on the circle. Their spread along the axis is the length.
        let hs = zip(pts, c.inliers).filter { $0.1 }.map { vdot($0.0, a) }.sorted()
        guard hs.count >= 8 else { return nil }
        let lo = hs[Int(Double(hs.count - 1) * 0.005)], hi = hs[Int(Double(hs.count - 1) * 0.995)]
        let share = Double(hs.count) / Double(pts.count)
        let center = u * c.center.x + v * c.center.y + a * ((lo + hi) / 2)
        let fit = ShapeFit(kind: .cylinder, axis: a, center: center, radius: c.radius, length: hi - lo,
                           residual: c.residual, inlierShare: share)
        // Few points on the side means the "cylinder" is a coincidence: penalise.
        return (fit, c.residual / c.radius + (share < 0.35 ? 1 : 0))
    }

    /// Finds whether the rock is a cylinder (core plug), a sphere or neither, from its surface points.
    /// Cylinders are searched about the vertical, the principal axes and small tilts around the best of them.
    public static func fitShape(_ points: [SIMD3<Float>], maxPoints: Int = 6000) -> ShapeFit? {
        guard points.count >= 20 else { return nil }
        let step = Swift.max(1, points.count / maxPoints)
        let pts = stride(from: 0, to: points.count, by: step).map { SIMD3<Double>(points[$0]) }

        var best: (ShapeFit, Double)?
        func consider(_ a: SIMD3<Double>) {
            guard let c = cylinder(pts, axis: vnormalize(a)) else { return }
            if best == nil || c.1 < best!.1 { best = c }
        }
        let frame = principalFrame(points.count > maxPoints ? stride(from: 0, to: points.count, by: step).map { points[$0] } : points)
        consider(SIMD3(0, 1, 0))
        for ax in frame.axes { consider(ax) }
        // Refine the axis by small tilts (core plugs rarely stand perfectly straight).
        for span in [8.0, 2.0, 0.5] {
            guard let b = best else { break }
            let (u, v) = planeBasis(b.0.axis)
            for i in -2...2 { for j in -2...2 where i != 0 || j != 0 {
                let ti = tan(Double(i) * span / 2 * .pi / 180), tj = tan(Double(j) * span / 2 * .pi / 180)
                consider(b.0.axis + u * ti + v * tj)
            } }
        }

        var result: ShapeFit?
        if let b = best, b.1 < 0.03, b.0.inlierShare >= 0.35 {
            var f = b.0
            if f.axis.y < 0 { f.axis = -f.axis }
            result = f
        }
        if let s = sphereFit(pts) {
            let r = pts.map { abs(simd_length($0 - s.center) - s.radius) }
            let share = Double(r.filter { $0 <= s.radius * 0.03 }.count) / Double(r.count)
            let res = median(r)
            if res / s.radius < 0.02, share > 0.7, result == nil || res / s.radius < result!.residual / result!.radius {
                result = ShapeFit(kind: .sphere, axis: SIMD3(0, 1, 0), center: s.center, radius: s.radius,
                                  length: s.radius * 2, residual: res, inlierShare: share)
            }
        }
        if let result { return result }
        let b = best?.0
        return ShapeFit(kind: .irregular, axis: SIMD3(0, 1, 0), center: b?.center ?? .zero, radius: b?.radius ?? 0,
                        length: b?.length ?? 0, residual: b?.residual ?? 0, inlierShare: b?.inlierShare ?? 0)
    }
}

/// Rotation about the vertical axis, written the DigitalSCAL way: positive = counter-clockwise seen from above.
public enum Rotation {
    /// Angle in (-180, 180].
    public static func normalized(_ degrees: Double) -> Double {
        var v = (degrees + 180).truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        v -= 180
        if abs(v + 180) < 1e-9 { v = 180 }
        return v
    }

    /// "+90.83°", "−12.50°" or "0.00°".
    public static func text(_ degrees: Double) -> String {
        let v = (normalized(degrees) * 100).rounded() / 100
        let sign = v > 0 ? "+" : (v < 0 ? "−" : "")
        return sign + String(format: "%.2f°", abs(v))
    }

    /// File-name token, e.g. "Rot_pos90p83" (same convention as the lab RAW names and SliceLock).
    public static func token(_ degrees: Double) -> String {
        let v = (normalized(degrees) * 100).rounded() / 100
        let body = String(format: "%.2f", abs(v)).replacingOccurrences(of: ".", with: "p")
        return "Rot_" + (v < 0 ? "neg" : "pos") + body
    }

    public static func direction(_ degrees: Double) -> String {
        let v = normalized(degrees)
        return abs(v) < 0.005 ? "start" : (v > 0 ? "CCW" : "CW")
    }
}

/// Tick marks of a millimetre ruler.
public enum RulerTicks {
    public struct Tick: Equatable, Sendable {
        public var mm: Double
        /// 0 = every millimetre, 1 = every 5 mm, 2 = every 10 mm (labelled in cm).
        public var level: Int
        public var label: String?
    }

    /// Ruler at least `lengthMM` long, rounded up to whole centimetres.
    public static func ticks(coveringMM lengthMM: Double) -> [Tick] {
        let cm = Swift.max(1, Int((lengthMM / 10).rounded(.up)))
        return (0...(cm * 10)).map { mm in
            let level = mm % 10 == 0 ? 2 : (mm % 5 == 0 ? 1 : 0)
            return Tick(mm: Double(mm), level: level, label: level == 2 ? "\(mm / 10)" : nil)
        }
    }
}
