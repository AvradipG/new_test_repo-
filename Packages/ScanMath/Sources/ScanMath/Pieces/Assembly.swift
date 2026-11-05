import Foundation
import simd

/// Global assembly by beam search, as in the DRA Fragment Reconstruction Studio: starting from the largest piece,
/// a piece is added only when one of its pairwise poses, re-checked against everything already placed, explains
/// enough of its break surface without overlapping anything. Several partial assemblies stay alive so one
/// attractive but wrong pair does not decide the result; ambiguous single-contact placements are reported
/// instead of attached silently. Pieces that cannot be placed with enough evidence stay unplaced.
public struct AssemblyParams: Sendable {
    public var beam = 4
    public var acceptScore = 0.02
    public var minGain = 0.025
    public var maxPenetration = 0.04
    public var maxAmbiguity = 0.85
    public var expansionsPerState = 3
    public var refineRounds = 2
    public init() {}
}

public struct PlacedPiece: Sendable {
    public var id: Int
    /// Moves the piece from the scan frame into the assembly frame.
    public var pose: Pose
    public var cluster: Int
    /// "anchor", "placed"
    public var role: String
    public var via: Int?
    public var gain: Double
    public var penetration: Double
    public var ambiguity: Double
    public var neighbours: [Int]
    public var confirmedBy: [Int]
}

public struct AssemblyResult: Sendable {
    public var placed: [Int: PlacedPiece]
    public var unplaced: [Int: String]
    public var clusters: [[Int]]
    public var score: Double
}

public enum PieceAssembler {
    struct State {
        var poses: [Int: Pose]
        var score: Double
        var order: [Int]
        var info: [Int: (via: Int, gain: Double, pen: Double, amb: Double)]
    }

    final class Evaluator {
        let F: [Int: Piece]
        var cache: [String: (Double, Double)] = [:]
        init(_ F: [Int: Piece]) { self.F = F }

        func near(_ i: Int, _ Wi: Pose, _ j: Int, _ Wj: Pose) -> Bool {
            let a = F[i]!, b = F[j]!
            return simd_length(Wi.apply(a.centroid) - Wj.apply(b.centroid)) < a.radius + b.radius + 3 * Swift.max(a.spacing, b.spacing)
        }

        /// (break-weighted contact area, overlap) of i at relative pose T against j.
        func pair(_ i: Int, _ j: Int, _ T: Pose) -> (Double, Double) {
            let h = Swift.max(F[i]!.spacing, F[j]!.spacing)
            let key = "\(i)-\(j)-" + T.matrix.prefix(12).map { String(Int(($0 / (h * 0.1)).rounded())) }.joined(separator: ",")
            if let hit = cache[key] { return hit }
            let a = F[i]!, b = F[j]!
            let sig = PieceMatcher.sigma(a, b)
            let c1 = PieceMatcher.contact(a, T, b, sigma: sig), c2 = PieceMatcher.contact(b, T.inverse, a, sigma: sig)
            let pen = Swift.max(PieceMatcher.penetration(a, T, b, tol: 1.5 * h), PieceMatcher.penetration(b, T.inverse, a, tol: 1.5 * h))
            let out = ((c1.weighted + c2.weighted) / 2, pen)
            if cache.count > 50_000 { cache.removeAll() }
            cache[key] = out
            return out
        }

        func against(_ i: Int, _ Wi: Pose, _ placed: [Int: Pose]) -> (gain: Double, warea: Double, penMax: Double, penSum: Double, contacts: [Int]) {
            let A = F[i]!
            var sum = 0.0, penMax = 0.0, penSum = 0.0, big = 0.0
            var contacts: [Int] = []
            for (j, Wj) in placed where j != i && near(i, Wi, j, Wj) {
                let (w, pen) = pair(i, j, Wj.inverse.compose(Wi))
                penMax = Swift.max(penMax, pen)
                penSum += pen
                if w > 0.004 * A.surfaceArea {
                    contacts.append(j)
                    big = Swift.max(big, F[j]!.surfaceArea)
                }
                sum += w
            }
            let denom = big > 0 ? Swift.min(A.surfaceArea, big) : A.surfaceArea
            return (sum / denom, sum, penMax, penSum, contacts.sorted())
        }

        func refine(_ i: Int, _ Wi: Pose, _ placed: [Int: Pose], iterations: Int = 15) -> Pose {
            let A = F[i]!
            var P: [SIMD3<Double>] = [], N: [SIMD3<Double>] = []
            for (j, Wj) in placed where j != i && near(i, Wi, j, Wj) {
                let B = F[j]!
                P += B.points.map { Wj.apply($0) }
                N += B.normals.map { Wj.rotate($0) }
            }
            guard P.count >= 20 else { return Wi }
            let tree = KDTree(P)
            let h = A.spacing
            return PieceMatcher.contactICP(src: A.points, srcN: A.normals, srcW: A.fracture.map { $0 + 0.05 }, tree: tree, tgtN: N,
                                           start: Wi, h: h, iterations: iterations, dStart: 2.5, dEnd: 1.2, sigma: 0.3 * h)
        }

