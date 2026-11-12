import Foundation
import simd

// Standing a core straight for the micro-CT (3.16). A core whose end is not cut square to its axis leans when it
// stands on that end, and leans the same way on the CT stage: it then turns about a tilted axis and wobbles,
// which smears the scan. The usual fix is a few slips of paper ("confetti") under the low side. Here the axis is
// found from the core's curved side, the lean from the end it stands on, and the paper is placed: where round
// the core (as an angle from the reference mark, 0°, counted like the scanning mat's ring) and how thick.

public struct LevelPlan: Codable, Hashable, Sendable {
    /// How far the axis is from perpendicular to the end it stands on (degrees).
    public var tiltDeg: Double
    /// Model azimuth (degrees, atan2(x, z), counter-clockwise seen from above) of the side to lift.
    public var liftAzimuthDeg: Double
    /// Gap under the rim on that side when the core stands straight, pivoting on the opposite rim (mm).
    public var rimGapMM: Double
    /// "as_stood" (the axis against the vertical as it stood in the scan) or "end_face" (the end face's plane
    /// against the axis).
    public var method: String
    /// How much repeated fits of the axis disagree (degrees): below this the lean can't be told apart from noise.
    public var spreadDeg: Double
}

public struct LevelReport: Codable, Hashable, Sendable {
    public var diameterMM: Double
    public var lengthMM: Double
    /// Axis from the vertical as it stood in the scan (degrees).
    public var standingTiltDeg: Double
    /// Standing on the end it stood on in the scan.
    public var asScanned: LevelPlan
    /// Turned over, standing on the other end (from that end's face, which the scan saw).
    public var turnedOver: LevelPlan?
    /// Share of the surface on the cylinder: how much of a cylinder it is.
    public var cylinderShare: Double
}

public enum CoreLeveller {
    /// Gap (mm) under the end at `radiusShare` of the radius out from the axis, `deltaDeg` round from the side to
    /// lift, when the core stands straight pivoting on the rim opposite that side.
    public static func gap(_ p: LevelPlan, radiusMM: Double, deltaDeg: Double, radiusShare: Double) -> Double {
        let t: Double = tan(p.tiltDeg * .pi / 180)
        let reach: Double = radiusMM + radiusShare * radiusMM * cos(deltaDeg * .pi / 180)
        return Swift.max(0, t * reach)
    }

    @inline(__always) static func azimuth(_ d: SIMD3<Double>) -> Double {
        atan2(d.x, d.z) * 180 / .pi
    }

    /// The best plane through points: its unit normal (smallest spread) and the rms distance from it.
    static func plane(_ pts: [SIMD3<Double>]) -> (normal: SIMD3<Double>, rms: Double)? {
        guard pts.count >= 12 else { return nil }
        let c = pts.reduce(SIMD3<Double>.zero, +) / Double(pts.count)
        var m: [[Double]] = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
        for p in pts {
            let d = p - c
            let v: [Double] = [d.x, d.y, d.z]
            for r in 0..<3 { for s in 0..<3 { m[r][s] += v[r] * v[s] } }
        }
        let n = CylinderFinder.smallestEigenvector(m)
        var sq = 0.0
        for p in pts {
            let e = simd_dot(p - c, n)
            sq += e * e
        }
        return (n, (sq / Double(pts.count)).squareRoot())
    }

    /// The plan for standing on the end whose outward direction along the axis is `e`, from that end's face.
    static func facePlan(_ piece: Piece, axis e: SIMD3<Double>, radius R: Double, unitToMM: Double, spread: Double) -> LevelPlan? {
        let proj = piece.points.map { simd_dot($0, e) }
        guard let far = proj.max(), let near = proj.min() else { return nil }
        let len = far - near
        var face: [SIMD3<Double>] = []
        for i in piece.points.indices where simd_dot(piece.normals[i], e) > 0.9 && proj[i] > far - 0.15 * len {
            face.append(piece.points[i])
        }
        guard face.count >= 30, let pl = plane(face) else { return nil }
        var n = pl.normal
        if simd_dot(n, e) < 0 { n = -n }
        let tilt = acos(Swift.min(1, Swift.max(-1, simd_dot(n, e))))
        // The face recedes toward the middle of the core on the side its normal leans to: that side gets the paper.
        var t = n - e * simd_dot(n, e)
        let tl = simd_length(t)
        t = tl > 1e-9 ? t / tl : SIMD3(0, 0, 1)
        let tiltDeg = tilt * 180 / .pi
        return LevelPlan(tiltDeg: tiltDeg, liftAzimuthDeg: azimuth(t), rimGapMM: 2 * R * tan(tilt) * unitToMM,
                         method: "end_face", spreadDeg: spread)
    }

