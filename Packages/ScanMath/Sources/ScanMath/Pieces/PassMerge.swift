import Foundation
import simd

/// Joins the two sides of one piece: scanned once as it lay, then again after it was turned over. The second
/// scan is fitted onto the first where both saw the same surface (the sides), with no part of it allowed in the
/// space the first scan saw as empty.
public struct SideMerge: Sendable {
    /// Moves the second scan's piece into the first scan's frame.
    public var pose: Pose
    /// Share of the smaller side's samples lying on the other side's surface.
    public var overlap: Double
    /// Share of moved samples that land in space the first scan saw as empty (or under the table).
    public var conflict: Double
    public var rms: Double
    public var accepted: Bool
}

public enum SideMerger {
    /// Rotations covering all orientations about 25° apart.
    static func rotations(directions: Int = 60, yaws: Int = 16) -> [simd_double3x3] {
        var out: [simd_double3x3] = []
        let golden = Double.pi * (3 - 5.0.squareRoot())
        for i in 0..<directions {
            let y: Double = 1 - 2 * (Double(i) + 0.5) / Double(directions)
            let r: Double = (1 - y * y).squareRoot()
            let th: Double = golden * Double(i)
            let d = SIMD3(r * cos(th), y, r * sin(th))
            let R0 = Pose.align(SIMD3(0, 1, 0), to: d)
            for k in 0..<yaws {
                out.append(Pose.rotation(axis: d, degrees: 360 * Double(k) / Double(yaws)) * R0)
            }
        }
        return out
    }

    /// - loose: wide tolerances, for ranking rough starting poses before any refinement.
    static func score(_ a: Piece, _ b: Piece, _ T: Pose, floorA: Double, probe: [Int], h: Double, loose: Bool = false)
        -> (overlap: Double, conflict: Double, rms: Double) {
        let near = loose ? 5 * h : 1.5 * h
        let ahead = loose ? 5 * h : 2 * h
        let reach = loose ? 10 * h : 6 * h
        let agree = loose ? 0.2 : 0.5
        var on = 0, bad = 0, sq = 0.0
        for i in probe {
            let p = T.apply(b.points[i])
            if p.y < floorA - (loose ? 4 : 2) * h {
                bad += 1
                continue
            }
            guard let nn = a.tree.nearest(p) else { continue }
            let d = simd_dot(p - a.points[nn.index], a.normals[nn.index])
            if nn.distance < near && simd_dot(T.rotate(b.normals[i]), a.normals[nn.index]) > agree {
                on += 1
                sq += d * d
            } else if d > ahead && nn.distance < reach && a.normals[nn.index].y > -0.3 {
                // In front of a surface the first scan saw: that space is empty.
                bad += 1
            }
        }
        let n = Double(Swift.max(1, probe.count))
        return (Double(on) / n, Double(bad) / n, on > 0 ? (sq / Double(on)).squareRoot() : .infinity)
    }