        func total(_ poses: [Int: Pose]) -> Double {
            let ids = poses.keys.sorted()
            var tot = 0.0
            for a in 0..<ids.count {
                for b in (a + 1)..<ids.count {
                    let i = ids[a], j = ids[b]
                    guard near(i, poses[i]!, j, poses[j]!) else { continue }
                    let (w, p) = pair(i, j, poses[j]!.inverse.compose(poses[i]!))
                    tot += w * exp(-p / 0.03)
                }
            }
            let area = F.values.reduce(0) { $0 + $1.surfaceArea }
            return 2 * tot / Swift.max(area, 1e-12)
        }
    }

    static func samePose(_ p: Piece, _ a: Pose, _ b: Pose) -> Bool {
        let probe = stride(from: 0, to: p.points.count, by: Swift.max(1, p.points.count / 100)).map { p.points[$0] }
        return Pose.displacement(a, b, points: probe) < 2.5 * p.spacing
    }

    /// Candidates moving i into j's frame.
    static func candidates(_ pairs: [String: PairMatch], _ i: Int, _ j: Int) -> [PairCandidate] {
        if let m = pairs["\(i)-\(j)"] { return m.candidates }
        if let m = pairs["\(j)-\(i)"] {
            return m.candidates.map { c in
                var d = c
                d.pose = c.pose.inverse
                return d
            }
        }
        return []
    }

    public static func key(_ a: Int, _ b: Int) -> String { "\(a)-\(b)" }

