import XCTest
import simd
@testable import ScanMath

final class MarkAndUnitsTests: XCTestCase {
    /// Unrolled side image: rock colour with grain noise, plus optional marks.
    func image(width: Int = 360, height: Int = 120, rock: SIMD3<Float>, noise: Float = 0.06,
               paint: (Int, Int) -> SIMD3<Float>?) -> [SIMD3<Float>] {
        var rng = SplitMix64(seed: 11)
        var px: [SIMD3<Float>] = []
        for y in 0..<height {
            for x in 0..<width {
                if let c = paint(x, y) { px.append(c); continue }
                let n = Float(rng.unit() * 2 - 1) * noise
                px.append(simd_clamp(rock + SIMD3(repeating: n), SIMD3(repeating: 0), SIMD3(repeating: 1)))
            }
        }
        return px
    }

    let sandstone = SIMD3<Float>(0.72, 0.64, 0.5)
    let shale = SIMD3<Float>(0.24, 0.24, 0.26)
    let red = SIMD3<Float>(0.85, 0.12, 0.1)
    let black = SIMD3<Float>(0.06, 0.06, 0.06)

    func testRedTopBlackBottomLineOnSandstone() {
        let px = image(rock: sandstone) { x, y in
            (136...138).contains(x) ? (y < 60 ? self.red : self.black) : nil
        }
        let m = try! XCTUnwrap(MarkFinder.detect(rgb: px, width: 360, height: 120))
        XCTAssertEqual(m.angle, 137.5, accuracy: 2)
        XCTAssertEqual(m.kind, .redBlackLine)
        XCTAssertEqual(m.redEnd, .top)
        XCTAssertFalse(m.upsideDown)
        XCTAssertGreaterThan(m.confidence, 0.5)
    }

    func testUpsideDownIsNoticed() {
        let px = image(rock: sandstone) { x, y in
            (300...302).contains(x) ? (y >= 60 ? self.red : self.black) : nil
        }
        let m = try! XCTUnwrap(MarkFinder.detect(rgb: px, width: 360, height: 120))
        XCTAssertEqual(m.angle, 301.5, accuracy: 2)
        XCTAssertTrue(m.upsideDown)
    }

    func testBlackLineOnShaleAndWrapAround() {
        let px = image(rock: shale, noise: 0.04) { x, _ in
            (x >= 358 || x <= 1) ? self.black : nil
        }
        let m = try! XCTUnwrap(MarkFinder.detect(rgb: px, width: 360, height: 120))
        let d = abs(Rotation.normalized(m.angle - 0))
        XCTAssertLessThan(d, 3)
        XCTAssertEqual(m.kind, .blackLine)
    }

    func testRedAndBlackLinesSideBySide() {
        let px = image(rock: sandstone) { x, _ in
            (80...82).contains(x) ? self.red : ((92...94).contains(x) ? self.black : nil)
        }
        let m = try! XCTUnwrap(MarkFinder.detect(rgb: px, width: 360, height: 120))
        XCTAssertEqual(m.kind, .redBlackPair)
        XCTAssertEqual(m.angle, 87.5, accuracy: 3)
    }

    func testNoMarkGivesNothing() {
        let px = image(rock: sandstone) { _, _ in nil }
        XCTAssertNil(MarkFinder.detect(rgb: px, width: 360, height: 120))
    }

    func testDarkSpotIsNotAMark() {
        let px = image(rock: sandstone) { x, y in
            (200...203).contains(x) && (50...56).contains(y) ? self.black : nil
        }
        XCTAssertNil(MarkFinder.detect(rgb: px, width: 360, height: 120))
    }

    func testUnits() {
        XCTAssertEqual(LengthUnit.mm.format(25.4), "25.4 mm")
        XCTAssertEqual(LengthUnit.cm.format(25.4), "2.54 cm")
        XCTAssertEqual(LengthUnit.m.format(25.4), "0.0254 m")
        XCTAssertEqual(LengthUnit.inch.format(25.4), "1.000 in")
        XCTAssertEqual(LengthUnit.inch.formatList([50.8, 25.4]), "2.000 × 1.000 in")
        XCTAssertEqual(LengthUnit.cm.formatArea(100), "1.00 cm²")
        XCTAssertEqual(LengthUnit.inch.formatVolume(cm3: 16.387064), "1.000 in³")
    }

    func testInchAndMetricRulers() {
        let inch = RulerTicks.ticks(coveringMM: 60, unit: .inch)
        XCTAssertEqual(inch.last!.mm, 76.2, accuracy: 1e-9) // 3 in
        XCTAssertEqual(inch.filter { $0.level == 2 }.compactMap { $0.label }, ["0", "1", "2", "3"])
        let cm = RulerTicks.ticks(coveringMM: 25, unit: .cm)
        XCTAssertEqual(cm.count, 31)
        XCTAssertEqual(cm.filter { $0.level == 2 }.compactMap { $0.label }, ["0", "1", "2", "3"])
        let mm = RulerTicks.ticks(coveringMM: 25, unit: .mm)
        XCTAssertEqual(mm.filter { $0.level == 2 }.compactMap { $0.label }, ["0", "10", "20", "30"])
        XCTAssertEqual(RulerTicks.ticks(coveringMM: 25), cm)
    }
}
