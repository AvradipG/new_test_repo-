import Foundation
import simd

/// Pairwise matching of two pieces, following the DRA Fragment Reconstruction Studio method: break facets are put
/// face to face and spun about their common normal, every start is refined by "contact ICP" (point-to-plane on
/// samples whose normals oppose), and each pose is scored on how much break surface touches, how tightly, and
/// how little the pieces overlap. A low residual alone is never taken as a match: a pose with little contact is
/// not a match.
public struct MatchParams: Sendable {
    public var spins = 24
    public var facetPairs = 30
    public var preIterations = 10
    public var preSamples = 300
    public var keepAfterPre = 8
    public var iterations = 18
    public var maxCandidates = 4
    public init() {}
}

public struct PairCandidate: Sendable {
    /// Moves piece a into piece b's frame.
    public var pose: Pose
    public var score: Double
    public var contactShare: Double
    public var penetration: Double
    public var rms: Double
}

public struct PairMatch: Sendable {
    public var a: Int
    public var b: Int
    public var candidates: [PairCandidate]
    public var best: PairCandidate? { candidates.first }
    /// Runner-up / best score (0 = unique, 1 = two equally good poses).
    public var ambiguity: Double {
        guard candidates.count > 1, let s = candidates.first?.score, s > 0 else { return 0 }
        return candidates[1].score / s
    }
}

public enum PieceMatcher {
    /// Contact tolerance: expected distance between two touching break surfaces sampled at spacing h.
    static func sigma(_ a: Piece, _ b: Piece) -> Double { 0.3 * Swift.max(a.spacing, b.spacing) }

    /// Aligns `src` (moved by `start`) onto the outside of the surface in `tree` (normals opposed).
    static func contactICP(src: [SIMD3<Double>], srcN: [SIMD3<Double>], srcW: [Double],
                           tree: KDTree, tgtN: [SIMD3<Double>], start: Pose, h: Double,
                           iterations: Int, dStart: Double = 4, dEnd: Double = 1.5, sigma: Double,
                           opposed: Bool = true) -> Pose {
        var T = start
        for it in 0..<iterations {
            let ramp: Double = Swift.max(1, Double(iterations) * 0.6)
            let f: Double = Swift.min(1, Double(it) / ramp)
            let dmax: Double = h * (dStart + (dEnd - dStart) * f)
            var rows: [(SIMD3<Double>, SIMD3<Double>, Double, Double)] = []
            rows.reserveCapacity(src.count)
            for i in src.indices {
                let p = T.apply(src[i])
                guard let nn = tree.nearest(p, maxDistance: dmax) else { continue }
                let n = T.rotate(srcN[i])
                let m = tgtN[nn.index]
                let c = simd_dot(n, m)
                if opposed ? c > -0.4 : c < 0.4 { continue }
                let r = simd_dot(p - tree.points[nn.index], m)
                rows.append((simd_cross(p, m), m, r, srcW[i]))
            }
            guard rows.count >= 12 else { break }
            let s = Swift.max(sigma, 1.4826 * ScanMath.median(rows.map { abs($0.2) }))
            var A = [Double](repeating: 0, count: 36), b = [Double](repeating: 0, count: 6)
            for (cpm, m, r, w0) in rows {
                let q: Double = r / (2 * s)
                let w: Double = w0 / (1 + q * q)
                let J = [cpm.x, cpm.y, cpm.z, m.x, m.y, m.z]
                for u in 0..<6 {
                    let ju = J[u] * w
                    b[u] -= ju * r
                    for v in 0..<6 { A[u * 6 + v] += ju * J[v] }
                }
            }
            for u in 0..<6 { A[u * 6 + u] += 1e-12 + 1e-9 * A[u * 6 + u] }
            guard let x = LinearSolve.solve(A, b, n: 6) else { break }
            let w = SIMD3(x[0], x[1], x[2]), v = SIMD3(x[3], x[4], x[5])
            T = Pose(R: Pose.rotation(vector: w), t: v).compose(T)
            if simd_length(w) < 1e-5 && simd_length(v) < 1e-3 * h { break }
        }
        return T
    }

    /// Soft contact of `src` moved by T against `tgt`: (area, break-weighted area, rms of touching samples).
    static func contact(_ src: Piece, _ T: Pose, _ tgt: Piece, sigma: Double, sampleStep: Int = 1) -> (area: Double, weighted: Double, rms: Double) {
        let h = Swift.max(src.spacing, tgt.spacing)
        var area = 0.0, weighted = 0.0, sq = 0.0, n = 0
        let picked = sampleStep > 1 ? spreadIndices(src.points.count, want: src.points.count / sampleStep) : Array(src.points.indices)
        for i in picked {
            let p = T.apply(src.points[i])
            guard let nn = tgt.tree.nearest(p, maxDistance: 2 * h) else { continue }
            let m = tgt.normals[nn.index]
            guard simd_dot(T.rotate(src.normals[i]), m) < -0.5 else { continue }
            let d = abs(simd_dot(p - tgt.points[nn.index], m))
            let ds: Double = d / sigma
            let k: Double = exp(-0.5 * ds * ds)
            let fa: Double = Swift.max(0, Swift.min(1, src.fracture[i]))
            let fb: Double = Swift.max(0, Swift.min(1, tgt.fracture[nn.index]))
            let wt: Double = (fa * fb).squareRoot()
            area += k
            weighted += wt * k
            if d < 2 * sigma {
                sq += d * d
                n += 1
            }
        }
        let scale = src.areaPerPoint * Double(src.points.count) / Double(Swift.max(1, picked.count))
        return (area * scale, weighted * scale, n > 0 ? (sq / Double(n)).squareRoot() : .infinity)
    }

