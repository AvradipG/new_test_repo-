import XCTest
import simd
@testable import ScanMath

/// Smoke tests of the broken-piece reconstruction on synthetic cores with known answers.
final class PiecesTests: XCTestCase {
    let R = 0.0125   // 25 mm core
    let h = 0.0011   // sample spacing

    /// Wavy, non-symmetric break surface height at (x, z).
    func breakHeight(_ base: Double, _ x: Double, _ z: Double, phase: Double) -> Double {
        let a: Double = sin(x * 260 + phase) * cos(z * 190 - phase)
        let u: Double = (x + 0.6 * z) * 420 + 2 * phase
        let b: Double = sin(u)
        return base + 0.0028 * a + 0.0016 * b
    }
    func breakNormal(_ base: Double, _ x: Double, _ z: Double, phase: Double) -> SIMD3<Double> {
        let e = 1e-6
        let fx = (breakHeight(base, x + e, z, phase: phase) - breakHeight(base, x - e, z, phase: phase)) / (2 * e)
        let fz = (breakHeight(base, x, z + e, phase: phase) - breakHeight(base, x, z - e, phase: phase)) / (2 * e)
        return simd_normalize(SIMD3(-fx, 1, -fz))
    }

    /// Samples of the slab of a core between two break surfaces (nil = flat original end at y0 / y1).
    func slab(y0: Double, y1: Double, lowerBreak: Double?, upperBreak: Double?, phaseLow: Double = 0.3, phaseHigh: Double = 1.7)
        -> (points: [SIMD3<Double>], normals: [SIMD3<Double>]) {
        var P: [SIMD3<Double>] = [], N: [SIMD3<Double>] = []
        func low(_ x: Double, _ z: Double) -> Double { lowerBreak.map { breakHeight($0, x, z, phase: phaseLow) } ?? y0 }
        func high(_ x: Double, _ z: Double) -> Double { upperBreak.map { breakHeight($0, x, z, phase: phaseHigh) } ?? y1 }
        let steps = Int(2 * .pi * R / h)
        for k in 0..<steps {
            let th = Double(k) / Double(steps) * 2 * .pi
            let x = R * cos(th), z = R * sin(th)
            var y = y0 - 0.004
            while y < y1 + 0.004 {
                if y > low(x, z) && y < high(x, z) {
                    P.append(SIMD3(x, y, z))
                    N.append(SIMD3(cos(th), 0, sin(th)))
                }
                y += h
            }
        }
        var x = -R
        while x <= R {
            var z = -R
            while z <= R {
                if x * x + z * z < R * R {
                    if let b = lowerBreak {
                        P.append(SIMD3(x, breakHeight(b, x, z, phase: phaseLow), z))
                        N.append(-breakNormal(b, x, z, phase: phaseLow))
                    } else {
                        P.append(SIMD3(x, y0, z))
                        N.append(SIMD3(0, -1, 0))
                    }
                    if let b = upperBreak {
                        P.append(SIMD3(x, breakHeight(b, x, z, phase: phaseHigh), z))
                        N.append(breakNormal(b, x, z, phase: phaseHigh))
                    } else {
                        P.append(SIMD3(x, y1, z))
                        N.append(SIMD3(0, 1, 0))
                    }
                }
                z += h
            }
            x += h
        }
        return (P, N)
    }

    func moved(_ s: (points: [SIMD3<Double>], normals: [SIMD3<Double>]), by G: Pose) -> (points: [SIMD3<Double>], normals: [SIMD3<Double>]) {
        (s.points.map { G.apply($0) }, s.normals.map { G.rotate($0) })
    }

    /// Classifies like the pipeline does, with a known core diameter.
    func prepare(_ pieces: [Piece], radius: Double?) {
        let rough = pieces.map { $0.roughness(radius: 3 * h) }
        let all = rough.flatMap { $0 }
        let lo = PieceReconstructor.quantile(all, 0.3), hi = PieceReconstructor.quantile(all, 0.85)
        for (k, p) in pieces.enumerated() {
            let ext = radius.map { PieceReconstructor.cylinderExterior(p, radius: $0) }
            p.classify(roughness: rough[k], lowQuantile: lo, highQuantile: hi, exterior: ext)
            p.buildFacets()
        }
    }

