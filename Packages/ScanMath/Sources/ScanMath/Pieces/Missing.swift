import Foundation
import simd

/// What the pieces were before they broke, as given by the user (sizes in mm) or found from the pieces.
public struct TargetShape: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case auto, cylinder, cuboid, none }
    public var kind: Kind
    /// Cylinder: diameter. Cuboid: longest side.
    public var aMM: Double?
    /// Cylinder: length. Cuboid: middle side.
    public var bMM: Double?
    /// Cuboid: shortest side.
    public var cMM: Double?

    public init(kind: Kind, aMM: Double? = nil, bMM: Double? = nil, cMM: Double? = nil) {
        self.kind = kind
        self.aMM = aMM
        self.bMM = bMM
        self.cMM = cMM
    }
    public static let auto = TargetShape(kind: .auto)
}

/// The envelope placed in the assembly frame.
public struct PlacedEnvelope: Sendable {
    public enum Kind: String, Sendable { case cylinder, box }
    public var kind: Kind
    public var center: SIMD3<Double>
    /// Cylinder: axis in `axes[0]`. Box: three unit axes.
    public var axes: [SIMD3<Double>]
    /// Cylinder: (radius, half length, 0). Box: half sides along the axes.
    public var half: SIMD3<Double>
    /// Given by the user (true) or fitted to the pieces (false).
    public var given: Bool
    /// Which ends or sides were pinned by original outside surface; the rest is a guess.
    public var note: String

    public func contains(_ p: SIMD3<Double>) -> Bool {
        let d = p - center
        switch kind {
        case .cylinder:
            let a = simd_dot(d, axes[0])
            guard abs(a) <= half.y else { return false }
            return simd_length(d - axes[0] * a) <= half.x
        case .box:
            return abs(simd_dot(d, axes[0])) <= half.x && abs(simd_dot(d, axes[1])) <= half.y && abs(simd_dot(d, axes[2])) <= half.z
        }
    }

    public var volume: Double {
        let cyl: Double = Double.pi * half.x * half.x * 2 * half.y
        let box: Double = 8 * half.x * half.y * half.z
        return kind == .cylinder ? cyl : box
    }
}

public struct MissingRegion: Sendable {
    /// "missing_piece" (a chunk of material) or "crack_gap" (thin space between pieces that do not quite close).
    public var kind: String
    public var volume: Double
    public var centroid: SIMD3<Double>
    /// Sides of the region along its own principal directions (metres, largest first).
    public var extents: SIMD3<Double>
    /// Pieces it borders.
    public var neighbours: [Int]
    /// Where it sits in the envelope: share of the length from the bottom (cylinder) and angle round the axis.
    public var axialShare: Double?
    public var angleDegrees: Double?
    /// Cell centres (assembly frame), for drawing.
    public var cells: [SIMD3<Double>]
    public var cellSize: Double
}

