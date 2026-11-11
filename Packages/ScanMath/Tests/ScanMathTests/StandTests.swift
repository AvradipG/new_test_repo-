import XCTest
import simd
@testable import ScanMath

/// 3.14: a small rock scanned on a wooden block; the block is found on the unrolled side and cut off the model.
final class StandTests: XCTestCase {
    /// Closed box mesh, outward faces counter-clockwise, split into a fine grid so cuts cross many triangles.
    func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, n: Int = 6) -> ([SIMD3<Float>], [UInt32]) {
        var P: [SIMD3<Float>] = [], T: [UInt32] = []
        // Each face as an n×n grid: origin o, edge vectors u and v with u × v pointing out.
        let d = hi - lo
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (lo, SIMD3(0, d.y, 0), SIMD3(d.x, 0, 0)),                    // z = lo (normal −z)
            (SIMD3(lo.x, lo.y, hi.z), SIMD3(d.x, 0, 0), SIMD3(0, d.y, 0)), // z = hi (+z)
            (lo, SIMD3(0, 0, d.z), SIMD3(0, d.y, 0)),                    // x = lo (−x)
            (SIMD3(hi.x, lo.y, lo.z), SIMD3(0, d.y, 0), SIMD3(0, 0, d.z)), // x = hi (+x)
            (lo, SIMD3(d.x, 0, 0), SIMD3(0, 0, d.z)),                    // y = lo (−y)
            (SIMD3(lo.x, hi.y, lo.z), SIMD3(0, 0, d.z), SIMD3(d.x, 0, 0)), // y = hi (+y)
        ]
        var index: [SIMD3<Int32>: UInt32] = [:]
        func vertex(_ p: SIMD3<Float>) -> UInt32 {
            let key = SIMD3<Int32>(Int32((p.x * 1e5).rounded()), Int32((p.y * 1e5).rounded()), Int32((p.z * 1e5).rounded()))
            if let i = index[key] { return i }
            let i = UInt32(P.count)
            P.append(p)
            index[key] = i
            return i
        }
        for (o, u, v) in faces {
            for i in 0..<n { for j in 0..<n {
                let a = vertex(o + u * Float(i) / Float(n) + v * Float(j) / Float(n))
                let b = vertex(o + u * Float(i + 1) / Float(n) + v * Float(j) / Float(n))
                let c = vertex(o + u * Float(i + 1) / Float(n) + v * Float(j + 1) / Float(n))
                let e = vertex(o + u * Float(i) / Float(n) + v * Float(j + 1) / Float(n))
                T += [a, b, c, a, c, e]
            } }
        }
        return (P, T)
    }

    func volume(_ P: [SIMD3<Float>], _ T: [UInt32]) -> Double {
        var v = 0.0
        var k = 0
        while k + 2 < T.count {
            let a = SIMD3<Double>(P[Int(T[k])]), b = SIMD3<Double>(P[Int(T[k + 1])]), c = SIMD3<Double>(P[Int(T[k + 2])])
            v += simd_dot(a, simd_cross(b, c)) / 6
            k += 3
        }
        return v
    }

    /// Every directed edge once and its reverse once: closed and consistently wound.
    func isClosed(_ T: [UInt32]) -> Bool {
        var count: [UInt64: Int] = [:]
        var k = 0
        while k + 2 < T.count {
            let t = [T[k], T[k + 1], T[k + 2]]
            for i in 0..<3 { count[(UInt64(t[i]) << 32) | UInt64(t[(i + 1) % 3]), default: 0] += 1 }
            k += 3
        }
        for (key, c) in count {
            let a = key >> 32, b = key & 0xFFFF_FFFF
            if c != 1 || count[(b << 32) | a] != 1 { return false }
        }
        return true
    }

    func testBoxCutIsClosedWithTheRightVolume() {
        let (P, T) = box(SIMD3(-0.01, 0, -0.005), SIMD3(0.01, 0.03, 0.005))
        XCTAssertEqual(volume(P, T), 0.02 * 0.03 * 0.01, accuracy: 1e-12)
        let cut = MeshCut.above(positions: P, indices: T, y: 0.0123)
        XCTAssertTrue(isClosed(cut.indices))
        XCTAssertEqual(volume(cut.positions, cut.indices), 0.02 * (0.03 - 0.0123) * 0.01, accuracy: 1e-11)
        XCTAssertEqual(Double(cut.positions.map { $0.y }.min()!), 0.0123, accuracy: 1e-7)
        // A cut on a grid line (vertices exactly on the plane) is closed too.
        let onGrid = MeshCut.above(positions: P, indices: T, y: 0.015)
        XCTAssertTrue(isClosed(onGrid.indices))
        XCTAssertEqual(volume(onGrid.positions, onGrid.indices), 0.02 * 0.015 * 0.01, accuracy: 1e-11)
        // Below everything: nothing changes.
        let all = MeshCut.above(positions: P, indices: T, y: -1)
        XCTAssertEqual(all.indices.count, T.count)
    }

    func testTiltedRockOnABlockIsCutAtTheJoin() {
        // A tilted box (the rock) on a wider block (the stand), as one mesh; cut where the rock begins.
        let (rp, rt) = box(SIMD3(-0.005, 0.02, -0.004), SIMD3(0.005, 0.04, 0.004))
        let R = Pose.rotation(axis: SIMD3(0, 0, 1), degrees: 12)
        let tilted = rp.map { p -> SIMD3<Float> in
            let q = R * SIMD3<Double>(Double(p.x), Double(p.y) - 0.03, Double(p.z))
            return SIMD3<Float>(Float(q.x), Float(q.y + 0.03), Float(q.z))
        }
        let full = volume(tilted, rt)
        let up = MeshCut.above(positions: tilted, indices: rt, y: 0.025)
        // The same cut from below (mirror y, flip winding) holds the rest: the two add up.
        let mirrored = tilted.map { SIMD3<Float>($0.x, -$0.y, $0.z) }
        var flipped: [UInt32] = []
        var k = 0
        while k + 2 < rt.count { flipped += [rt[k], rt[k + 2], rt[k + 1]]; k += 3 }
        let down = MeshCut.above(positions: mirrored, indices: flipped, y: -0.025)
        XCTAssertTrue(isClosed(up.indices))
        XCTAssertTrue(isClosed(down.indices))
        XCTAssertEqual(volume(up.positions, up.indices) + volume(down.positions, down.indices), full, accuracy: full * 1e-6)
    }

    /// Rows of an unrolled side: a dark greenish rock above a light, grained wooden stand.
    func rows(rock: Int, stand: Int, seed: UInt64 = 5) -> [SIMD3<Double>?] {
        var rng = SplitMix64(seed: seed)
        var out: [SIMD3<Double>?] = []
        for _ in 0..<rock {
            let n = (rng.unit() - 0.5) * 0.12
            out.append(SIMD3(0.30 + n, 0.36 + n, 0.31 + n)) // dark grey-green conglomerate, mottled
        }
        for i in 0..<stand {
            let grain = (i % 5 < 2) ? -0.06 : 0.03 // darker grain lines
            out.append(SIMD3(0.86 + grain, 0.74 + grain, 0.56 + grain)) // pale pine
        }
        return out
    }

    func testWoodenStandUnderADarkRockIsFound() {
        let r = try! XCTUnwrap(StandFinder.find(rows: rows(rock: 120, stand: 70)))
        XCTAssertEqual(r.boundaryRow, 120, accuracy: 1)
        XCTAssertGreaterThan(r.standLuma, r.rockLuma)
        XCTAssertEqual(r.standShare, 70.0 / 190.0, accuracy: 0.01)
    }

    func testNoStandIsFoundOnAPlainRock() {
        XCTAssertNil(StandFinder.find(rows: rows(rock: 190, stand: 0)))
        // A rock that only shades gradually from dark to light has no stand either.
        let shaded: [SIMD3<Double>?] = (0..<190).map { i in
            let t = Double(i) / 189 * 0.3
            return SIMD3(0.3 + t, 0.33 + t, 0.3 + t)
        }
        XCTAssertNil(StandFinder.find(rows: shaded))
        // Nor does a thin band at the very bottom (a shadow or a scrap of table).
        XCTAssertNil(StandFinder.find(rows: rows(rock: 184, stand: 6)))
    }
}