    /// Share of `src`'s interior samples lying deeper than `tol` inside `tgt`.
    static func penetration(_ src: Piece, _ T: Pose, _ tgt: Piece, tol: Double) -> Double {
        guard !src.interior.isEmpty else { return 0 }
        let lo = tgt.lo - SIMD3(repeating: tol), hi = tgt.hi + SIMD3(repeating: tol)
        var inside = 0
        for q0 in src.interior {
            let q = T.apply(q0)
            if q.x < lo.x || q.y < lo.y || q.z < lo.z || q.x > hi.x || q.y > hi.y || q.z > hi.z { continue }
            if tgt.signedDistance(q) < -tol { inside += 1 }
        }
        return Double(inside) / Double(src.interior.count)
    }

    public static func evaluate(_ a: Piece, _ b: Piece, _ T: Pose) -> PairCandidate {
        let sig = sigma(a, b)
        let c1 = contact(a, T, b, sigma: sig), c2 = contact(b, T.inverse, a, sigma: sig)
        let weighted = (c1.weighted + c2.weighted) / 2
        let area = (c1.area + c2.area) / 2
        let denom = Swift.min(a.surfaceArea, b.surfaceArea)
        let tol = 1.5 * Swift.max(a.spacing, b.spacing)
        let pen = Swift.max(penetration(a, T, b, tol: tol), penetration(b, T.inverse, a, tol: tol))
        let rr = [c1.rms, c2.rms].filter { $0.isFinite }
        let damp: Double = exp(-pen / 0.03)
        let score: Double = weighted / denom * damp
        return PairCandidate(pose: T, score: score, contactShare: area / denom, penetration: pen,
                             rms: rr.isEmpty ? .infinity : rr.reduce(0, +) / Double(rr.count))
    }

    static func distinct(_ list: [PairCandidate], piece: Piece, limit: Int) -> [PairCandidate] {
        let probe = spreadIndices(piece.points.count, want: 150).map { piece.points[$0] }
        var keep: [PairCandidate] = []
        for c in list {
            if keep.contains(where: { Pose.displacement($0.pose, c.pose, points: probe) < 2.5 * piece.spacing }) { continue }
            keep.append(c)
            if keep.count >= limit { break }
        }
        return keep
    }

    /// All good poses of piece a against piece b, best first.
    public static func match(_ a: Piece, _ b: Piece, params: MatchParams = MatchParams()) -> PairMatch {
        let h = Swift.max(a.spacing, b.spacing)
        let sig = sigma(a, b)
        // Facet pairs of compatible size.
        // Whole break against whole break first, then facet against facet.
        var pairs: [(Double, Int, Int)] = []
        for (i, fa) in a.facets.enumerated() {
            for (j, fb) in b.facets.enumerated() where fa.coarse == fb.coarse {
                let r = fa.area / fb.area
                let rank: Double = abs(log(r)) + (fa.coarse ? 0 : 10)
                if r > 0.2 && r < 5 { pairs.append((rank, i, j)) }
            }
        }
        pairs.sort { $0.0 < $1.0 }
        var starts: [Pose] = []
        for (_, i, j) in pairs.prefix(params.facetPairs) {
            let fa = a.facets[i], fb = b.facets[j]
            let R0 = Pose.align(fa.normal, to: -fb.normal)
            for k in 0..<params.spins {
                let Rs = Pose.rotation(axis: -fb.normal, degrees: 360 * Double(k) / Double(params.spins)) * R0
                starts.append(Pose(R: Rs, t: fb.centroid - Rs * fa.centroid))
            }
        }
        // Short contact ICP from every start on a subset of a's break samples.
        var order = a.points.indices.filter { a.fracture[$0] > 0.35 }
        if order.count < 60 { order = Array(a.points.indices) }
        let stepSub = Swift.max(1, order.count / params.preSamples)
        let sub = spreadIndices(order.count, want: order.count / stepSub).map { order[$0] }
        let sp = sub.map { a.points[$0] }, sn = sub.map { a.normals[$0] }, sw = sub.map { a.fracture[$0] + 0.05 }
        var pre: [PairCandidate] = []
        for s in starts {
            let T = contactICP(src: sp, srcN: sn, srcW: sw, tree: b.tree, tgtN: b.normals, start: s, h: h,
                               iterations: params.preIterations, sigma: sig)
            let c = contact(a, T, b, sigma: sig, sampleStep: 2)
            let pen = penetration(a, T, b, tol: 1.5 * h)
            pre.append(PairCandidate(pose: T, score: c.weighted * exp(-pen / 0.03), contactShare: 0, penetration: pen, rms: c.rms))
        }
        pre.sort { $0.score > $1.score }
        let seeds = distinct(pre, piece: a, limit: params.keepAfterPre)
        let wAll = a.fracture.map { $0 + 0.05 }
        var refined: [PairCandidate] = []
        for s in seeds {
            let T = contactICP(src: a.points, srcN: a.normals, srcW: wAll, tree: b.tree, tgtN: b.normals, start: s.pose, h: h,
                               iterations: params.iterations, sigma: sig)
            refined.append(evaluate(a, b, T))
        }
        refined.sort { $0.score > $1.score }
        return PairMatch(a: a.id, b: b.id, candidates: distinct(refined, piece: a, limit: params.maxCandidates))
    }
}