    /// - Parameters:
    ///   - a: the piece as first scanned (open where it touched the table)
    ///   - b: the same piece from the second scan, in that scan's frame
    ///   - floorA: table height in the first scan
    ///   - floorB: table height in the second scan (default: the lowest point seen)
    public static func merge(_ a: Piece, _ b: Piece, floorA: Double, floorB: Double? = nil) -> SideMerge {
        let h = Swift.max(a.spacing, b.spacing)
        let probe = spreadIndices(b.points.count, want: 220)
        var starts: [(Double, Pose)] = []
        // The whole piece stands between the table and its top: that middle is the same point in both scans
        // (the centroid of what each scan saw is not: each saw a different part).
        let fb = floorB ?? b.lo.y
        let ca = SIMD3<Double>((a.lo.x + a.hi.x) / 2, (floorA + a.hi.y) / 2, (a.lo.z + a.hi.z) / 2)
        let cb = SIMD3<Double>((b.lo.x + b.hi.x) / 2, (fb + b.hi.y) / 2, (b.lo.z + b.hi.z) / 2)
        let thick = Swift.max(a.hi.y - floorA, h)
        for R in rotations() {
            for dy in [-0.15, 0.0, 0.15] {
                let lift = SIMD3<Double>(0, dy * thick, 0)
                let t: SIMD3<Double> = ca + lift - R * cb
                let T = Pose(R: R, t: t)
                let s = score(a, b, T, floorA: floorA, probe: probe, h: h, loose: true)
                starts.append((s.overlap - 2 * s.conflict, T))
            }
        }
        starts.sort { $0.0 > $1.0 }
        // Keep starts that really differ (a near-symmetric piece otherwise fills the list with one wrong guess).
        var seeds: [Pose] = []
        for (_, T) in starts {
            let dup = seeds.contains { S in
                Pose(R: S.R.transpose * T.R).angleDegrees < 25 && simd_length(S.t - T.t) < 4 * h
            }
            if !dup { seeds.append(T) }
            if seeds.count >= 40 { break }
        }
        // Short refinement on a subset, then full refinement of the best few.
        let subIdx = spreadIndices(b.points.count, want: 600)
        let sp = subIdx.map { b.points[$0] }, sn = subIdx.map { b.normals[$0] }
        let sw = [Double](repeating: 1, count: subIdx.count)
        var rough: [(Double, Pose)] = []
        for T0 in seeds {
            let T = PieceMatcher.contactICP(src: sp, srcN: sn, srcW: sw, tree: a.tree, tgtN: a.normals, start: T0, h: h,
                                            iterations: 16, dStart: 7, dEnd: 1.5, sigma: 0.3 * h, opposed: false)
            let s = score(a, b, T, floorA: floorA, probe: probe, h: h)
            rough.append((s.overlap - 2 * s.conflict, T))
        }
        rough.sort { $0.0 > $1.0 }
        var best: SideMerge?
        let w = [Double](repeating: 1, count: b.points.count)
        for (_, T0) in rough.prefix(4) {
            let T = PieceMatcher.contactICP(src: b.points, srcN: b.normals, srcW: w, tree: a.tree, tgtN: a.normals, start: T0, h: h,
                                            iterations: 20, dStart: 2.5, dEnd: 1.0, sigma: 0.3 * h, opposed: false)
            let s = score(a, b, T, floorA: floorA, probe: probe, h: h)
            let value = s.overlap - 2 * s.conflict
            if best == nil || value > best!.overlap - 2 * best!.conflict {
                best = SideMerge(pose: T, overlap: s.overlap, conflict: s.conflict, rms: s.rms, accepted: false)
            }
        }
        guard var m = best else { return SideMerge(pose: .identity, overlap: 0, conflict: 1, rms: .infinity, accepted: false) }
        m.accepted = m.overlap >= 0.12 && m.conflict <= 0.12
        return m
    }

    /// One closed sample set from both sides: the first side, plus the second side where the first saw nothing.
    public static func combine(_ a: Piece, _ b: Piece, _ m: SideMerge, floorA: Double, floorB: Double, id: Int) -> Piece {
        let h = Swift.max(a.spacing, b.spacing)
        var pts: [SIMD3<Double>] = [], nrm: [SIMD3<Double>] = []
        for i in a.points.indices where a.points[i].y > floorA + 0.6 * h {
            pts.append(a.points[i])
            nrm.append(a.normals[i])
        }
        let tree = KDTree(pts)
        for i in b.points.indices where b.points[i].y > floorB + 0.6 * h {
            let p = m.pose.apply(b.points[i])
            if let nn = tree.nearest(p, maxDistance: 0.9 * h), nn.distance < 0.9 * h { continue }
            pts.append(p)
            nrm.append(m.pose.rotate(b.normals[i]))
        }
        return Piece(id: id, points: pts, normals: nrm, spacing: h)
    }
}
