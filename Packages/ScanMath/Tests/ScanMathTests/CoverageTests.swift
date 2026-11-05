import XCTest
@testable import ScanMath

final class CoverageTests: XCTestCase {
    func testSectorEdges() {
        XCTAssertEqual(CoverageMap.sector(0), 0)
        XCTAssertEqual(CoverageMap.sector(14.99), 0)
        XCTAssertEqual(CoverageMap.sector(15), 1)
        XCTAssertEqual(CoverageMap.sector(359.99), 23)
        XCTAssertEqual(CoverageMap.sector(360), 0)
        XCTAssertEqual(CoverageMap.sector(-0.01), 23)
        XCTAssertEqual(CoverageMap.sector(-360), 0)
        XCTAssertEqual(CoverageMap.wrap(190), -170, accuracy: 1e-9)
        XCTAssertEqual(CoverageMap.wrap(-190), 170, accuracy: 1e-9)
        XCTAssertEqual(CoverageMap.band(lookDown: 10), 0)
        XCTAssertEqual(CoverageMap.band(lookDown: 35), 1)
        XCTAssertEqual(CoverageMap.band(lookDown: 70), 2)
    }

    func testGapAcrossStartIsOneGap() {
        var m = CoverageMap()
        for s in 2..<22 { m.add(band: 1, degrees: Double(s) * 15 + 7) }
        let g = m.gaps()
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.first?.length, 4) // sectors 22, 23, 0, 1
        XCTAssertEqual(g.first?.from, 22)
        XCTAssertEqual(m.nearestGap(fromSector: 3, band: 1), -2)
        XCTAssertEqual(m.nearestGap(fromSector: 20, band: 1), 2)
        XCTAssertEqual(m.nearestGap(fromSector: 23, band: 1), 0)
    }

    func testNoRequestWhileMovingFastOrOnCoveredSector() {
        var m = CoverageMap()
        m.add(band: 1, degrees: 100)
        var p = ShotPlanner()
        var t = 0.0
        // Covered sector: never.
        for _ in 0..<30 { XCTAssertFalse(p.update(map: m, degrees: 100, lookDown: 35, speed: 0, tracking: true, now: t)); t += 0.1 }
        // Empty sector but walking fast: never.
        for _ in 0..<30 { XCTAssertFalse(p.update(map: m, degrees: 200, lookDown: 35, speed: 25, tracking: true, now: t)); t += 0.1 }
        // Not tracking: never.
        for _ in 0..<30 { XCTAssertFalse(p.update(map: m, degrees: 200, lookDown: 35, speed: 0, tracking: false, now: t)); t += 0.1 }
    }

    func testRequestAfterDwellAndRateLimited() {
        let m = CoverageMap()
        var p = ShotPlanner()
        var fired: [Double] = []
        var t = 0.0
        while t < 3.0 {
            if p.update(map: m, degrees: 50, lookDown: 35, speed: 3, tracking: true, now: t) { fired.append(t) }
            t += 0.1
        }
        XCTAssertFalse(fired.isEmpty)
        XCTAssertGreaterThanOrEqual(fired[0], 0.7 - 1e-9)
        for (a, b) in zip(fired, fired.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 0.9 - 1e-9) }
    }

    func testChangingHeightRestartsDwell() {
        let m = CoverageMap()
        var p = ShotPlanner()
        XCTAssertFalse(p.update(map: m, degrees: 50, lookDown: 35, speed: 0, tracking: true, now: 0))
        XCTAssertFalse(p.update(map: m, degrees: 50, lookDown: 35, speed: 0, tracking: true, now: 0.5))
        // Now in the high band: the dwell starts again.
        XCTAssertFalse(p.update(map: m, degrees: 50, lookDown: 60, speed: 0, tracking: true, now: 0.8))
        XCTAssertFalse(p.update(map: m, degrees: 50, lookDown: 60, speed: 0, tracking: true, now: 1.4))
        XCTAssertTrue(p.update(map: m, degrees: 50, lookDown: 60, speed: 0, tracking: true, now: 1.6))
    }

    /// Smoke test of the reported problem: Object Capture skips some spots on the first ring and then refuses to
    /// take more photos anywhere. Going back to the orange sectors must still turn them green.
    func testGapsFillOnSecondPassWhenObjectCaptureRefuses() {
        var map = CoverageMap()
        var planner = ShotPlanner()
        let refused = Set(6...9) // sectors Object Capture never photographs on its own
        var t = 0.0
        var lastAuto = -1.0

        // Pass 1: steady walk at 20°/s, middle height; Object Capture shoots once a second except in `refused`.
        var deg = 0.0
        while deg < 360 {
            if t - lastAuto >= 1, !refused.contains(CoverageMap.sector(deg)) {
                map.add(band: 1, degrees: deg)
                lastAuto = t
            }
            if planner.update(map: map, degrees: deg, lookDown: 35, speed: 20, tracking: true, now: t) {
                map.add(band: 1, degrees: deg)
            }
            deg += 2
            t += 0.1
        }
        XCTAssertFalse(map.gaps().isEmpty, "the first ring should leave the refused sectors empty")
        let emptyBefore = map.counts[1].filter { $0 == 0 }.count
        XCTAssertGreaterThanOrEqual(emptyBefore, 4)

        // Pass 2: the user walks slowly to each gap and pauses; Object Capture now refuses everything.
        var requests = 0
        for _ in 0..<3 {
            for sector in 0..<CoverageMap.sectorCount where map.counts[1][sector] == 0 {
                let target = Double(sector) * 15 + 7.5
                for k in 0..<15 { // 1.5 s at the spot, rocking a little
                    let d = target + Double(k % 3 - 1)
                    if planner.update(map: map, degrees: d, lookDown: 35, speed: 4, tracking: true, now: t) {
                        map.add(band: 1, degrees: d)
                        requests += 1
                    }
                    t += 0.1
                }
                t += 2 // walking to the next one
            }
        }
        XCTAssertEqual(map.counts[1].filter { $0 == 0 }.count, 0, "every sector of the ring should be green")
        XCTAssertLessThanOrEqual(requests, emptyBefore + 2, "one photo per gap, not a burst")
    }

    /// Low and high rings fill the same way, and a requested photo lands in the band the phone is in.
    func testRequestedPhotoGoesToCurrentBand() {
        var map = CoverageMap()
        var planner = ShotPlanner()
        var t = 0.0
        while !planner.update(map: map, degrees: 123, lookDown: 65, speed: 0, tracking: true, now: t) { t += 0.1 }
        map.add(band: CoverageMap.band(lookDown: 65), degrees: 123)
        XCTAssertEqual(map.count(band: 2, degrees: 123), 1)
        XCTAssertEqual(map.count(band: 1, degrees: 123), 0)
        XCTAssertFalse(planner.update(map: map, degrees: 123, lookDown: 65, speed: 0, tracking: true, now: t + 5))
    }
}