    public static func assemble(_ pieces: [Piece], pairs: [String: PairMatch], params: AssemblyParams = AssemblyParams()) -> AssemblyResult {
        let F = Dictionary(uniqueKeysWithValues: pieces.map { ($0.id, $0) })
        let ev = Evaluator(F)
        let ids = pieces.sorted { $0.volume > $1.volume }.map { $0.id }
        var remaining = ids
        var placedAll: [Int: PlacedPiece] = [:]
        var clusters: [[Int]] = []
        var ambiguous: [Int: Double] = [:]
        var clusterIndex = 0
        var offsetX = 0.0
        var totalScore = 0.0

        while remaining.count >= 2 {
            let pool = remaining
            guard let anchor = pool.first(where: { k in
                pool.contains { j in j != k && (candidates(pairs, k, j).first?.score ?? 0) >= params.acceptScore }
            }) else { break }
            var beam = [State(poses: [anchor: .identity], score: 0, order: [anchor], info: [:])]
            var finished: [State] = []
            var guardSteps = 0
            while !beam.isEmpty && guardSteps < pool.count + 2 {
                guardSteps += 1
                var expansions: [State] = []
                for st in beam {
                    var props: [(prio: Double, i: Int, W: Pose, via: Int, gain: Double, pen: Double, amb: Double)] = []
                    for i in pool where st.poses[i] == nil {
                        var hyps: [(Pose, Int)] = []
                        for (j, Wj) in st.poses {
                            for c in candidates(pairs, i, j) where c.score >= params.acceptScore {
                                let Wi = Wj.compose(c.pose)
                                if hyps.contains(where: { samePose(F[i]!, $0.0, Wi) }) { continue }
                                hyps.append((Wi, j))
                            }
                        }
                        var scored: [(Double, Pose, Int, Double, Double, Int)] = []
                        for (Wi0, j) in hyps {
                            var Wi = Wi0
                            var e = ev.against(i, Wi, st.poses)
                            if e.penMax > 3 * params.maxPenetration || e.gain < 0.4 * params.minGain { continue }
                            let Wr = ev.refine(i, Wi, st.poses)
                            let e2 = ev.against(i, Wr, st.poses)
                            if e2.gain * exp(-e2.penSum / 0.03) >= e.gain * exp(-e.penSum / 0.03) {
                                Wi = Wr
                                e = e2
                            }
                            scored.append((e.gain * exp(-e.penSum / 0.03), Wi, j, e.gain, e.penMax, e.contacts.count))
                        }
                        scored.sort { $0.0 > $1.0 }
                        var distinct: [(Double, Pose, Int, Double, Double, Int)] = []
                        for s in scored where !distinct.contains(where: { samePose(F[i]!, $0.1, s.1) }) { distinct.append(s) }
                        guard let top = distinct.first else { continue }
                        let r0 = distinct.count > 1 && top.0 > 0 ? distinct[1].0 / top.0 : 0
                        if r0 > params.maxAmbiguity && top.5 < 2 {
                            ambiguous[i] = Swift.max(ambiguous[i] ?? 0, r0)
                            continue
                        }
                        for (rank, s) in distinct.prefix(2).enumerated() {
                            guard s.3 >= params.minGain, s.4 <= params.maxPenetration else { continue }
                            let runner = rank == 0 ? (distinct.count > 1 ? distinct[1].0 : 0) : distinct[0].0
                            let amb = s.0 > 0 ? runner / s.0 : 1
                            props.append((s.0 * (1 - 0.7 * Swift.min(1, amb)), i, s.1, s.2, s.3, s.4, amb))
                        }
                    }
                    props.sort { $0.prio > $1.prio }
                    if props.isEmpty {
                        finished.append(st)
                        continue
                    }
                    for p in props.prefix(params.expansionsPerState) {
                        var poses = st.poses
                        poses[p.i] = p.W
                        var info = st.info
                        info[p.i] = (p.via, p.gain, p.pen, p.amb)
                        expansions.append(State(poses: poses, score: st.score + p.prio, order: st.order + [p.i], info: info))
                    }
                }
                expansions.sort { $0.score > $1.score }
                var next: [State] = []
                for s in expansions {
                    let dup = next.contains { t in
                        Set(t.poses.keys) == Set(s.poses.keys) && t.poses.allSatisfy { k, W in samePose(F[k]!, W, s.poses[k]!) }
                    }
                    if !dup { next.append(s) }
                    if next.count >= params.beam { break }
                }
                beam = next
            }
            finished += beam
            guard var best = finished.max(by: { ev.total($0.poses) < ev.total($1.poses) }) else { break }

            // Joint refinement: each piece against all its neighbours.
            for _ in 0..<params.refineRounds {
                for k in best.order where k != anchor {
                    let others = best.poses.filter { $0.key != k }
                    let e0 = ev.against(k, best.poses[k]!, others)
                    let Wn = ev.refine(k, best.poses[k]!, others, iterations: 10)
                    let e1 = ev.against(k, Wn, others)
                    if e1.warea * exp(-e1.penSum / 0.03) > e0.warea * exp(-e0.penSum / 0.03) { best.poses[k] = Wn }
                }
            }
            guard best.poses.count >= 2 else { break }

            // Clusters after the first are laid out to the side of the previous ones.
            var shift = SIMD3<Double>.zero
            if clusterIndex > 0 {
                let xs = best.poses.flatMap { k, W in F[k]!.points.map { W.apply($0).x } }
                shift.x = offsetX - (xs.min() ?? 0)
            }
            for (k, W) in best.poses {
                let others = best.poses.filter { $0.key != k }
                let e = ev.against(k, W, others)
                var confirmed: [Int] = []
                let via = best.info[k]?.via
                for (j, Wj) in others where j != via && best.info[j]?.via != k {
                    let rel = Wj.inverse.compose(W)
                    if candidates(pairs, k, j).contains(where: { $0.score >= params.acceptScore && samePose(F[k]!, $0.pose, rel) }) {
                        confirmed.append(j)
                    }
                }
                let placedPose = Pose(R: W.R, t: W.t + shift)
                placedAll[k] = PlacedPiece(id: k, pose: placedPose, cluster: clusterIndex, role: k == anchor ? "anchor" : "placed",
                                           via: via, gain: e.gain, penetration: e.penMax, ambiguity: best.info[k]?.amb ?? 0,
                                           neighbours: e.contacts, confirmedBy: confirmed.sorted())
            }
            let xsAfter = best.poses.flatMap { k, W in F[k]!.points.map { W.apply($0).x + shift.x } }
            let width = (xsAfter.max() ?? 0) - (xsAfter.min() ?? 0)
            offsetX = (xsAfter.max() ?? 0) + 0.15 * width
            totalScore += ev.total(best.poses)
            clusters.append(best.order)
            remaining = remaining.filter { best.poses[$0] == nil }
            clusterIndex += 1
        }

        var unplaced: [Int: String] = [:]
        for k in ids where placedAll[k] == nil {
            let bestScore = ids.filter { $0 != k }.map { candidates(pairs, k, $0).first?.score ?? 0 }.max() ?? 0
            if let amb = ambiguous[k] {
                unplaced[k] = String(format: "ambiguous: two different placements score within %.0f%% of each other and it touches only one piece; check it by eye", (1 - amb) * 100)
            } else if bestScore < params.acceptScore {
                unplaced[k] = String(format: "no matching break found (best pair score %.3f): its partner may be missing, or the break is worn or too smooth", bestScore)
            } else {
                unplaced[k] = String(format: "pair matches exist (best %.3f) but none fits with the pieces already placed", bestScore)
            }
        }
        return AssemblyResult(placed: placedAll, unplaced: unplaced, clusters: clusters, score: totalScore)
    }
}
