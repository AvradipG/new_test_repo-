import Foundation

/// Size of a section outline measured from its points alone, so it is valid for open chains too
/// (an outline with a gap still shows how wide the rock is at that plane). Units: input units.
public struct OutlineSize: Sendable, Hashable {
    /// Largest distance between two outline points (maximum Feret diameter).
    public var maxFeret: Double
    /// Smallest caliper width of the outline's convex hull (minimum Feret diameter).
    public var minWidth: Double
    /// Range of the outline along the plane's u and v axes.
    public var extentU: Double
    public var extentV: Double
    public var pointCount: Int
}

/// Size of the whole model standing as it was scanned: `up` is the vertical axis of the model frame
/// (Object Capture models are +Y up, aligned with gravity during capture).
public struct UprightSize: Codable, Hashable, Sendable {
    /// Lowest to highest point, millimetres.
    public var heightMM: Double
    /// Sides of the smallest rectangle around the footprint seen from above, longer first.
    public var lengthMM: Double
    public var widthMM: Double
    /// Largest horizontal distance across the model (maximum Feret diameter of the footprint).
    public var maxDiameterMM: Double
    /// Narrowest horizontal caliper width of the footprint.
    public var minWidthMM: Double

    public init(heightMM: Double, lengthMM: Double, widthMM: Double, maxDiameterMM: Double, minWidthMM: Double) {
        self.heightMM = heightMM; self.lengthMM = lengthMM; self.widthMM = widthMM
        self.maxDiameterMM = maxDiameterMM; self.minWidthMM = minWidthMM
    }
}

extension CrossSection {
    /// Outline size from every intersection point, closed or open. Nil for an empty plane.
    public var outlineSize: OutlineSize? { ScanMath.outlineSize((loops + openChains).flatMap { $0 }) }
}

