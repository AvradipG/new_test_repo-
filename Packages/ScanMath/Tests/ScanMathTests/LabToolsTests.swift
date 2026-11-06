import XCTest
import simd
@testable import ScanMath

final class LabToolsTests: XCTestCase {
    // A 1.5-inch plug, 50 mm long, in metres like an Object Capture model.
    let plug = DemoRock.cylinder(radius: 0.01905, height: 0.050)

    func testDemoRockIsAClosedPlugOfTheRightSize() {
        let s = ScanMath.stats(positions: plug.positions, indices: plug.indices, unitToMM: 1000)
        XCTAssertTrue(s.isClosed)
        let expected = Double.pi * 1.905 * 1.905 * 5.0 // cm³
        XCTAssertEqual(s.volumeCM3, expected, accuracy: expected * 0.01)
        XCTAssertEqual(s.axisA, 50, accuracy: 0.5)
    }

    func testDensityAndPorosity() {
        XCTAssertEqual(Density.bulk(massG: 150, volumeCM3: 60)!, 2.5, accuracy: 1e-12)
        XCTAssertNil(Density.bulk(massG: 0, volumeCM3: 60))
        XCTAssertNil(Density.bulk(massG: 10, volumeCM3: 0))
        XCTAssertEqual(Density.porosity(bulk: 2.385, grain: 2.65)!, 0.1, accuracy: 1e-9)
        XCTAssertNil(Density.porosity(bulk: 2.7, grain: 2.65))
    }

    func testVirtualCoringOnACylinder() {
        // A 40 mm wide, 60 mm tall rock.
        let rock = DemoRock.cylinder(radius: 0.020, height: 0.060)
        let one = VirtualCoring.longestPlug(positions: rock.positions, indices: rock.indices, diameter: 0.0254,
                                            vertical: true, step: 0.001, gridStep: 0.002)!
        XCTAssertEqual(one.length, 0.060, accuracy: 0.0011)          // the whole height
        XCTAssertLessThan(hypot(one.center.x, one.center.y), 0.0025)  // near the axis
        let big = VirtualCoring.longestPlug(positions: rock.positions, indices: rock.indices, diameter: 0.0381,
                                            vertical: true, step: 0.001, gridStep: 0.002)!
        XCTAssertEqual(big.length, 0.060, accuracy: 0.0011)          // 38.1 mm still fits in 40 mm
        let tooBig = VirtualCoring.longestPlug(positions: rock.positions, indices: rock.indices, diameter: 0.0508,
                                               vertical: true, step: 0.001, gridStep: 0.002)!
        XCTAssertEqual(tooBig.length, 0)                              // 2 inch does not
    }

    func testVirtualCoringAcrossALyingRock() {
        // The same rock, plug drilled along its long axis a (which is the height here).
        let rock = DemoRock.cylinder(radius: 0.020, height: 0.060)
        let r = VirtualCoring.longestPlug(positions: rock.positions, indices: rock.indices, diameter: 0.0254,
                                          vertical: false, step: 0.001, gridStep: 0.002)!
        XCTAssertEqual(r.length, 0.060, accuracy: 0.0011)
    }

    func testCTFramePutsTheRockOnTheAxisFromZero() {
        // Shift the plug sideways and up: the CT frame must undo it.
        let moved = plug.positions.map { $0 + SIMD3<Float>(0.3, 0.12, -0.2) }
        let f = CTFrame.make(moved)
        let pts = moved.map { f.apply($0, scale: 1000) }
        let zs = pts.map(\.z)
        XCTAssertEqual(zs.min()!, 0, accuracy: 1e-3)
        XCTAssertEqual(zs.max()!, 50, accuracy: 1e-3)
        let radial = pts.map { hypot($0.x, $0.y) }.max()!
        XCTAssertEqual(radial, 19.05, accuracy: 0.01)
        // The matrix gives the same answer as apply().
        let m = f.matrix(scale: 1000)
        let p = SIMD3<Double>(moved[7])
        let viaMatrix = SIMD3((0..<3).map { r in m[r][0] * p.x + m[r][1] * p.y + m[r][2] * p.z + m[r][3] })
        XCTAssertEqual(simd_distance(viaMatrix, pts[7]), 0, accuracy: 1e-6)
    }

    func testBeddingFitRecoversDipAndDirection() {
        let radius = 19.05
        let dip = 30.0, high = 60.0, centre = 25.0
        let amp = radius * tan(dip * .pi / 180)
        let angles = [10.0, 95, 170, 250, 320]
        let heights = angles.map { centre + amp * cos(($0 - high) * .pi / 180) }
        let f = BeddingFit.fit(angles: angles, heights: heights, radiusMM: radius)!
        XCTAssertEqual(f.dipDegrees, dip, accuracy: 1e-6)
        XCTAssertEqual(f.highAngleDegrees, high, accuracy: 1e-6)
        XCTAssertEqual(f.centreHeightMM, centre, accuracy: 1e-6)
        XCTAssertEqual(f.rmsMM, 0, accuracy: 1e-9)
        // A plane square across the core has no dip.
        let flat = BeddingFit.fit(angles: [0, 120, 240], heights: [10, 10, 10], radiusMM: radius)!
        XCTAssertEqual(flat.dipDegrees, 0, accuracy: 1e-9)
        // Three taps at the same angle can't define a plane.
        XCTAssertNil(BeddingFit.fit(angles: [5, 5, 5], heights: [1, 2, 3], radiusMM: radius))
    }
}

final class ScaleReferenceTests: XCTestCase {
    func testFactor() {
        XCTAssertEqual(ScaleReference.factor(trueMM: 25.4, scannedMM: 25.0)!, 1.016, accuracy: 1e-12)
        XCTAssertNil(ScaleReference.factor(trueMM: 25.4, scannedMM: 50))  // wrong axis
        XCTAssertNil(ScaleReference.factor(trueMM: 0, scannedMM: 25))
    }
}
