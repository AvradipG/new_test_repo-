import Foundation
import simd

/// A scanned mesh in metres, +Y up (Object Capture frame).
public struct SceneMesh: Sendable {
    public var positions: [SIMD3<Double>]
    public var triangles: [SIMD3<Int>]
    public init(positions: [SIMD3<Double>], triangles: [SIMD3<Int>]) {
        self.positions = positions
        self.triangles = triangles
    }
}

public struct ReconstructionOptions: Sendable {
    public var target: TargetShape = .auto
    /// Matched pieces at most (largest first); the rest are listed only.
    public var maxMatched = 14
    public var sampleSpacing: Double?
    public var match = MatchParams()
    public var assembly = AssemblyParams()
    public init() {}
}

/// Everything the app needs to show and save a reconstruction.
public final class Reconstruction {
    public struct Item {
        public var id: Int
        public var first: SceneComponent
        public var second: SceneComponent?
        /// Moves the second scan's component into the first scan's frame.
        public var secondPose: Pose?
        public var piece: Piece
        public var merge: SideMerge?
    }
    public var items: [Item] = []
    public var split1: SceneSplit
    public var split2: SceneSplit?
    public var assembly: AssemblyResult?
    public var envelope: PlacedEnvelope?
    public var missing: [MissingRegion] = []
    public var filledVolume = 0.0
    public var emptyVolume = 0.0
    public var report: PiecesReport

    init(split1: SceneSplit, split2: SceneSplit?, report: PiecesReport) {
        self.split1 = split1
        self.split2 = split2
        self.report = report
    }
}

// MARK: - Report (written as JSON for the lab software)

public struct PiecesReport: Codable, Sendable {
    public struct PieceEntry: Codable, Sendable {
        public var id: Int
        public var label: String
        /// "anchor", "placed", "unplaced", "not_matched"
        public var status: String
        /// "both" (turned over and joined), "first_only"
        public var sides: String
        public var sideJoinOverlap: Double?
        public var sizeMM: [Double]
        public var volumeCM3: Double
        public var surfaceCM2: Double
        public var asFoundCentreMM: [Double]
        public var poseInAssembly: [Double]?
        public var cluster: Int?
        public var placedVia: String?
        public var touches: [String]
        public var confirmedBy: [String]
        public var contactShare: Double?
        public var overlapShare: Double?
        public var ambiguity: Double?
        public var confidence: String
        public var note: String?
    }
    public struct SmallEntry: Codable, Sendable {
        public var label: String
        public var sizeMM: Double
        public var volumeCM3: Double?
        public var asFoundCentreMM: [Double]
    }
    public struct MissingEntry: Codable, Sendable {
        public var label: String
        public var kind: String
        public var volumeCM3: Double
        public var sizeMM: [Double]
        public var centreMM: [Double]
        public var heightShare: Double?
        public var angleDegrees: Double?
        public var between: [String]
        public var description: String
    }
    public struct Envelope: Codable, Sendable {
        public var kind: String
        public var given: Bool
        public var diameterMM: Double?
        public var lengthMM: Double?
        public var sidesMM: [Double]?
        public var volumeCM3: Double
        public var centreMM: [Double]
        public var axis: [Double]
        public var note: String
    }
    public struct Volumes: Codable, Sendable {
        public var envelopeCM3: Double?
        public var piecesCM3: Double
        public var smallFragmentsCM3: Double
        public var missingCM3: Double?
        public var recoveredShare: Double?
    }

    public var schema = "crystal-bowl.pieces/1"
    public var target: TargetShape
    public var envelope: Envelope?
    public var pieces: [PieceEntry] = []
    public var small: [SmallEntry] = []
    public var specks = 0
    public var missing: [MissingEntry] = []
    public var volumes = Volumes(envelopeCM3: nil, piecesCM3: 0, smallFragmentsCM3: 0, missingCM3: nil, recoveredShare: nil)
    public var groups: [[String]] = []
    public var containerRemoved = false
    public var guidance: [String] = []
    public var limits: [String] = []
    public var method = "Geometry-only reassembly (DRA Fragment Reconstruction Studio method, phone port): break facets placed face to face and spun, contact ICP, scored on break contact, tightness and overlap; beam-search assembly; empty space inside the target shape split into missing regions."
    public var units = "mm, cm³; poses are 4x4 row-major matrices in metres, from the first scan's frame to the assembly frame"
}