    /// Works out how to stand a core straight. Positions are the model's (metres, +Y up, as it stood in the
    /// scan). Nil when the shape isn't a cylinder.
    public static func plan(positions: [SIMD3<Float>], indices: [UInt32], unitToMM: Double = 1000) -> LevelReport? {
        var tris: [SIMD3<Int>] = []
        tris.reserveCapacity(indices.count / 3)
        var k = 0
        while k + 2 < indices.count {
            tris.append(SIMD3(Int(indices[k]), Int(indices[k + 1]), Int(indices[k + 2])))
            k += 3
        }
        let P = positions.map { SIMD3<Double>($0) }
        guard !P.isEmpty, !tris.isEmpty else { return nil }
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in P { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let size = simd_length(hi - lo)
        let s = Piece.sample(positions: P, triangles: tris, spacing: size / 70, maxPoints: 5000, seed: 11)
        guard s.points.count >= 100 else { return nil }
        let piece = Piece(id: 1, points: s.points, normals: s.normals, spacing: Swift.max(size / 70, (s.area / Double(s.points.count)).squareRoot()),
                          area: s.area)
        // The axis, fitted three times from different random starts: their spread is the uncertainty.
        var fits: [CylinderPatch] = []
        for seed in [3, 17, 29] as [UInt64] {
            if let f = CylinderFinder.fit(piece, radius: nil, attempts: 160, seed: seed) { fits.append(f) }
        }
        guard let best = fits.max(by: { $0.share < $1.share }), best.share >= 0.3, best.arcDegrees >= 200 else { return nil }
        var a = simd_normalize(best.axis)
        if a.y < 0 { a = -a }
        var spread = 0.0
        for f in fits {
            let c = Swift.min(1, abs(simd_dot(simd_normalize(f.axis), a)))
            spread = Swift.max(spread, acos(c) * 180 / .pi)
        }
        let R = best.radius
        let proj = piece.points.map { simd_dot($0, a) }
        let length = ((proj.max() ?? 0) - (proj.min() ?? 0)) * unitToMM
        // As it stood: the axis against the vertical; the top leans toward the side to lift.
        let up = SIMD3<Double>(0, 1, 0)
        let standing = acos(Swift.min(1, Swift.max(-1, simd_dot(a, up))))
        var lean = a - up * simd_dot(a, up)
        let ll = simd_length(lean)
        lean = ll > 1e-12 ? lean / ll : SIMD3(0, 0, 1)
        let asStood = LevelPlan(tiltDeg: standing * 180 / .pi, liftAzimuthDeg: azimuth(lean), rimGapMM: 2 * R * tan(standing) * unitToMM,
                                method: "as_stood", spreadDeg: spread)
        let over = facePlan(piece, axis: a, radius: R, unitToMM: unitToMM, spread: spread)
        return LevelReport(diameterMM: 2 * R * unitToMM, lengthMM: length, standingTiltDeg: standing * 180 / .pi,
                           asScanned: asStood, turnedOver: over, cylinderShare: best.share)
    }

    /// Paper slips for a plan: (angle from the reference mark counted like the mat's ring, layers) for one slip
    /// near the rim on the side to lift, and for a steadier pair 60° either side of it.
    /// - Parameters:
    ///   - markAngleDeg: the protractor angle that turns the mark to face the viewer (nil = no mark: angles
    ///     count from the sheets' 0° view).
    ///   - turnedOver: the core stands on the other end, so angles seen from above run the other way.
    public static func slips(_ p: LevelPlan, radiusMM: Double, markAngleDeg: Double?, turnedOver: Bool, paperMM: Double)
        -> (single: (angle: Double, layers: Int, gapMM: Double), pair: [(angle: Double, layers: Int, gapMM: Double)]) {
        var rel = Rotation.normalized(p.liftAzimuthDeg + (markAngleDeg ?? 0))
        if turnedOver { rel = Rotation.normalized(-rel) }
        let g1 = gap(p, radiusMM: radiusMM, deltaDeg: 0, radiusShare: 0.85)
        let g2 = gap(p, radiusMM: radiusMM, deltaDeg: 60, radiusShare: 0.85)
        func layers(_ g: Double) -> Int { Swift.max(0, Int((g / Swift.max(0.01, paperMM)).rounded())) }
        let single = (Rotation.normalized(rel), layers(g1), g1)
        let pair = [(Rotation.normalized(rel - 60), layers(g2), g2), (Rotation.normalized(rel + 60), layers(g2), g2)]
        return (single, pair)
    }
}

extension StandFinder {
    /// Does the outline change where a stand would meet the rock? Convex hulls of the surface just above and just
    /// below height `y` (model frame, +Y up): the share by which their areas differ, and how far their middles
    /// are apart compared with their size. A straight core's outline runs on unchanged; a rock on a block changes.
    public static func outlineStep(positions: [SIMD3<Float>], y: Double, band: Double) -> (areaChange: Double, shift: Double)? {
        var above: [SIMD2<Double>] = [], below: [SIMD2<Double>] = []
        for p in positions {
            let py = Double(p.y)
            if py >= y + 0.15 * band && py < y + band { above.append(SIMD2(Double(p.x), Double(p.z))) }
            if py <= y - 0.15 * band && py > y - band { below.append(SIMD2(Double(p.x), Double(p.z))) }
        }
        guard above.count >= 12, below.count >= 12 else { return nil }
        func areaAndMiddle(_ pts: [SIMD2<Double>]) -> (Double, SIMD2<Double>) {
            let h = ScanMath.convexHull(pts)
            guard h.count >= 3 else { return (0, pts.reduce(.zero, +) / Double(pts.count)) }
            var a = 0.0
            var c = SIMD2<Double>.zero
            for i in h.indices {
                let p = h[i], q = h[(i + 1) % h.count]
                let cr = p.x * q.y - q.x * p.y
                a += cr
                c += (p + q) * cr
            }
            let area = abs(a) / 2
            let middle: SIMD2<Double> = abs(a) > 1e-18 ? c / (3 * a) : h.reduce(.zero, +) / Double(h.count)
            return (area, middle)
        }
        let (a1, c1) = areaAndMiddle(above), (a2, c2) = areaAndMiddle(below)
        let big = Swift.max(a1, a2)
        guard big > 0 else { return nil }
        return (abs(a1 - a2) / big, simd_length(c1 - c2) / big.squareRoot())
    }
}
