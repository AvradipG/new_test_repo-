import Foundation
import simd

/// How one scan of a rock differs from another scan of the same rock (3.5): the second scan is turned and moved
/// onto the first (principal axes, then point-to-plane ICP), and every point of it gets a signed distance to
/// the first surface. Positive = the compared surface lies outside the reference (material gained or swelling),
/// negative = inside (material lost).
public struct ChangeMapResult: Sendable {
    /// Takes the compared scan onto the reference.
    public var pose: Pose
    /// Signed distance of each compared vertex, in the units of the positions given (after `scale`).
    public var signed: [Double]
    public var mean: Double
    public var median: Double
    public var rms: Double
    public var p95Abs: Double
    public var maxAbs: Double
    /// Misfit of the alignment on the matched points (same units).
    public var fitRMS: Double
}

public enum ChangeMap {
    /// `scaleA` and `scaleB` multiply the positions first (for example each scan's caliper factor).
    public static func compare(reference a: (positions: [SIMD3<Float>], indices: [UInt32]),
                               compared b: (positions: [SIMD3<Float>], indices: [UInt32]),
                               scaleA: Double = 1, scaleB: Double = 1, sample: Int = 3000, iterations: Int = 30) -> ChangeMapResult? {
        guard a.positions.count > 10, b.positions.count > 10 else { return nil }
        let pa = a.positions.map { SIMD3<Double>($0) * scaleA }
        let pb = b.positions.map { SIMD3<Double>($0) * scaleB }
        let na = vertexNormals(pa, a.indices)
        let tree = KDTree(pa)
        let fa = ScanMath.principalFrame(pa.map { SIMD3<Float>($0) })
        let fb = ScanMath.principalFrame(pb.map { SIMD3<Float>($0) })
        let picks = spreadIndices(pb.count, want: sample).map { pb[$0] }

        var best: (pose: Pose, fit: Double)?
        for (s0, s1) in [(1.0, 1.0), (1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0)] {
            let b0 = fb.axes[0] * s0, b1 = fb.axes[1] * s1
            let b2 = simd_cross(b0, b1)
            let A = simd_double3x3(columns: (fa.axes[0], fa.axes[1], simd_cross(fa.axes[0], fa.axes[1])))
            let B = simd_double3x3(columns: (b0, b1, b2))
            let R0 = A * B.transpose
            var pose = Pose(R: R0, t: fa.center - R0 * fb.center)
            var fit = Double.infinity
            for _ in 0..<iterations {
                guard let step = icpStep(picks, pose, tree, na, centre: fa.center) else { break }
                pose = step.pose
                fit = step.fit
            }
            if best == nil || fit < best!.fit { best = (pose, fit) }
        }
        guard let chosen = best, chosen.fit.isFinite else { return nil }
        let pose = chosen.pose, fit = chosen.fit

        var signed = [Double](repeating: 0, count: pb.count)
        for (i, p) in pb.enumerated() {
            let q = pose.apply(p)
            if let n = tree.nearest(q) { signed[i] = simd_dot(q - pa[n.index], na[n.index]) }
        }
        let absSorted = signed.map(abs).sorted()
        let sorted = signed.sorted()
        let n = Double(signed.count)
        let mean = signed.reduce(0, +) / n
        let rms = (signed.map { $0 * $0 }.reduce(0, +) / n).squareRoot()
        return ChangeMapResult(pose: pose, signed: signed, mean: mean, median: sorted[sorted.count / 2], rms: rms,
                               p95Abs: absSorted[min(absSorted.count - 1, Int(0.95 * n))], maxAbs: absSorted.last ?? 0,
                               fitRMS: fit)
    }

    /// One linearised point-to-plane step (rotation about the reference centre, damped so a symmetric rock's
    /// free spin stays put). The worst tenth of the matches is left out.
    static func icpStep(_ pts: [SIMD3<Double>], _ pose: Pose, _ tree: KDTree, _ normals: [SIMD3<Double>],
                        centre c: SIMD3<Double>) -> (pose: Pose, fit: Double)? {
        var rows: [(j: [Double], r: Double)] = []
        rows.reserveCapacity(pts.count)
        for p in pts {
            let q = pose.apply(p)
            guard let m = tree.nearest(q) else { continue }
            let nrm = normals[m.index]
            let r = simd_dot(q - tree.points[m.index], nrm)
            let qc = q - c
            let w = simd_cross(qc, nrm)
            rows.append(([w.x, w.y, w.z, nrm.x, nrm.y, nrm.z], r))
        }
        guard rows.count >= 12 else { return nil }
        let cut = rows.map { abs($0.r) }.sorted()[Int(Double(rows.count) * 0.9)]
        var ata = [Double](repeating: 0, count: 36), atb = [Double](repeating: 0, count: 6)
        var ss = 0.0, used = 0.0
        for row in rows where abs(row.r) <= cut {
            for i in 0..<6 {
                atb[i] -= row.j[i] * row.r
                for k in 0..<6 { ata[i * 6 + k] += row.j[i] * row.j[k] }
            }
            ss += row.r * row.r
            used += 1
        }
        let damp = 1e-6 * (0..<6).map { ata[$0 * 6 + $0] }.reduce(0, +) / 6 + 1e-18
        for i in 0..<6 { ata[i * 6 + i] += damp }
        guard let x = LinearSolve.solve(ata, atb, n: 6) else { return nil }
        let Rinc = Pose.rotation(vector: SIMD3(x[0], x[1], x[2]))
        let inc = Pose(R: Rinc, t: c - Rinc * c + SIMD3(x[3], x[4], x[5]))
        return (inc.compose(pose), (ss / max(used, 1)).squareRoot())
    }

    /// Area-weighted vertex normals (outward when the triangles face outward).
    public static func vertexNormals(_ p: [SIMD3<Double>], _ idx: [UInt32]) -> [SIMD3<Double>] {
        var n = [SIMD3<Double>](repeating: .zero, count: p.count)
        var i = 0
        while i + 2 < idx.count {
            let a = Int(idx[i]), b = Int(idx[i + 1]), c = Int(idx[i + 2])
            let f = simd_cross(p[b] - p[a], p[c] - p[a])
            n[a] += f; n[b] += f; n[c] += f
            i += 3
        }
        return n.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }

    /// Blue (lost) through white to red (gained), with ±`range` at full colour.
    public static func colour(_ d: Double, range: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
        let t = range > 0 ? max(-1, min(1, d / range)) : 0
        if t >= 0 {
            let k = UInt8((255 * (1 - t)).rounded())
            return (255, k, k)
        }
        let k = UInt8((255 * (1 + t)).rounded())
        return (k, k, 255)
    }
}