    func testPoseAlgebra() {
        let G = Pose(R: Pose.rotation(axis: SIMD3(0.3, 1, -0.2), degrees: 73), t: SIMD3(0.1, -0.02, 0.05))
        let p = SIMD3(0.01, 0.02, -0.03)
        XCTAssertLessThan(simd_length(G.inverse.apply(G.apply(p)) - p), 1e-12)
        let M = Pose(matrix: G.matrix)
        XCTAssertLessThan(simd_length(M.apply(p) - G.apply(p)), 1e-12)
        XCTAssertEqual(G.angleDegrees, 73, accuracy: 1e-6)
        let a = simd_normalize(SIMD3(0.2, -0.5, 0.8)), b = simd_normalize(SIMD3(-0.7, 0.1, 0.3))
        XCTAssertLessThan(simd_length(Pose.align(a, to: b) * a - b), 1e-9)
        XCTAssertLessThan(simd_length(Pose.align(a, to: -a) * a + a), 1e-9)
    }

    func testKDTreeAgreesWithBruteForce() {
        var rng = SplitMix64(seed: 3)
        let pts = (0..<500).map { _ in SIMD3(rng.unit(), rng.unit(), rng.unit()) }
        let tree = KDTree(pts)
        for _ in 0..<50 {
            let q = SIMD3(rng.unit(), rng.unit(), rng.unit())
            let brute = pts.indices.min { simd_length(pts[$0] - q) < simd_length(pts[$1] - q) }!
            XCTAssertEqual(tree.nearest(q)!.index, brute)
            let r = 0.15
            XCTAssertEqual(Set(tree.within(q, radius: r)), Set(pts.indices.filter { simd_length(pts[$0] - q) <= r }))
        }
    }

    func testCylinderOutsideIsNotTakenForABreak() {
        let s = slab(y0: 0, y1: 0.05, lowerBreak: nil, upperBreak: 0.025)
        let p = Piece(id: 1, points: s.points, normals: s.normals, spacing: h)
        prepare([p], radius: R)
        let side = p.points.indices.filter { abs(p.normals[$0].y) < 0.1 && p.points[$0].y < 0.018 }
        let breakPts = p.points.indices.filter { p.points[$0].y > 0.021 && p.normals[$0].y > 0.5 }
        let sideMean = side.map { p.fracture[$0] }.reduce(0, +) / Double(side.count)
        let breakMean = breakPts.map { p.fracture[$0] }.reduce(0, +) / Double(breakPts.count)
        XCTAssertLessThan(sideMean, 0.2)
        XCTAssertGreaterThan(breakMean, 0.4)
        XCTAssertFalse(p.facets.isEmpty)
        XCTAssertGreaterThan(p.volume, 0.6 * .pi * R * R * 0.025)
    }

    func testTwoPiecesMatch() {
        let a = slab(y0: 0, y1: 0.05, lowerBreak: nil, upperBreak: 0.024)
        let b = slab(y0: 0, y1: 0.05, lowerBreak: 0.024, upperBreak: nil, phaseLow: 1.7)
        let G = Pose(R: Pose.rotation(axis: SIMD3(1, 0.4, -0.3), degrees: 117), t: SIMD3(0.07, 0.01, -0.04))
        let bm = moved(b, by: G)
        let A = Piece(id: 1, points: a.points, normals: a.normals, spacing: h)
        let B = Piece(id: 2, points: bm.points, normals: bm.normals, spacing: h)
        prepare([A, B], radius: R)
        var params = MatchParams()
        params.facetPairs = 24
        let m = PieceMatcher.match(A, B, params: params)
        let best = try! XCTUnwrap(m.best)
        // True pose of A into B's (moved) frame is G.
        let err = Pose.displacement(best.pose, G, points: A.points)
        XCTAssertLessThan(err, 0.0015, "pose error \(err * 1000) mm, score \(best.score)")
        XCTAssertGreaterThan(best.score, 0.05)
        XCTAssertLessThan(best.penetration, 0.03)
    }