public enum PieceReconstructor {
    static func mm(_ v: SIMD3<Double>) -> [Double] { [v.x * 1000, v.y * 1000, v.z * 1000].map { ($0 * 100).rounded() / 100 } }

    static func pieceFrom(_ c: SceneComponent, mesh: SceneMesh, id: Int, spacing: Double) -> Piece {
        let s = Piece.sample(positions: mesh.positions, triangles: c.triangles, spacing: spacing, maxPoints: 2500, seed: UInt64(id + 7))
        // Actual spacing (large pieces are capped at 2500 samples, so theirs is coarser than asked).
        let actual = Swift.max(spacing, (s.area / Double(Swift.max(1, s.points.count))).squareRoot())
        return Piece(id: id, points: s.points, normals: s.normals, spacing: actual, area: s.area, volume: c.closedVolume)
    }

    /// Samples lying on a cylinder of the target radius (the core's outside) or on its flat ends.
    static func cylinderExterior(_ p: Piece, radius R: Double) -> [Bool] {
        var rng = SplitMix64(seed: UInt64(p.id) &* 31 &+ 5)
        let n = p.points.count
        var best: (count: Int, mask: [Bool])?
        guard n >= 30 else { return [Bool](repeating: false, count: n) }
        for _ in 0..<150 {
            let i = Int(rng.next() % UInt64(n)), j = Int(rng.next() % UInt64(n))
            var a = simd_cross(p.normals[i], p.normals[j])
            guard simd_length(a) > 0.3 else { continue }
            a = simd_normalize(a)
            let side = p.points.indices.filter { abs(simd_dot(p.normals[$0], a)) < 0.2 }
            guard side.count >= 30 else { continue }
            let u = simd_normalize(simd_cross(a, abs(a.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)))
            let v = simd_cross(a, u)
            let flat = side.map { SIMD2(simd_dot(p.points[$0], u), simd_dot(p.points[$0], v)) }
            guard let c = ScanMath.circleFit(flat), abs(c.radius - R) < 0.2 * R else { continue }
            let tol = Swift.max(0.04 * R, 1.5 * p.spacing)
            var mask = [Bool](repeating: false, count: n)
            var count = 0
            for (k, idx) in side.enumerated() {
                let d = flat[k] - c.center
                let dist = simd_length(d)
                guard abs(dist - R) < tol, dist > 0 else { continue }
                let radial = u * (d.x / dist) + v * (d.y / dist)
                if simd_dot(p.normals[idx], radial) > 0.8 {
                    mask[idx] = true
                    count += 1
                }
            }
            if count > (best?.count ?? 0) {
                // Flat ends of the core: normals along the axis at the extremes.
                let proj = p.points.map { simd_dot($0, a) }
                let lo = proj.min() ?? 0, hi = proj.max() ?? 0
                for k in 0..<n where abs(simd_dot(p.normals[k], a)) > 0.95 && (proj[k] > hi - 1.5 * p.spacing || proj[k] < lo + 1.5 * p.spacing) {
                    mask[k] = true
                }
                best = (count, mask)
            }
        }
        guard let b = best, b.count >= Swift.max(30, n / 12) else { return [Bool](repeating: false, count: n) }
        return b.mask
    }

