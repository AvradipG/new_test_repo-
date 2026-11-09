import XCTest
import simd
@testable import ScanMath

/// The marks used in the lab (3.8), drawn the way they look in a real unrolled scan: a thin line only a little
/// darker than the rock and slightly slanted, often with a red top and a black dot at the bottom; or only a red
/// mark at the top and/or a black mark at the bottom; next to a bold sample number written along the sample.
final class MarkKindsTests: XCTestCase {
    let width = 720, height = 300            // 0.5° per column; 80 mm round → 9 px per mm
    let rock = SIMD3<Float>(0.62, 0.62, 0.60)
    let ink = SIMD3<Float>(0.06, 0.06, 0.07)
    let redInk = SIMD3<Float>(0.78, 0.18, 0.14)

    /// A sample number written top to bottom: four boxy characters with 8 px strokes, 60 px across.
    func label(_ x: Int, _ y: Int, at x0: Int = 100) -> Bool {
        guard (x0..<(x0 + 60)).contains(x), (40..<260).contains(y) else { return false }
        let r = (y - 40) % 55
        guard r < 44 else { return false }
        return x < x0 + 8 || x >= x0 + 52 || r < 8 || r >= 36
    }

    /// The thin mark line: 3 px wide, drifting 6 px from top to bottom, 0.15 darker than the rock.
    func onLine(_ x: Int, _ y: Int, at x0: Int) -> Bool {
        let c = x0 + y * 6 / height
        return (c...(c + 2)).contains(x)
    }

    func picture(_ paint: (Int, Int) -> SIMD3<Float>?) -> [SIMD3<Float>] {
        var rng = SplitMix64(seed: 23)
        var px: [SIMD3<Float>] = []
        for y in 0..<height {
            for x in 0..<width {
                if let c = paint(x, y) { px.append(c); continue }
                let n = Float(rng.unit() * 2 - 1) * 0.05
                px.append(simd_clamp(rock + SIMD3(repeating: n), SIMD3(repeating: 0), SIMD3(repeating: 1)))
            }
        }
        return px
    }

    func detect(_ px: [SIMD3<Float>]) -> MarkDetection? {
        MarkFinder.detect(rgb: px, width: width, height: height, circumferenceMM: 80)
    }

    /// The case from the field: the bold label was taken for the mark and the real line sat at 180°.
    func testFaintLineWithRedTopAndBlackDotBeatsABoldLabel() {
        let px = picture { x, y in
            if self.label(x, y) { return self.ink }
            if y < 30 && self.onLine(x, y, at: 500) { return self.redInk }
            if y >= 270 && y < 292 && (502...510).contains(x) { return self.ink }
            if self.onLine(x, y, at: 500) { return self.rock - SIMD3(repeating: 0.15) }
            return nil
        }
        let m = try! XCTUnwrap(detect(px))
        XCTAssertEqual(m.angle, 252, accuracy: 2.5)
        XCTAssertEqual(m.kind, .redBlackLine)
        XCTAssertEqual(m.redEnd, .top)
        XCTAssertGreaterThan(m.confidence, 0.6)
    }

    func testRedTopAndBlackBottomWithoutALine() {
        let px = picture { x, y in
            if self.label(x, y) { return self.ink }
            if y < 30 && (300...303).contains(x) { return self.redInk }
            if y >= 270 && y < 292 && (299...305).contains(x) { return self.ink }
            return nil
        }
        let m = try! XCTUnwrap(detect(px))
        XCTAssertEqual(m.angle, 151, accuracy: 2)
        XCTAssertEqual(m.kind, .redBlackEnds)
        XCTAssertEqual(m.redEnd, .top)
        XCTAssertGreaterThanOrEqual(m.confidence, 0.35)
    }

    func testRedTopMarkAlone() {
        let px = picture { x, y in
            if self.label(x, y) { return self.ink }
            return y < 30 && (300...303).contains(x) ? self.redInk : nil
        }
        let m = try! XCTUnwrap(detect(px))
        XCTAssertEqual(m.angle, 151, accuracy: 2)
        XCTAssertEqual(m.kind, .redSpot)
        XCTAssertEqual(m.redEnd, .top)
        XCTAssertGreaterThanOrEqual(m.confidence, 0.35)
    }

    func testBlackBottomMarkAlone() {
        let px = picture { x, y in
            if self.label(x, y) { return self.ink }
            return y >= 266 && y < 292 && (298...305).contains(x) ? self.ink : nil
        }
        let m = try! XCTUnwrap(detect(px))
        XCTAssertEqual(m.angle, 151, accuracy: 2)
        XCTAssertEqual(m.kind, .blackSpot)
        XCTAssertEqual(m.redEnd, .top, "the black mark is the bottom, so the sample stood the right way up")
        XCTAssertGreaterThanOrEqual(m.confidence, 0.35)
        XCTAssertLessThanOrEqual(m.confidence, 0.4)
    }

    func testBlackMarkAtTheTopMeansUpsideDown() {
        let px = picture { x, y in
            y >= 8 && y < 34 && (598...605).contains(x) ? self.ink : nil
        }
        let m = try! XCTUnwrap(detect(px))
        XCTAssertEqual(m.angle, 301, accuracy: 2)
        XCTAssertTrue(m.upsideDown)
    }

    func testABoldLabelAloneIsNoMark() {
        let px = picture { x, y in self.label(x, y) ? self.ink : nil }
        XCTAssertNil(detect(px))
    }

    func testFoundAcrossTheSeam() {
        let px = picture { x, y in
            if self.label(x, y, at: 300) { return self.ink }
            return self.onLine(x, y, at: 716) || self.onLine(x + self.width, y, at: 716) ? self.ink : nil
        }
        let m = try! XCTUnwrap(detect(px))
        XCTAssertLessThan(abs(Rotation.normalized(m.angle - 0)), 3)
        XCTAssertEqual(m.kind, .blackLine)
    }
}
