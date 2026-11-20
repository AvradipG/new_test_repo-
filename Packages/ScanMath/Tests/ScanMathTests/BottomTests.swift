import XCTest
import simd
@testable import ScanMath

/// 3.20: the end a core stood on is never seen; a hollow guess there (a "cup") is filled flat at the table.
final class BottomTests: XCTestCase {
    /// A core of radius R and length L standing on y = 0. Its bottom is closed like photogrammetry closes an unseen
    /// face: the side comes down to the table, then the end turns inward and up to a flat disc `recess` above it.
    static func cupCore(R: Double, L: Double, recess: Double, n: Int = 72, rows: Int = 30)
        -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        var P: [SIMD3<Double>] = []
        var T: [UInt32] = []
        func ring(_ r: Double, _ y: Double) -> UInt32 {
            let start = UInt32(P.count)
            for k in 0..<n {
                let th = 2 * Double.pi * Double(k) / Double(n)
                P.append(SIMD3(r * sin(th), y, r * cos(th)))
            }
            return start
        }
        func band(_ a: UInt32, _ b: UInt32) {
            // Outward faces between ring a (lower) and ring b (upper) when going round counter-clockwise from above.
            for k in 0..<n {
                let k1 = UInt32((k + 1) % n), k0 = UInt32(k)
                T += [a + k0, a + k1, b + k1, a + k0, b + k1, b + k0]
            }
        }
        var rings: [UInt32] = []
        for j in 0...rows { rings.append(ring(R, L * Double(j) / Double(rows))) }
        for j in 0..<rows { band(rings[j], rings[j + 1]) }
        // Top: flat disc at L.
        var topRings = [rings[rows]]
        for r in stride(from: 0.8, to: 0.05, by: -0.25) { topRings.append(ring(R * r, L)) }
        for i in 0..<(topRings.count - 1) { band(topRings[i], topRings[i + 1]) }
        let topMid = UInt32(P.count)
        P.append(SIMD3(0, L, 0))
        let last = topRings.last!
        for k in 0..<n { T += [last + UInt32(k), last + UInt32((k + 1) % n), topMid] }
        // Bottom: in to 0.92 R and up to the recess, then a disc there (facing down).
        var bottomRings = [rings[0], ring(R * 0.92, recess)]
        for r in stride(from: 0.7, to: 0.05, by: -0.2) { bottomRings.append(ring(R * r, recess)) }
        for i in 0..<(bottomRings.count - 1) { band(bottomRings[i + 1], bottomRings[i]) }
        let botMid = UInt32(P.count)
        P.append(SIMD3(0, recess, 0))
        let inner = bottomRings.last!
        for k in 0..<n { T += [inner + UInt32((k + 1) % n), inner + UInt32(k), botMid] }
        return (P.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }, T)
    }

    func testAHollowGuessedBottomIsFoundAndFilledFlat() {
        // Adnoc Sample 5: Ø 37 mm × 52.3 mm, its bottom set about 2.3 mm up inside the core.
        let R = 0.0185, L = 0.0523
        let c = Self.cupCore(R: R, L: L, recess: 0.0023)
        let before = ScanMath.signedVolume(positions: c.positions, indices: c.indices)
        let ideal = Double.pi * R * R * L
        XCTAssertGreaterThan(before, 0.9 * ideal, "outward faces: positive volume")
        XCTAssertLessThan(before, 0.97 * ideal, "the cup loses volume")
        let plan = try! XCTUnwrap(BottomFill.find(positions: c.positions, indices: c.indices))
        XCTAssertEqual(plan.recess, 0.0023, accuracy: 0.0003)
        XCTAssertEqual(plan.floorY, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(plan.cutY, 0.0023)
        XCTAssertLessThan(plan.cutY, 0.004)
        XCTAssertEqual(plan.radius, R, accuracy: 0.0005)
        let filled = BottomFill.apply(positions: c.positions, indices: c.indices, plan: plan)
        let after = ScanMath.signedVolume(positions: filled.positions, indices: filled.indices)
        // The polygon side is a little inside the circle: compare with the same mesh closed flat.
        let flat = Self.cupCore(R: R, L: L, recess: 0)
        let flatVolume = ScanMath.signedVolume(positions: flat.positions, indices: flat.indices)
        XCTAssertEqual(after, flatVolume, accuracy: 0.004 * flatVolume)
        XCTAssertEqual(filled.positions.map { Double($0.y) }.min()!, 0, accuracy: 1e-6)
        XCTAssertEqual(filled.positions.map { Double($0.y) }.max()!, L, accuracy: 1e-6)
        // Filled once, nothing more to fill.
        XCTAssertNil(BottomFill.find(positions: filled.positions, indices: filled.indices))
    }

    func testAFlatBottomIsLeftAlone() {
        let c = Self.cupCore(R: 0.0127, L: 0.05, recess: 0)
        XCTAssertNil(BottomFill.find(positions: c.positions, indices: c.indices))
        // A hollow under 0.8 mm is within what the scan can tell.
        let shallow = Self.cupCore(R: 0.0127, L: 0.05, recess: 0.0004)
        XCTAssertNil(BottomFill.find(positions: shallow.positions, indices: shallow.indices))
    }

    func testABoxIsNotACup() {
        let (P, T) = StandTests.box(SIMD3(-0.01, 0, -0.007), SIMD3(0.01, 0.03, 0.007), n: 10)
        XCTAssertNil(BottomFill.find(positions: P, indices: T))
    }
}
