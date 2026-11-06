import XCTest
@testable import ScanMath

final class ShotLedgerTests: XCTestCase {
    let here = ShotLedger.Pose(degrees: 100, band: 1)
    let there = ShotLedger.Pose(degrees: 200, band: 1)

    func testSessionCountRestartOnNewPassKeepsCounting() {
        var l = ShotLedger()
        XCTAssertEqual(l.update(session: 30, files: nil, pose: here, now: 0).count, 30)
        // New pass: the session count restarts at 0, then 2 more photos come.
        XCTAssertEqual(l.update(session: 0, files: nil, pose: here, now: 1).count, 0)
        XCTAssertEqual(l.update(session: 2, files: nil, pose: there, now: 2), [there, there])
        XCTAssertEqual(l.counted, 32)
    }

    func testFilesOnDiskCountWhenSessionLagsAndNoDoubleCount() {
        var l = ShotLedger()
        _ = l.update(session: 10, files: 10, pose: here, now: 0)
        XCTAssertEqual(l.update(session: 10, files: 12, pose: there, now: 1).count, 2) // the session hasn't reported them
        XCTAssertEqual(l.update(session: 12, files: 12, pose: there, now: 2).count, 0) // now it has: not counted again
        XCTAssertEqual(l.counted, 12)
    }

    func testRequestedPhotoGoesWhereItWasAsked() {
        var l = ShotLedger()
        _ = l.update(session: 5, files: nil, pose: here, now: 0)
        l.requested(there, manual: false, now: 10)
        XCTAssertTrue(l.waiting)
        // The photo shows up 1.2 s later, after the phone moved back.
        XCTAssertEqual(l.update(session: 6, files: nil, pose: here, now: 11.2), [there])
        XCTAssertEqual(l.landed, 1)
        XCTAssertFalse(l.waiting)
    }

    func testIgnoredRequestsAreCountedPerSpot() {
        var l = ShotLedger()
        l.requested(there, manual: false, now: 0)
        XCTAssertEqual(l.update(session: 0, files: 0, pose: there, now: 2).count, 0)
        XCTAssertEqual(l.failures(at: there), 0) // still waiting
        _ = l.update(session: 0, files: 0, pose: there, now: 4)
        XCTAssertEqual(l.failures(at: there), 1)
        l.requested(there, manual: true, now: 5)
        _ = l.update(session: 0, files: 0, pose: there, now: 9)
        XCTAssertEqual(l.failures(at: there), 2)
        XCTAssertTrue(l.lastFailureWasManual)
        XCTAssertEqual(l.failed, 2)
        // A photo that finally lands there clears the record for that spot.
        l.requested(there, manual: true, now: 10)
        _ = l.update(session: 1, files: nil, pose: there, now: 10.5)
        XCTAssertEqual(l.failures(at: there), 0)
        XCTAssertFalse(l.lastFailureWasManual)
    }

    func testFillOrderFinishesTheWalkedRingFirst() {
        var m = CoverageMap()
        for s in 0..<20 { m.add(band: 1, degrees: Double(s) * 15 + 5) } // middle ring 20 of 24
        m.add(band: 2, degrees: 5)                                       // one stray high photo
        XCTAssertEqual(GapGuide.fillOrder(m), [1, 2])
        var full = CoverageMap()
        for s in 0..<24 { full.add(band: 1, degrees: Double(s) * 15 + 5) }
        XCTAssertEqual(GapGuide.fillOrder(full), [2]) // middle done: go up next
        // A few stray low photos don't send the user to the low ring before the untouched high one.
        var mixed = CoverageMap()
        for s in 0..<20 { mixed.add(band: 1, degrees: Double(s) * 15 + 5) }
        mixed.add(band: 0, degrees: 5)
        mixed.add(band: 0, degrees: 40)
        XCTAssertEqual(GapGuide.fillOrder(mixed), [1, 2, 0])
    }

    func testMoveText() {
        XCTAssertTrue(GapGuide.moveText(sectors: 0).hasPrefix("Gap here"))
        let ahead = GapGuide.moveText(sectors: 3)
        XCTAssertTrue(ahead.contains("45°") && ahead.contains("same way") && ahead.contains("25 cm"), ahead)
        XCTAssertTrue(GapGuide.moveText(sectors: -1).contains("back"))
    }
}
