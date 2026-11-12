import XCTest
import simd
@testable import ScanMath

/// 3.16: a core whose bottom is cut off square leans when it stands; the app says where the paper goes.
final class LevelTests: XCTestCase {
    /// A closed core mesh (axis +Y in its own frame) of radius R and length L whose bottom is cut by a plane tilted
    /// `tiltDeg` so that it recedes toward the direction at `towardDeg` (azimuth atan2(x, z)); then stood on that
    /// bottom face (the face turned flat onto y = 0).
    func core(R: Double, L: Double, tiltDeg: Double, towardDeg: Double, n: Int = 96, rows: Int = 40)
        -> (positions: [SIMD3<Float>], indices: [UInt32], lean: SIMD3<Double>) {
        let t = tiltDeg * .pi / 180, b = towardDeg * .pi / 180
        let dir = SIMD3<Double>(sin(b), 0, cos(b))
        // Bottom face: y = tan(t) · (p · dir): higher (receding into the core) toward +dir.
        func bottom(_ x: Double, _ z: Double) -> Double { tan(t) * (x * dir.x + z * dir.z) }
        var P: [SIMD3<Double>] = [], T: [UInt32] = []
        for j in 0...rows {
            for k in 0..<n {
                let th = 2 * Double.pi * Double(k) / Double(n)
                let x = R * sin(th), z = R * cos(th)
                let y0 = bottom(x, z)
                P.append(SIMD3(x, y0 + (L - y0) * Double(j) / Double(rows), z))
            }
        }
        func v(_ j: Int, _ k: Int) -> UInt32 { UInt32(j * n + (k % n)) }
        for j in 0..<rows {
            for k in 0..<n {
                // Outward winding (seen from outside, counter-clockwise).
                T += [v(j, k), v(j, k + 1), v(j + 1, k + 1), v(j, k), v(j + 1, k + 1), v(j + 1, k)]
            }
        }
        // Caps with a ring of rims and a fan from the middle, several rings for even sampling.
        let rings = 12
        func cap(top: Bool) {
            let centre = UInt32(P.count)
            P.append(SIMD3(0, top ? L : bottom(0, 0), 0))
            var ringStart: [UInt32] = []
            for r in 1..<rings {
                ringStart.append(UInt32(P.count))
                let rr = R * Double(r) / Double(rings)
                for k in 0..<n {
                    let th = 2 * Double.pi * Double(k) / Double(n)
                    let x = rr * sin(th), z = rr * cos(th)
                    P.append(SIMD3(x, top ? L : bottom(x, z), z))
                }
            }
            let rimRow = top ? rows : 0
            func ring(_ r: Int, _ k: Int) -> UInt32 { r == rings - 1 ? v(rimRow, k) : ringStart[r] + UInt32(k % n) }
            for k in 0..<n {
                let a = ringStart[0] + UInt32(k), b2 = ringStart[0] + UInt32((k + 1) % n)
                T += top ? [centre, b2, a] : [centre, a, b2]
            }
            for r in 0..<(rings - 2) {
                for k in 0..<n {
                    let a = ring(r, k), b2 = ring(r, k + 1), c = ring(r + 1, k + 1), d = ring(r + 1, k)
                    T += top ? [a, c, b2, a, d, c] : [a, b2, c, a, c, d]
                }
            }
        }
        cap(top: true)
        cap(top: false)
        // Stand it on the bottom face: turn the face's outward normal straight down.
        let nb = simd_normalize(SIMD3<Double>(tan(t) * dir.x, -1, tan(t) * dir.z))
        let Rot = Pose.align(nb, to: SIMD3(0, -1, 0))
        let moved = P.map { Rot * $0 }
        let minY = moved.map { $0.y }.min()!
        let axis = Rot * SIMD3<Double>(0, 1, 0)
        let lean = simd_normalize(SIMD3(axis.x, 0, axis.z))
        return (moved.map { SIMD3<Float>(Float($0.x), Float($0.y - minY), Float($0.z)) }, T, lean)
    }