    func testThreePiecesAssemble() {
        let a = slab(y0: 0, y1: 0.06, lowerBreak: nil, upperBreak: 0.02, phaseHigh: 0.3)
        let b = slab(y0: 0, y1: 0.06, lowerBreak: 0.02, upperBreak: 0.041, phaseLow: 0.3, phaseHigh: 2.2)
        let c = slab(y0: 0, y1: 0.06, lowerBreak: 0.041, upperBreak: nil, phaseLow: 2.2)
        let G: [Pose] = [
            .identity,
            Pose(R: Pose.rotation(axis: SIMD3(0, 1, 1), degrees: 140), t: SIMD3(0.06, 0, 0)),
            Pose(R: Pose.rotation(axis: SIMD3(1, -1, 0.2), degrees: 65), t: SIMD3(-0.05, 0.01, 0.07)),
        ]
        let parts = [a, b, c].enumerated().map { k, s -> Piece in
            let m = moved(s, by: G[k])
            return Piece(id: k + 1, points: m.points, normals: m.normals, spacing: h)
        }
        prepare(parts, radius: R)
        var params = MatchParams()
        params.facetPairs = 24
        var pairs: [String: PairMatch] = [:]
        for i in 0..<3 { for j in (i + 1)..<3 {
            pairs[PieceAssembler.key(parts[i].id, parts[j].id)] = PieceMatcher.match(parts[i], parts[j], params: params)
        } }
        let result = PieceAssembler.assemble(parts, pairs: pairs)
        XCTAssertEqual(result.placed.count, 3, "unplaced: \(result.unplaced)")
        // Every piece back in its original place relative to the others.
        let originals = [a.points, b.points, c.points]
        for i in 0..<3 {
            for j in 0..<3 where i != j {
                guard let Wi = result.placed[i + 1]?.pose, let Wj = result.placed[j + 1]?.pose else { continue }
                let err = Pose.displacement(Wi.compose(G[i]), Wj.compose(G[j]), points: originals[i])
                XCTAssertLessThan(err, 0.002, "pieces \(i + 1)-\(j + 1): \(err * 1000) mm")
            }
        }
    }

    func testMissingPartOfTheCoreIsFound() {
        // Only the bottom 20 mm of a 25 × 50 mm core: 30 mm is missing.
        let a = slab(y0: 0, y1: 0.05, lowerBreak: nil, upperBreak: 0.02)
        let A = Piece(id: 1, points: a.points, normals: a.normals, spacing: h)
        prepare([A], radius: R)
        let target = TargetShape(kind: .cylinder, aMM: 25, bMM: 50)
        let env = try! XCTUnwrap(MissingFinder.envelope([A], poses: [1: .identity], target: target))
        XCTAssertEqual(env.half.x, R, accuracy: 1e-9)
        XCTAssertEqual(env.half.y, 0.025, accuracy: 1e-9)
        XCTAssertTrue(env.note.contains("bottom"), env.note)
        let r = MissingFinder.regions([A], poses: [1: .identity], envelope: env)
        let missing = r.regions.filter { $0.kind == "missing_piece" }
        XCTAssertEqual(missing.count, 1)
        let expected = Double.pi * R * R * 0.03
        XCTAssertEqual(missing[0].volume, expected, accuracy: 0.15 * expected)
        XCTAssertGreaterThan(missing[0].axialShare ?? 0, 0.55)
    }

    /// A bumpy, non-symmetric rock with outward normals.
    func rock() -> (points: [SIMD3<Double>], normals: [SIMD3<Double>]) {
        func surf(_ th: Double, _ ph: Double) -> SIMD3<Double> {
            let t1: Double = 0.18 * sin(3 * th + 0.5) * cos(2 * ph)
            let t2: Double = 0.12 * sin(5 * ph + 1)
            let t3: Double = 0.08 * cos(th - 2 * ph)
            let r: Double = 0.012 * (1 + t1 + t2 + t3)
            let sp: Double = sin(ph)
            let x: Double = r * 1.3 * sp * cos(th)
            let y: Double = r * 0.8 * cos(ph)
            let z: Double = r * sp * sin(th)
            return SIMD3(x, y, z)
        }
        var P: [SIMD3<Double>] = [], N: [SIMD3<Double>] = []
        let nph = 70
        for i in 1..<nph {
            let ph = Double(i) / Double(nph) * .pi
            let nth = Swift.max(8, Int(140 * sin(ph)))
            for j in 0..<nth {
                let th = Double(j) / Double(nth) * 2 * .pi
                let p = surf(th, ph)
                let e = 1e-5
                let dth = surf(th + e, ph) - surf(th - e, ph), dph = surf(th, ph + e) - surf(th, ph - e)
                var n = simd_normalize(simd_cross(dph, dth))
                if simd_dot(n, p) < 0 { n = -n }
                P.append(p)
                N.append(n)
            }
        }
        return (P, N)
    }

