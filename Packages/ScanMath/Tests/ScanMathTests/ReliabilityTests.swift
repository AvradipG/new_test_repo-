import XCTest
@testable import ScanMath

final class ReliabilityTests: XCTestCase {
    func testAllInOneStaysInsideTheBudgetWithGapsAndTitle() {
        // The case from the review: 100 slices of 1000 × 1000 px went to 33.3 MP before.
        let l = AllInOneLayout.plan(count: 100, tileWidth: 1000, tileHeight: 1000)!
        XCTAssertEqual(l.cols, 10)
        XCTAssertEqual(l.rows, 10)
        XCTAssertLessThanOrEqual(l.width * l.height, 32_000_000)
        XCTAssertLessThanOrEqual(max(l.width, l.height), 10_000)
        XCTAssertGreaterThan(l.tileWidth, 500)
    }

    func testSmallStackIsNotShrunk() {
        let l = AllInOneLayout.plan(count: 4, tileWidth: 900, tileHeight: 700)!
        XCTAssertEqual(l.tileWidth, 900)
        XCTAssertEqual(l.tileHeight, 700)
        XCTAssertEqual(l.width, 2 * 900 + 3 * 8)
        XCTAssertEqual(l.height, 64 + 2 * 700 + 3 * 8)
    }

    func testImpossibleLayoutsFailSafely() {
        XCTAssertNil(AllInOneLayout.plan(count: 0, tileWidth: 100, tileHeight: 100))
        XCTAssertNil(AllInOneLayout.plan(count: 10, tileWidth: 0, tileHeight: 100))
        XCTAssertNil(AllInOneLayout.plan(count: 1_000_000, tileWidth: 1000, tileHeight: 1000)) // tiles would be unreadable
        let tall = AllInOneLayout.plan(count: 3, tileWidth: 400, tileHeight: 40_000)!         // limited by the side cap
        XCTAssertLessThanOrEqual(tall.height, 10_000)
    }

    func testBuildStopClassification() {
        // On screen: always a failure.
        XCTAssertEqual(BuildStop.classify(interrupted: false, domain: "CoreOC", code: 1, pausesSoFar: 0), .failure)
        // Locked phone, unknown photogrammetry error: a pause.
        XCTAssertEqual(BuildStop.classify(interrupted: true, domain: "CoreOC", code: 1, pausesSoFar: 3), .pause)
        // Disk full or a missing file while in the background is still a real failure.
        XCTAssertEqual(BuildStop.classify(interrupted: true, domain: "NSCocoaErrorDomain", code: 640, pausesSoFar: 0), .failure)
        XCTAssertEqual(BuildStop.classify(interrupted: true, domain: "NSPOSIXErrorDomain", code: 28, pausesSoFar: 0), .failure)
        XCTAssertEqual(BuildStop.classify(interrupted: true, domain: "NSCocoaErrorDomain", code: 260, pausesSoFar: 0), .failure)
        // After 30 pauses the next stop counts as a failure.
        XCTAssertEqual(BuildStop.classify(interrupted: true, domain: "CoreOC", code: 1, pausesSoFar: 30), .failure)
    }
}