public enum MissingFinder {
    /// Places the envelope round a cluster of placed pieces, using samples on the original outside as evidence.
    public static func envelope(_ pieces: [Piece], poses: [Int: Pose], target: TargetShape) -> PlacedEnvelope? {
        var ext: [SIMD3<Double>] = [], extN: [SIMD3<Double>] = [], all: [SIMD3<Double>] = []
        for p in pieces {
            guard let W = poses[p.id] else { continue }
            for i in p.points.indices {
                let q = W.apply(p.points[i])
                all.append(q)
                if p.fracture[i] < 0.4 {
                    ext.append(q)
                    extN.append(W.rotate(p.normals[i]))
                }
            }
        }
        guard all.count >= 50 else { return nil }
        let evidence = ext.count >= 60 ? ext : all
        let evidenceN = ext.count >= 60 ? extN : []

        func cylinderEnvelope(radius givenR: Double?, length givenL: Double?) -> PlacedEnvelope? {
            let fl = evidence.map { SIMD3<Float>($0) }
            guard let fit = ScanMath.fitShape(fl) else { return nil }
            var axis = fit.axis
            let center0 = fit.center
            // The fit of a partial surface may report "irregular" but its best cylinder axis is still the best guess.
            if fit.kind != .cylinder, let frame = Optional(ScanMath.principalFrame(all.map { SIMD3<Float>($0) })) {
                axis = frame.axes[0]
            }
            axis = simd_normalize(axis)
            let r = givenR ?? (fit.radius > 0 ? fit.radius : 0)
            guard r > 0 else { return nil }
            let proj = all.map { simd_dot($0 - center0, axis) }
            let lo = proj.min() ?? 0, hi = proj.max() ?? 0
            // Ends pinned by flat original faces (normals along the axis at the extremes)?
            var topFace = 0, bottomFace = 0
            for (k, q) in ext.enumerated() where k < evidenceN.count {
                let a = simd_dot(q - center0, axis), c = simd_dot(evidenceN[k], axis)
                if c > 0.9 && a > hi - 0.03 * (hi - lo) { topFace += 1 }
                if c < -0.9 && a < lo + 0.03 * (hi - lo) { bottomFace += 1 }
            }
            let L = Swift.max(givenL ?? (hi - lo), hi - lo)
            var mid: Double
            var note: String
            if topFace >= 20 && bottomFace < 20 {
                mid = hi - L / 2
                note = "top end found on the pieces; anything missing is placed below it"
            } else if bottomFace >= 20 && topFace < 20 {
                mid = lo + L / 2
                note = "bottom end found on the pieces; anything missing is placed above it"
            } else {
                mid = (lo + hi) / 2
                note = topFace >= 20 ? "both ends found on the pieces" : "no original end face found: the length position is a guess"
            }
            // Centre the axis on the side evidence.
            var ctr = center0 + axis * (mid - 0)
            if fit.kind != .cylinder {
                let c = all.centroid
                ctr = c + axis * (mid - simd_dot(c - center0, axis))
            }
            return PlacedEnvelope(kind: .cylinder, center: ctr, axes: [axis], half: SIMD3(r, L / 2, 0), given: givenR != nil, note: note)
        }

        func boxEnvelope(sides given: [Double]?) -> PlacedEnvelope {
            let frame = ScanMath.principalFrame(all.map { SIMD3<Float>($0) })
            let axes = frame.axes.map { simd_normalize($0) }
            var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
            for q in all {
                let v = SIMD3(simd_dot(q, axes[0]), simd_dot(q, axes[1]), simd_dot(q, axes[2]))
                lo = simd_min(lo, v)
                hi = simd_max(hi, v)
            }
            var half = (hi - lo) / 2
            let mid = (hi + lo) / 2
            if let g = given?.sorted(by: >), g.count == 3 {
                // Largest given side along the longest principal axis, and so on; never smaller than the pieces.
                half = SIMD3(Swift.max(g[0] / 2, half.x), Swift.max(g[1] / 2, half.y), Swift.max(g[2] / 2, half.z))
            }
            let center = axes[0] * mid.x + axes[1] * mid.y + axes[2] * mid.z
            return PlacedEnvelope(kind: .box, center: center, axes: axes, half: half, given: given != nil,
                                  note: given != nil ? "box centred on the pieces along its principal directions" : "box fitted round the pieces")
        }

        switch target.kind {
        case .none:
            return nil
        case .cylinder:
            return cylinderEnvelope(radius: target.aMM.map { $0 / 2000 }, length: target.bMM.map { $0 / 1000 })
        case .cuboid:
            let sides = [target.aMM, target.bMM, target.cMM].compactMap { $0 }.map { $0 / 1000 }
            return boxEnvelope(sides: sides.count == 3 ? sides : nil)
        case .auto:
            if let fit = ScanMath.fitShape(evidence.map { SIMD3<Float>($0) }), fit.kind == .cylinder, fit.inlierShare > 0.3 {
                return cylinderEnvelope(radius: nil, length: nil)
            }
            return boxEnvelope(sides: nil)
        }
    }

