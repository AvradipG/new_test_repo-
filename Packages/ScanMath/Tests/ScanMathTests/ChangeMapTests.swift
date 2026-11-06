import XCTest
import simd
@testable import ScanMath

final class ChangeMapTests: XCTestCase {
    func moved(_ m: (positions: [SIMD3<Float>], indices: [UInt32])) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        let R = Pose.rotation(axis: SIMD3(0, 1, 0), degrees: 50) * Pose.rotation(axis: SIMD3(1, 0, 0), degrees: 30)
        let t = SIMD3<Double>(0.1, -0.05, 0.02)
        return (m.positions.map { SIMD3<Float>(R * SIMD3<Double>($0) + t) }, m.indices)
    }

    func testSameRockInAnotherPoseShowsNoChange() {
        let a = DemoRock.cylinder(radius: 0.020, height: 0.060)
        let r = ChangeMap.compare(reference: a, compared: moved(a))!
        XCTAssertLessThan(r.p95Abs, 0.00005)   // under 0.05 mm
        XCTAssertLessThan(r.fitRMS, 0.00002)
    }

    func testSwollenRockShowsTheGain() {
        let a = DemoRock.cylinder(radius: 0.020, height: 0.060)
        let b = DemoRock.cylinder(radius: 0.0205, height: 0.060) // 0.5 mm thicker all round
        let r = ChangeMap.compare(reference: a, compared: moved(b))!
        XCTAssertEqual(r.median, 0.0005, accuracy: 0.0001)
        XCTAssertGreaterThan(r.mean, 0.0003)
    }

    func testColourScale() {
        let white = ChangeMap.colour(0, range: 1), red = ChangeMap.colour(1, range: 1), blue = ChangeMap.colour(-2, range: 1)
        XCTAssertEqual([white.r, white.g, white.b], [255, 255, 255])
        XCTAssertEqual([red.r, red.g, red.b], [255, 0, 0])
        XCTAssertEqual([blue.r, blue.g, blue.b], [0, 0, 255])
    }
}
