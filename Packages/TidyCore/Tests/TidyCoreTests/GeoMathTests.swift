import XCTest
@testable import TidyCore

final class GeoMathTests: XCTestCase {
    func testBearing() {
        // Camera looks along −Z and the compass says 90° (east): −Z points east.
        XCTAssertEqual(GeoMath.bearingOfMinusZ(headingDegrees: 90, forwardX: 0, forwardZ: -1), 90, accuracy: 1e-9)
        // Camera looks along +X and the compass says 0° (north): −Z points west.
        XCTAssertEqual(GeoMath.bearingOfMinusZ(headingDegrees: 0, forwardX: 1, forwardZ: 0), 270, accuracy: 1e-9)
    }

    func testEastNorth() {
        let n = GeoMath.eastNorth(x: 0, z: -10, bearingOfMinusZ: 0)
        XCTAssertEqual(n.north, 10, accuracy: 1e-9)
        XCTAssertEqual(n.east, 0, accuracy: 1e-9)
        let e = GeoMath.eastNorth(x: 0, z: -10, bearingOfMinusZ: 90)
        XCTAssertEqual(e.east, 10, accuracy: 1e-9, "−Z pointing east puts a point 10 m along −Z 10 m east")
        XCTAssertEqual(e.north, 0, accuracy: 1e-9)
        let x = GeoMath.eastNorth(x: 5, z: 0, bearingOfMinusZ: 0)
        XCTAssertEqual(x.east, 5, accuracy: 1e-9)
    }

    func testLocateAndDistance() {
        let home = GeoPoint(latitude: 29.76, longitude: -95.37)
        let p = GeoMath.locate(x: 0, z: -100, origin: home, bearingOfMinusZ: 0)
        XCTAssertGreaterThan(p.latitude, home.latitude)
        XCTAssertEqual(GeoMath.distance(home, p), 100, accuracy: 0.5)
        let q = GeoMath.locate(x: 30, z: 40, origin: home, bearingOfMinusZ: 123)
        XCTAssertEqual(GeoMath.distance(home, q), 50, accuracy: 0.5, "distance doesn't depend on the bearing")
    }

    func testNearest() {
        let home = GeoPoint(latitude: 29.76, longitude: -95.37)
        let office = GeoMath.offset(home, east: 3000, north: 0)
        let here = GeoMath.offset(home, east: 40, north: 20)
        XCTAssertEqual(GeoMath.nearest([("home", home), ("office", office)], to: here, within: 250), "home")
        XCTAssertNil(GeoMath.nearest([("office", office)], to: here, within: 250))
    }

    func testCompassName() {
        XCTAssertEqual(GeoMath.compassName(0), "N")
        XCTAssertEqual(GeoMath.compassName(350), "N")
        XCTAssertEqual(GeoMath.compassName(100), "E")
        XCTAssertEqual(GeoMath.compassName(-90), "W")
    }
}