    /// Empty space inside the envelope that no piece fills, split into regions.
    public static func regions(_ pieces: [Piece], poses: [Int: Pose], envelope env: PlacedEnvelope, cellsAcross: Int = 40)
        -> (regions: [MissingRegion], filledVolume: Double, emptyVolume: Double) {
        let placed = pieces.filter { poses[$0.id] != nil }
        // Bounding box of the envelope.
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        var corners: [SIMD3<Double>] = []
        let signs: [Double] = [-1, 1]
        let ax0: SIMD3<Double>, ax1: SIMD3<Double>, ax2: SIMD3<Double>
        let h0: Double, h1: Double, h2: Double
        if env.kind == .cylinder {
            let a = env.axes[0]
            let u = simd_normalize(simd_cross(a, abs(a.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)))
            ax0 = a
            ax1 = u
            ax2 = simd_cross(a, u)
            h0 = env.half.y
            h1 = env.half.x
            h2 = env.half.x
        } else {
            ax0 = env.axes[0]
            ax1 = env.axes[1]
            ax2 = env.axes[2]
            h0 = env.half.x
            h1 = env.half.y
            h2 = env.half.z
        }
        for s0 in signs {
            for s1 in signs {
                for s2 in signs {
                    let d0: SIMD3<Double> = ax0 * (s0 * h0)
                    let d1: SIMD3<Double> = ax1 * (s1 * h1)
                    let d2: SIMD3<Double> = ax2 * (s2 * h2)
                    corners.append(env.center + d0 + d1 + d2)
                }
            }
        }
        for c in corners {
            lo = simd_min(lo, c)
            hi = simd_max(hi, c)
        }
        let ext = hi - lo
        let spacing = placed.map { $0.spacing }.min() ?? 0.001
        let cell = Swift.max(spacing * 0.8, Swift.max(ext.x, Swift.max(ext.y, ext.z)) / Double(cellsAcross))
        let nx = Int(ext.x / cell) + 1, ny = Int(ext.y / cell) + 1, nz = Int(ext.z / cell) + 1
        let inv = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, poses[$0.id]!.inverse) })

        // 0 = outside the envelope, 1 = filled by a piece, 2 = empty.
        var state = [UInt8](repeating: 0, count: nx * ny * nz)
        func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }
        var filled = 0, empty = 0
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let idx = SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5)
            let q: SIMD3<Double> = lo + idx * cell
            guard env.contains(q) else { continue }
            var inside = false
            for p in placed {
                let local = inv[p.id]!.apply(q)
                if simd_length(local - p.centroid) > p.radius + cell { continue }
                // Inside, or within half a cell of the surface (cracks narrower than a cell are not "missing").
                if p.signedDistance(local) < 0.5 * cell {
                    inside = true
                    break
                }
            }
            if inside { state[index(i, j, k)] = 1; filled += 1 } else { state[index(i, j, k)] = 2; empty += 1 }
        } } }

        // Thin gaps: empty cells that vanish after one erosion step.
        var core = [Bool](repeating: false, count: state.count)
        let nbr = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where state[index(i, j, k)] == 2 {
            var keep = true
            for (di, dj, dk) in nbr {
                let a = i + di, b = j + dj, c = k + dk
                if a < 0 || b < 0 || c < 0 || a >= nx || b >= ny || c >= nz || state[index(a, b, c)] == 1 { keep = false; break }
            }
            core[index(i, j, k)] = keep
        } } }

        // Connected empty regions.
        var label = [Int](repeating: -1, count: state.count)
        var out: [MissingRegion] = []
        let minCells = Swift.max(4, Int(0.002 * Double(filled + empty)))
        for start in state.indices where state[start] == 2 && label[start] < 0 {
            var queue = [start]
            label[start] = out.count
            var head = 0
            var coreCount = 0
            while head < queue.count {
                let c = queue[head]
                head += 1
                if core[c] { coreCount += 1 }
                let i = c % nx, j = (c / nx) % ny, k = c / (nx * ny)
                for (di, dj, dk) in nbr {
                    let a = i + di, b = j + dj, cc = k + dk
                    guard a >= 0, b >= 0, cc >= 0, a < nx, b < ny, cc < nz else { continue }
                    let n = index(a, b, cc)
                    if state[n] == 2 && label[n] < 0 {
                        label[n] = out.count
                        queue.append(n)
                    }
                }
            }
            guard queue.count >= minCells else {
                out.append(MissingRegion(kind: "noise", volume: 0, centroid: .zero, extents: .zero, neighbours: [], cells: [], cellSize: cell))
                continue
            }
            let pts = queue.map { c -> SIMD3<Double> in
                let i = c % nx, j = (c / nx) % ny, k = c / (nx * ny)
                let idx = SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5)
                return lo + idx * cell
            }
            let centroid = pts.centroid
            let frame = ScanMath.principalFrame(pts.map { SIMD3<Float>($0) })
            var e = SIMD3<Double>.zero
            for (n, ax) in frame.axes.prefix(3).enumerated() {
                let proj = pts.map { simd_dot($0 - centroid, simd_normalize(ax)) }
                e[n] = (proj.max() ?? 0) - (proj.min() ?? 0) + cell
            }
            let sortedE = [e.x, e.y, e.z].sorted(by: >)
            var neighbours: [Int] = []
            let probe = stride(from: 0, to: pts.count, by: Swift.max(1, pts.count / 300)).map { pts[$0] }
            for p in placed {
                let W = inv[p.id]!
                if probe.contains(where: { q in
                    let l = W.apply(q)
                    return simd_length(l - p.centroid) < p.radius + 2 * cell && abs(p.signedDistance(l)) < 1.6 * cell
                }) { neighbours.append(p.id) }
            }
            var axial: Double?, angle: Double?
            if env.kind == .cylinder {
                let a = env.axes[0]
                let along: Double = simd_dot(centroid - env.center, a)
                axial = (along + env.half.y) / (2 * env.half.y)
                let u = simd_normalize(simd_cross(a, abs(a.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)))
                let v = simd_cross(a, u)
                let d = centroid - env.center
                var deg = atan2(simd_dot(d, v), simd_dot(d, u)) * 180 / .pi
                if deg < 0 { deg += 360 }
                angle = deg
            }
            let thin = coreCount == 0 || sortedE[2] < 2.2 * cell
            out.append(MissingRegion(kind: thin ? "crack_gap" : "missing_piece", volume: Double(queue.count) * cell * cell * cell,
                                     centroid: centroid, extents: SIMD3(sortedE[0], sortedE[1], sortedE[2]), neighbours: neighbours,
                                     axialShare: axial, angleDegrees: angle,
                                     cells: stride(from: 0, to: pts.count, by: Swift.max(1, pts.count / 4000)).map { pts[$0] },
                                     cellSize: cell))
        }
        let v = cell * cell * cell
        let regions = out.filter { $0.kind != "noise" }.sorted { $0.volume > $1.volume }
        return (regions, Double(filled) * v, Double(empty) * v)
    }
}
