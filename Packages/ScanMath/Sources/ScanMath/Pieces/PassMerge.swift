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
    static func rotations(directions: Int = 42, yaws: Int = 12) -> [simd_double3x3] {
        var out: [simd_double3x3] = []
        let golden = Double.pi * (3 - 5.0.squareRoot())
        for i in 0..<directions {
            let y = 1 - 2 * (Double(i) + 0.5) / Double(directions)
            let r = (1 - y * y).squareRoot()
            let th = golden * Double(i)
            let d = SIMD3(r * cos(th), y, r * sin(th))
            let R0 = Pose.align(SIMD3(0, 1, 0), to: d)
            for k in 0..<yaws {
                out.append(Pose.rotation(axis: d, degrees: 360 * Double(k) / Double(yaws)) * R0)
            }
        }
        return out
    }

    static func score(_ a: Piece, _ b: Piece, _ T: Pose, floorA: Double, probe: [Int], h: Double) -> (overlap: Double, conflict: Double, rms: Double) {
        var on = 0, bad = 0, sq = 0.0
        for i in probe {
            let p = T.apply(b.points[i])
            if p.y < floorA - 2 * h {
                bad += 1
                continue
            }
            guard let nn = a.tree.nearest(p) else { continue }
            let d = simd_dot(p - a.points[nn.index], a.normals[nn.index])
            if nn.distance < 1.5 * h && simd_dot(T.rotate(b.normals[i]), a.normals[nn.index]) > 0.5 {
                on += 1
                sq += d * d
            } else if d > 2 * h && nn.distance < 6 * h && a.normals[nn.index].y > -0.3 {
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
    public static func merge(_ a: Piece, _ b: Piece, floorA: Double) -> SideMerge {
        let h = Swift.max(a.spacing, b.spacing)
        let probe = Array(stride(from: 0, to: b.points.count, by: Swift.max(1, b.points.count / 220)))
        var starts: [(Double, Pose)] = []
        let ca = a.centroid, cb = b.centroid
        let thick = Swift.max(a.hi.y - a.lo.y, h)
        for R in rotations() {
            for dy in [-0.5, 0.0, 0.5] {
                let t = ca + SIMD3(0, dy * thick, 0) - R * cb
                let T = Pose(R: R, t: t)
                let s = score(a, b, T, floorA: floorA, probe: probe, h: h)
                starts.append((s.overlap - 2 * s.conflict, T))
            }
        }
        starts.sort { $0.0 > $1.0 }
        var best: SideMerge?
        let w = [Double](repeating: 1, count: b.points.count)
        for (_, T0) in starts.prefix(10) {
            let T = PieceMatcher.contactICP(src: b.points, srcN: b.normals, srcW: w, tree: a.tree, tgtN: a.normals, start: T0, h: h,
                                            iterations: 20, dStart: 4, dEnd: 1.2, sigma: 0.3 * h, opposed: false)
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