    func testCoreCutOffSquareLeansAndGetsPaperOnTheShortSide() {
        let c = core(R: 0.0127, L: 0.05, tiltDeg: 1.5, towardDeg: 70)
        let r = try! XCTUnwrap(CoreLeveller.plan(positions: c.positions, indices: c.indices))
        XCTAssertEqual(r.diameterMM, 25.4, accuracy: 0.3)
        XCTAssertEqual(r.asScanned.tiltDeg, 1.5, accuracy: 0.15)
        // The paper goes on the side the top leans to, which is where the bottom was cut short.
        let leanAz = atan2(c.lean.x, c.lean.z) * 180 / .pi
        XCTAssertEqual(Rotation.normalized(r.asScanned.liftAzimuthDeg - leanAz), 0, accuracy: 3)
        XCTAssertEqual(Rotation.normalized(r.asScanned.liftAzimuthDeg - 70), 0, accuracy: 3)
        XCTAssertEqual(r.asScanned.rimGapMM, 25.4 * tan(1.5 * .pi / 180), accuracy: 0.06)
        // The top end is square: standing on it needs nothing.
        let over = try! XCTUnwrap(r.turnedOver)
        XCTAssertLessThan(over.tiltDeg, 0.15)
        XCTAssertLessThan(r.asScanned.spreadDeg, 0.3)
        // Paper slips, counted from a mark at protractor angle 30° (its model azimuth is −30°).
        let s = CoreLeveller.slips(r.asScanned, radiusMM: 12.7, markAngleDeg: 30, turnedOver: false, paperMM: 0.1)
        XCTAssertEqual(Rotation.normalized(s.single.angle - 100), 0, accuracy: 3)
        // Near the rim: (R + 0.85 R) · tan 1.5° = 0.615 mm, six layers of 0.1 mm paper.
        XCTAssertEqual(s.single.gapMM, 1.85 * 12.7 * tan(1.5 * .pi / 180), accuracy: 0.05)
        XCTAssertEqual(s.single.layers, 6)
        XCTAssertEqual(s.pair.count, 2)
        XCTAssertEqual(Rotation.normalized(s.pair[0].angle - 40), 0, accuracy: 3)
        XCTAssertEqual(Rotation.normalized(s.pair[1].angle - 160), 0, accuracy: 3)
        // Turned over, angles seen from above run the other way.
        let t = CoreLeveller.slips(r.asScanned, radiusMM: 12.7, markAngleDeg: 30, turnedOver: true, paperMM: 0.1)
        XCTAssertEqual(Rotation.normalized(t.single.angle + 100), 0, accuracy: 3)
    }

    /// 3.17: with the underside scanned, the end it stood on is measured from its own face, so a table that
    /// isn't level (here 2° off) doesn't come into it.
    func testUndersideFaceIsIndependentOfTheTable() {
        let c = core(R: 0.0127, L: 0.05, tiltDeg: 1.2, towardDeg: -40)
        // The whole scene tipped 2° about x: the table wasn't level.
        let tip = Pose.rotation(axis: SIMD3(1, 0, 0), degrees: 2)
        let tipped = c.positions.map { p -> SIMD3<Float> in
            let q = tip * SIMD3<Double>(p)
            return SIMD3<Float>(Float(q.x), Float(q.y), Float(q.z))
        }
        let byGravity = try! XCTUnwrap(CoreLeveller.plan(positions: tipped, indices: c.indices))
        XCTAssertGreaterThan(abs(byGravity.asScanned.tiltDeg - 1.2), 0.5, "the gravity reading is thrown off by the table")
        let byFace = try! XCTUnwrap(CoreLeveller.plan(positions: tipped, indices: c.indices, bottomSeen: true))
        XCTAssertEqual(byFace.asScanned.method, "end_face")
        XCTAssertEqual(byFace.asScanned.tiltDeg, 1.2, accuracy: 0.15)
        XCTAssertEqual(Rotation.normalized(byFace.asScanned.liftAzimuthDeg + 40), 0, accuracy: 4)
    }

    func testAStraightCoreNeedsNothing() {
        let c = core(R: 0.019, L: 0.06, tiltDeg: 0, towardDeg: 0)
        let r = try! XCTUnwrap(CoreLeveller.plan(positions: c.positions, indices: c.indices))
        XCTAssertLessThan(r.asScanned.tiltDeg, 0.15)
        XCTAssertLessThan(r.asScanned.rimGapMM, 0.1)
    }

    func testAShapeThatIsNotACylinderGetsNoPlan() {
        let (P, T) = StandTests.box(SIMD3(-0.01, 0, -0.007), SIMD3(0.01, 0.03, 0.007), n: 10)
        XCTAssertNil(CoreLeveller.plan(positions: P, indices: T))
    }

    func testOutlineStepTellsABlockFromAStraightCore() {
        // A straight core: the outline runs on unchanged at any height.
        let c = core(R: 0.019, L: 0.12, tiltDeg: 0, towardDeg: 0)
        let s1 = try! XCTUnwrap(StandFinder.outlineStep(positions: c.positions, y: 0.025, band: 0.003))
        XCTAssertLessThan(s1.areaChange, 0.06)
        XCTAssertLessThan(s1.shift, 0.03)
        // A 10 × 10 mm rock standing off-centre on a 12 × 12 mm block.
        var (P, T) = StandTests.box(SIMD3(-0.006, 0, -0.006), SIMD3(0.006, 0.02, 0.006), n: 12)
        let (rp, rt) = StandTests.box(SIMD3(-0.004, 0.02, -0.005), SIMD3(0.006, 0.04, 0.005), n: 12)
        T += rt.map { $0 + UInt32(P.count) }
        P += rp
        let s2 = try! XCTUnwrap(StandFinder.outlineStep(positions: P, y: 0.02, band: 0.003))
        XCTAssertGreaterThan(s2.areaChange, 0.2)
    }
}