    func testTwoSidesOfAPieceJoin() {
        let r = rock()
        // First scan: lying as made, seen above 30 % of its height; the table at its lowest point.
        let T1 = Pose(R: matrix_identity_double3x3, t: SIMD3(0.02, 0, -0.01))
        let T2r = Pose.rotation(axis: SIMD3(0, 1, 0), degrees: 50) * Pose.rotation(axis: SIMD3(1, 0, 0.3), degrees: 175)
        var T2 = Pose(R: T2r, t: .zero)
        func place(_ T: Pose) -> (Pose, [SIMD3<Double>], [SIMD3<Double>], Double) {
            let pts = r.points.map { T.apply($0) }
            let minY = pts.map { $0.y }.min()!, maxY = pts.map { $0.y }.max()!
            let T0 = Pose(R: T.R, t: T.t - SIMD3(0, minY, 0))
            let cut = 0.3 * (maxY - minY)
            var P: [SIMD3<Double>] = [], N: [SIMD3<Double>] = []
            for i in r.points.indices {
                let p = T0.apply(r.points[i])
                if p.y > cut { P.append(p); N.append(T0.rotate(r.normals[i])) }
            }
            return (T0, P, N, 0)
        }
        let (A0, ap, an, floorA) = place(T1)
        T2.t = SIMD3(-0.03, 0, 0.05)
        let (B0, bp, bn, _) = place(T2)
        let A = Piece(id: 1, points: ap, normals: an, spacing: 0.0008)
        let B = Piece(id: 2, points: bp, normals: bn, spacing: 0.0008)
        let m = SideMerger.merge(A, B, floorA: floorA)
        XCTAssertTrue(m.accepted, "overlap \(m.overlap) conflict \(m.conflict)")
        let truth = A0.compose(B0.inverse)
        let err = Pose.displacement(m.pose, truth, points: bp)
        XCTAssertLessThan(err, 0.0015, "join error \(err * 1000) mm")
        let both = SideMerger.combine(A, B, m, floorA: floorA, floorB: 0, id: 1)
        XCTAssertGreaterThan(both.points.count, A.points.count)
    }

    /// Grid mesh helpers for the splitter.
    func box(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>, into P: inout [SIMD3<Double>], _ T: inout [SIMD3<Int>]) {
        let base = P.count
        for k in 0..<8 {
            P.append(SIMD3(k & 1 == 0 ? lo.x : hi.x, k & 2 == 0 ? lo.y : hi.y, k & 4 == 0 ? lo.z : hi.z))
        }
        let faces = [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
        for (a, b, c, d) in faces {
            T.append(SIMD3(base + a, base + b, base + c))
            T.append(SIMD3(base + a, base + c, base + d))
        }
    }

    func testSceneSplitFindsPiecesOnATable() {
        var P: [SIMD3<Double>] = [], T: [SIMD3<Int>] = []
        let n = 60, size = 0.12
        for i in 0...n { for k in 0...n { P.append(SIMD3(Double(i) / Double(n) * size - 0.06, 0, Double(k) / Double(n) * size - 0.06)) } }
        for i in 0..<n { for k in 0..<n {
            let a = i * (n + 1) + k
            T.append(SIMD3(a, a + 1, a + n + 2))
            T.append(SIMD3(a, a + n + 2, a + n + 1))
        } }
        box(SIMD3(-0.04, 0, -0.03), SIMD3(-0.02, 0.015, -0.01), into: &P, &T)
        box(SIMD3(0.01, 0, 0.01), SIMD3(0.025, 0.02, 0.04), into: &P, &T)
        box(SIMD3(0.04, 0, -0.04), SIMD3(0.043, 0.002, -0.037), into: &P, &T)   // 3 mm grain
        box(SIMD3(-0.05, 0, 0.05), SIMD3(-0.0495, 0.0005, 0.0505), into: &P, &T) // speck
        let s = SceneSplitter.split(positions: P, triangles: T, matchSize: 0.006, minSize: 0.0015)
        XCTAssertEqual(s.pieces.count, 2)
        XCTAssertEqual(s.small.count, 1)
        XCTAssertEqual(s.specks, 1)
        XCTAssertEqual(s.floorY, 0, accuracy: 0.002)
    }

    func testReportNamesTheMissingPiece() {
        // End to end on point pieces: three pieces, the middle one lost.
        let a = slab(y0: 0, y1: 0.06, lowerBreak: nil, upperBreak: 0.02, phaseHigh: 0.3)
        let c = slab(y0: 0, y1: 0.06, lowerBreak: 0.041, upperBreak: nil, phaseLow: 2.2)
        let A = Piece(id: 1, points: a.points, normals: a.normals, spacing: h)
        let C = Piece(id: 2, points: c.points, normals: c.normals, spacing: h)
        prepare([A, C], radius: R)
        // Placed where they belong (as if a user locked them on the core axis).
        let env = try! XCTUnwrap(MissingFinder.envelope([A, C], poses: [1: .identity, 2: .identity], target: TargetShape(kind: .cylinder, aMM: 25, bMM: 60)))
        let r = MissingFinder.regions([A, C], poses: [1: .identity, 2: .identity], envelope: env)
        let missing = r.regions.filter { $0.kind == "missing_piece" }
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(Set(missing[0].neighbours), [1, 2])
        XCTAssertEqual(missing[0].axialShare ?? 0, 0.5, accuracy: 0.12)
    }
}