    static func quantile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[Swift.min(s.count - 1, Swift.max(0, Int(Double(s.count - 1) * q)))]
    }

    /// Runs the whole reconstruction. `progress` gets (0…1, what is happening).
    public static func run(first: SceneMesh, second: SceneMesh?, options: ReconstructionOptions = ReconstructionOptions(),
                           progress: ((Double, String) -> Void)? = nil) -> Reconstruction {
        progress?(0.02, "Finding the pieces…")
        let s1 = SceneSplitter.split(positions: first.positions, triangles: first.triangles)
        let s2 = second.map { SceneSplitter.split(positions: $0.positions, triangles: $0.triangles) }
        var report = PiecesReport(target: options.target)
        let rec = Reconstruction(split1: s1, split2: s2, report: report)
        report.containerRemoved = s1.containerRemoved
        report.specks = s1.specks

        let firstPieces = Array(s1.pieces.prefix(options.maxMatched))
        let typical = firstPieces.map { $0.maxExtent }.sorted()
        let spacing = options.sampleSpacing ?? Swift.max(s1.resolution * 1.5, (typical.isEmpty ? 0.02 : quantile(typical, 0.5)) / 45, 0.0004)

        // Pieces from the first scan.
        var items: [Reconstruction.Item] = []
        for (k, c) in firstPieces.enumerated() {
            items.append(Reconstruction.Item(id: k + 1, first: c, second: nil, secondPose: nil,
                                             piece: pieceFrom(c, mesh: first, id: k + 1, spacing: spacing), merge: nil))
        }

        // Join each piece with its other side from the second scan.
        if let m2 = second, let s2 = s2, !s2.pieces.isEmpty {
            progress?(0.08, "Joining the two sides of each piece…")
            let others = s2.pieces.prefix(options.maxMatched + 4).enumerated().map { (k, c) in
                (k, c, pieceFrom(c, mesh: m2, id: 1000 + k, spacing: spacing))
            }
            var tried: [(Double, Int, Int, SideMerge)] = []
            for (ii, it) in items.enumerated() {
                for (k, c, p) in others {
                    let r = c.maxExtent / it.first.maxExtent
                    guard r > 0.55 && r < 1.8 else { continue }
                    let m = SideMerger.merge(it.piece, p, floorA: s1.floorY, floorB: s2.floorY)
                    if m.accepted { tried.append((m.overlap - 2 * m.conflict, ii, k, m)) }
                }
                progress?(0.08 + 0.17 * Double(ii + 1) / Double(items.count), "Joining the two sides of each piece…")
            }
            tried.sort { $0.0 > $1.0 }
            var usedA = Set<Int>(), usedB = Set<Int>()
            for (_, ii, k, m) in tried where !usedA.contains(ii) && !usedB.contains(k) {
                usedA.insert(ii)
                usedB.insert(k)
                let other = others[k]
                items[ii].second = other.1
                items[ii].secondPose = m.pose
                items[ii].merge = m
                items[ii].piece = SideMerger.combine(items[ii].piece, other.2, m, floorA: s1.floorY, floorB: s2.floorY, id: items[ii].id)
            }
        }

        // Break or original outside?
        progress?(0.27, "Telling break surfaces from the original outside…")
        let rough = items.map { $0.piece.roughness(radius: 3 * spacing) }
        let all = rough.flatMap { $0 }
        let lowQ = quantile(all, 0.3), highQ = quantile(all, 0.85)
        let radius: Double? = options.target.kind == .cylinder ? options.target.aMM.map { $0 / 2000 } : nil
        for (k, it) in items.enumerated() {
            let ext = radius.map { cylinderExterior(it.piece, radius: $0) }
            it.piece.classify(roughness: rough[k], lowQuantile: lowQ, highQuantile: highQ, exterior: ext)
            it.piece.buildFacets()
        }

        // Pairwise matching.
        let pieces = items.map { $0.piece }
        var pairs: [String: PairMatch] = [:]
        let total = Swift.max(1, pieces.count * (pieces.count - 1) / 2)
        var done = 0
        for i in 0..<pieces.count {
            for j in (i + 1)..<pieces.count {
                // Move the smaller piece onto the larger one.
                let (a, b) = pieces[i].volume <= pieces[j].volume ? (pieces[i], pieces[j]) : (pieces[j], pieces[i])
                let m = PieceMatcher.match(a, b, params: options.match)
                pairs[PieceAssembler.key(a.id, b.id)] = m
                done += 1
                progress?(0.3 + 0.5 * Double(done) / Double(total), "Matching break surfaces (\(done) of \(total) pairs)…")
            }
        }

        progress?(0.82, "Putting the pieces together…")
        let asm = pieces.count >= 2 ? PieceAssembler.assemble(pieces, pairs: pairs, params: options.assembly) : nil
        rec.assembly = asm

        // Missing regions in the main group.
        if let asm, let main = asm.clusters.first {
            progress?(0.9, "Looking for missing pieces…")
            let poses = asm.placed.filter { main.contains($0.key) }.mapValues { $0.pose }
            let members = pieces.filter { poses[$0.id] != nil }
            if let env = MissingFinder.envelope(members, poses: poses, target: options.target) {
                rec.envelope = env
                let r = MissingFinder.regions(members, poses: poses, envelope: env)
                rec.missing = r.regions
                rec.filledVolume = r.filledVolume
                rec.emptyVolume = r.emptyVolume
            }
        } else if pieces.count == 1, options.target.kind != .none {
            // One piece: what is missing from the target is everything it doesn't fill.
            let poses = [pieces[0].id: Pose.identity]
            if let env = MissingFinder.envelope(pieces, poses: poses, target: options.target) {
                rec.envelope = env
                let r = MissingFinder.regions(pieces, poses: poses, envelope: env)
                rec.missing = r.regions
                rec.filledVolume = r.filledVolume
                rec.emptyVolume = r.emptyVolume
            }
        }
        rec.items = items
        upright(rec)
        rec.report = buildReport(rec, base: report, options: options)
        progress?(1, "Done")
        return rec
    }

    /// Stands the result upright: the target's axis (or the longest direction) vertical, centred, base at height 0.
    static func upright(_ rec: Reconstruction) {
        guard var asm = rec.assembly, let main = asm.clusters.first else { return }
        let F = Dictionary(uniqueKeysWithValues: rec.items.map { ($0.id, $0.piece) })
        var pts: [SIMD3<Double>] = []
        for id in main {
            guard let W = asm.placed[id]?.pose, let p = F[id] else { continue }
            pts += stride(from: 0, to: p.points.count, by: 4).map { W.apply(p.points[$0]) }
        }
        guard pts.count > 10 else { return }
        let axis: SIMD3<Double>
        let centre: SIMD3<Double>
        if let env = rec.envelope {
            axis = env.axes[0]
            centre = env.center
        } else {
            let frame = ScanMath.principalFrame(pts.map { SIMD3<Float>($0) })
            axis = frame.axes[0]
            centre = frame.center
        }
        let R = Pose.align(simd_normalize(axis), to: SIMD3(0, 1, 0))
        var Q = Pose(R: R, t: -(R * centre))
        let minY = pts.map { Q.apply($0).y }.min() ?? 0
        Q.t.y -= minY
        for (k, v) in asm.placed {
            var p = v
            p.pose = Q.compose(v.pose)
            asm.placed[k] = p
        }
        rec.assembly = asm
        if var env = rec.envelope {
            env.center = Q.apply(env.center)
            env.axes = env.axes.map { R * $0 }
            rec.envelope = env
        }
        rec.missing = rec.missing.map { m in
            var n = m
            n.centroid = Q.apply(m.centroid)
            n.cells = m.cells.map { Q.apply($0) }
            return n
        }
    }

    static func label(_ id: Int) -> String { "P\(id)" }
    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    static func buildReport(_ rec: Reconstruction, base: PiecesReport, options: ReconstructionOptions) -> PiecesReport {
        var r = base
        let asm = rec.assembly
        var piecesVolume = 0.0
        for it in rec.items {
            let p = it.piece
            let frame = ScanMath.principalFrame(p.points.map { SIMD3<Float>($0) })
            let e = frame.extents
            let placed = asm?.placed[it.id]
            var status = "unplaced"
            var confidence = "none"
            var note = asm?.unplaced[it.id]
            if let pl = placed {
                status = pl.role
                if !pl.confirmedBy.isEmpty || pl.neighbours.count >= 2 { confidence = "high" }
                else if pl.gain >= 0.06 && pl.ambiguity < 0.6 { confidence = "medium" }
                else { confidence = "low" }
                note = pl.role == "anchor" ? "reference piece: the others are placed relative to it" : nil
            } else if rec.items.count < 2 {
                status = "not_matched"
                note = "only one piece"
            }
            piecesVolume += p.volume
            let size: [Double] = [e.x, e.y, e.z].map { round2($0 * 1000) }
            let join: Double? = it.merge.map { round3($0.overlap) }
            let touches: [String] = (placed?.neighbours ?? []).map { label($0) }
            let confirmed: [String] = (placed?.confirmedBy ?? []).map { label($0) }
            let via: String? = placed?.via.map { label($0) }
            let contactShare: Double? = placed.map { round3($0.gain) }
            let overlap: Double? = placed.map { round3($0.penetration) }
            let amb: Double? = placed.map { round2($0.ambiguity) }
            let entry = PiecesReport.PieceEntry(
                id: it.id, label: label(it.id), status: status, sides: it.second != nil ? "both" : "first_only",
                sideJoinOverlap: join, sizeMM: size, volumeCM3: round3(p.volume * 1e6), surfaceCM2: round2(p.surfaceArea * 1e4),
                asFoundCentreMM: mm(it.first.centroid), poseInAssembly: placed?.pose.matrix, cluster: placed?.cluster,
                placedVia: via, touches: touches, confirmedBy: confirmed, contactShare: contactShare,
                overlapShare: overlap, ambiguity: amb, confidence: confidence, note: note)
            r.pieces.append(entry)
        }
        var smallVolume = 0.0
        for (k, c) in rec.split1.small.enumerated() {
            let v = c.closedVolume ?? (c.hi - c.lo).x * (c.hi - c.lo).y * (c.hi - c.lo).z * 0.5
            smallVolume += v
            r.small.append(PiecesReport.SmallEntry(label: "S\(k + 1)", sizeMM: (c.maxExtent * 1000 * 100).rounded() / 100,
                                                   volumeCM3: c.closedVolume.map { ($0 * 1e6 * 10000).rounded() / 10000 },
                                                   asFoundCentreMM: mm(c.centroid)))
        }
        // Pieces of the first scan beyond the matched limit.
        if rec.split1.pieces.count > rec.items.count {
            for (k, c) in rec.split1.pieces.dropFirst(rec.items.count).enumerated() {
                r.small.append(PiecesReport.SmallEntry(label: "X\(k + 1)", sizeMM: (c.maxExtent * 1000 * 100).rounded() / 100,
                                                       volumeCM3: c.closedVolume.map { ($0 * 1e6 * 1000).rounded() / 1000 },
                                                       asFoundCentreMM: mm(c.centroid)))
            }
        }
        if let env = rec.envelope {
            r.envelope = PiecesReport.Envelope(
                kind: env.kind.rawValue, given: env.given,
                diameterMM: env.kind == .cylinder ? env.half.x * 2000 : nil,
                lengthMM: env.kind == .cylinder ? env.half.y * 2000 : nil,
                sidesMM: env.kind == .box ? [env.half.x * 2000, env.half.y * 2000, env.half.z * 2000] : nil,
                volumeCM3: env.volume * 1e6, centreMM: mm(env.center), axis: [env.axes[0].x, env.axes[0].y, env.axes[0].z], note: env.note)
        }
        var missingVolume = 0.0
        for (k, m) in rec.missing.enumerated() {
            let lab = (m.kind == "missing_piece" ? "M" : "G") + "\(k + 1)"
            if m.kind == "missing_piece" { missingVolume += m.volume }
            var where_ = ""
            if let a = m.axialShare {
                where_ = a > 0.67 ? "near the top" : (a < 0.33 ? "near the bottom" : "in the middle")
            }
            let between = m.neighbours.map(label)
            let size = [m.extents.x, m.extents.y, m.extents.z].map { $0 * 1000 }
            let desc: String
            if m.kind == "missing_piece" {
                desc = String(format: "Missing piece about %.1f × %.1f × %.1f mm (%.2f cm³)", size[0], size[1], size[2], m.volume * 1e6)
                    + (where_.isEmpty ? "" : " " + where_) + (between.isEmpty ? "" : ", next to " + between.joined(separator: ", "))
            } else {
                desc = String(format: "Narrow gap %.1f mm long between pieces (%@): a crack that doesn't close, or cut loss", size[0],
                              between.isEmpty ? "edge" : between.joined(separator: ", "))
            }
            r.missing.append(PiecesReport.MissingEntry(label: lab, kind: m.kind, volumeCM3: (m.volume * 1e6 * 1000).rounded() / 1000,
                                                       sizeMM: size.map { ($0 * 100).rounded() / 100 }, centreMM: mm(m.centroid),
                                                       heightShare: m.axialShare, angleDegrees: m.angleDegrees, between: between, description: desc))
        }
        let envelopeCM3: Double? = rec.envelope.map { $0.volume * 1e6 }
        var recovered: Double?
        if let env = rec.envelope { recovered = Swift.min(1, rec.filledVolume / Swift.max(env.volume, 1e-15)) }
        r.volumes = PiecesReport.Volumes(envelopeCM3: envelopeCM3, piecesCM3: piecesVolume * 1e6, smallFragmentsCM3: smallVolume * 1e6,
                                         missingCM3: rec.envelope != nil ? missingVolume * 1e6 : nil, recoveredShare: recovered)
        r.groups = (asm?.clusters ?? []).map { $0.map(label) }

        // What the user can do next.
        var g: [String] = []
        for it in rec.items where rec.split2 != nil && it.second == nil {
            g.append("\(label(it.id)): its other side wasn't found in the second scan. Turn it over and scan again, keeping the pieces a finger-width apart.")
        }
        if rec.split2 == nil && rec.items.count >= 2 {
            g.append("Only one side of each piece was scanned. Turn every piece over where it lies and scan again: break surfaces underneath can't be matched until they are seen.")
        }
        for e in r.pieces where e.status == "unplaced" {
            g.append("\(e.label) wasn't placed: \(e.note ?? "no confident match"). If you know where it goes, check its break surface is clean and facing up, and scan again.")
        }
        for e in r.pieces where e.confidence == "low" {
            g.append("\(e.label) is placed with low confidence: check the fit by eye before relying on it.")
        }
        for m in r.missing where m.kind == "missing_piece" {
            g.append("\(m.label): \(m.description). Look for it among the small fragments or the core box.")
        }
        if !r.small.isEmpty {
            g.append(String(format: "%d small fragments (under %.0f mm) were measured but not matched; together %.2f cm³.",
                            r.small.count, (rec.split1.pieces.last?.maxExtent ?? 0.006) * 1000, smallVolume * 1e6))
        }
        if rec.split1.containerRemoved { g.append("A dish rim was recognised and left out of the pieces.") }
        r.guidance = g
        r.limits = [
            "Pieces shorter than about 6 mm (or 12 mesh edges) are not matched; grains under about 1.5 mm are below what phone photogrammetry resolves and are only counted.",
            "Matching uses shape only. Flat saw cuts and the original outside are down-weighted so they are not mistaken for breaks; worn or very smooth breaks may not match.",
            "Pieces touching each other in the scan are seen as one piece: keep them apart.",
            "Missing regions are where the target shape is not filled by any placed piece. With no target given, the shape is fitted to the pieces and the missing estimate is weaker.",
            "Confidence: high = confirmed by a second neighbour or an independent pair match; medium = a clear single fit; low = check by eye.",
        ]
        return r
    }
}

extension SceneMesh {
    /// From a loaded model, with vertices at the same position welded (texture seams would otherwise split one
    /// piece into several).
    public static func welded(positions: [SIMD3<Float>], indices: [UInt32]) -> SceneMesh {
        let canon = ScanMath.canonicalIndices(positions: positions, indices: indices)
        var tris: [SIMD3<Int>] = []
        tris.reserveCapacity(canon.count / 3)
        var k = 0
        while k + 2 < canon.count {
            let a = Int(canon[k]), b = Int(canon[k + 1]), c = Int(canon[k + 2])
            if a != b && b != c && a != c { tris.append(SIMD3(a, b, c)) }
            k += 3
        }
        return SceneMesh(positions: positions.map { SIMD3<Double>($0) }, triangles: tris)
    }
}