extension ScanMath {
    /// Convex hull, counter-clockwise, without a repeated end point (Andrew's monotone chain).
    public static func convexHull(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let p = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        var upper: [SIMD2<Double>] = []
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Maximum and minimum Feret diameters and axis extents of a 2D point set.
    public static func outlineSize(_ points: [SIMD2<Double>]) -> OutlineSize? {
        guard !points.isEmpty else { return nil }
        var lo = points[0], hi = points[0]
        for q in points { lo = simd_min2(lo, q); hi = simd_max2(hi, q) }
        let hull = convexHull(points)
        let caliper = hullCalipers(hull)
        return OutlineSize(maxFeret: caliper.maxFeret, minWidth: caliper.minWidth,
                           extentU: hi.x - lo.x, extentV: hi.y - lo.y, pointCount: points.count)
    }

    /// Rotating-caliper measures of a convex hull: max Feret, min width, and the smallest-area
    /// enclosing rectangle (its sides, longer first, and the direction of the longer side).
    static func hullCalipers(_ hull: [SIMD2<Double>]) -> (maxFeret: Double, minWidth: Double, rectLong: Double, rectShort: Double, longDir: SIMD2<Double>) {
        let n = hull.count
        if n == 0 { return (0, 0, 0, 0, SIMD2(1, 0)) }
        if n == 1 { return (0, 0, 0, 0, SIMD2(1, 0)) }
        var maxFeret = 0.0
        for i in 0..<n { for j in (i + 1)..<n { maxFeret = Swift.max(maxFeret, length2(hull[i] - hull[j])) } }
        if n == 2 {
            let d = hull[1] - hull[0]
            let l = length2(d)
            return (maxFeret, 0, l, 0, l > 0 ? d / l : SIMD2(1, 0))
        }
        var minWidth = Double.infinity
        var bestArea = Double.infinity
        var rect = (long: 0.0, short: 0.0, dir: SIMD2<Double>(1, 0))
        for i in 0..<n {
            let e = hull[(i + 1) % n] - hull[i]
            let l = length2(e)
            guard l > 0 else { continue }
            let d = e / l
            let nrm = SIMD2(-d.y, d.x)
            var dLo = Double.infinity, dHi = -Double.infinity, nLo = Double.infinity, nHi = -Double.infinity
            for q in hull {
                let r = q - hull[i]
                let a = r.x * d.x + r.y * d.y, b = r.x * nrm.x + r.y * nrm.y
                dLo = Swift.min(dLo, a); dHi = Swift.max(dHi, a)
                nLo = Swift.min(nLo, b); nHi = Swift.max(nHi, b)
            }
            let along = dHi - dLo, across = nHi - nLo
            minWidth = Swift.min(minWidth, across)
            if along * across < bestArea {
                bestArea = along * across
                rect = along >= across ? (along, across, d) : (across, along, nrm)
            }
        }
        return (maxFeret, minWidth.isFinite ? minWidth : 0, rect.long, rect.short, rect.dir)
    }

    /// Plane axes perpendicular to `up` (index 0, 1 or 2): the next two axes in x-y-z order.
    static func horizontalAxes(_ up: Int) -> (Int, Int) {
        switch up {
        case 0: return (1, 2)
        case 1: return (0, 2)
        default: return (0, 1)
        }
    }

    /// Height and footprint of the model standing as scanned. `unitToMM` converts input units to millimetres.
    public static func uprightSize(positions: [SIMD3<Float>], up: Int = 1, unitToMM: Double = 1000) -> UprightSize? {
        guard !positions.isEmpty, (0...2).contains(up) else { return nil }
        let (h1, h2) = horizontalAxes(up)
        var lo = Double.infinity, hi = -Double.infinity
        var footprint: [SIMD2<Double>] = []
        footprint.reserveCapacity(positions.count)
        for p in positions {
            let h = Double(p[up])
            lo = Swift.min(lo, h); hi = Swift.max(hi, h)
            footprint.append(SIMD2(Double(p[h1]), Double(p[h2])))
        }
        let c = hullCalipers(convexHull(footprint))
        return UprightSize(heightMM: (hi - lo) * unitToMM, lengthMM: c.rectLong * unitToMM, widthMM: c.rectShort * unitToMM,
                           maxDiameterMM: c.maxFeret * unitToMM, minWidthMM: c.minWidth * unitToMM)
    }

    /// Frame for slicing the model horizontally as it stood: axis 0 points up, axis 1 along the long side of the
    /// footprint, axis 2 across it. Sections across axis 0 are then measured as height above the lowest point.
    public static func uprightFrame(_ points: [SIMD3<Float>], up: Int = 1) -> PrincipalFrame {
        let (h1, h2) = horizontalAxes(up)
        var upVec = SIMD3<Double>(0, 0, 0); upVec[up] = 1
        let footprint = points.map { SIMD2(Double($0[h1]), Double($0[h2])) }
        let dir = hullCalipers(convexHull(footprint)).longDir
        var u = SIMD3<Double>(0, 0, 0); u[h1] = dir.x; u[h2] = dir.y
        let v = vnormalize(vcross(upVec, u))
        let axes = [upVec, vnormalize(u), v]
        guard !points.isEmpty else { return PrincipalFrame(center: .zero, axes: axes, lo: .zero, hi: .zero) }
        var mean = SIMD3<Double>.zero
        for p in points { mean += SIMD3<Double>(p) }
        mean /= Double(points.count)
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in points {
            let d = SIMD3<Double>(p) - mean
            for k in 0..<3 {
                let t = vdot(d, axes[k])
                lo[k] = Swift.min(lo[k], t); hi[k] = Swift.max(hi[k], t)
            }
        }
        return PrincipalFrame(center: mean, axes: axes, lo: lo, hi: hi)
    }
}

@inline(__always) func length2(_ a: SIMD2<Double>) -> Double { (a.x * a.x + a.y * a.y).squareRoot() }
@inline(__always) func simd_min2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> { SIMD2(Swift.min(a.x, b.x), Swift.min(a.y, b.y)) }
@inline(__always) func simd_max2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> { SIMD2(Swift.max(a.x, b.x), Swift.max(a.y, b.y)) }
