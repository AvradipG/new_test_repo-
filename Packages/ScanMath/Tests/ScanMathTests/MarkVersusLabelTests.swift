import XCTest
import simd
@testable import ScanMath

/// A thin drawn line must win over a bold written label with more ink (3.7: a scan took the label "4002-2"
/// for the reference line, so the sheet's 0° view showed the label and the line sat at 180°).
final class MarkVersusLabelTests: XCTestCase {
    let rock = SIMD3<Float>(0.72, 0.70, 0.66)
    let ink = SIMD3<Float>(0.05, 0.05, 0.05)
    let pencil = SIMD3<Float>(0.18, 0.18, 0.18)
    let width = 720, height = 240 // 0.5° per column

    /// Six characters written along the sample, 22° wide, bold strokes: box outline plus a middle bar.
    func label(_ x: Int, _ y: Int) -> Bool {
        guard (30...74).contains(x), (30..<210).contains(y) else { return false }
        let r = (y - 30) % 30
        guard r < 22 else { return false } // gap between characters
        let edge = x < 35 || x > 69
        let bar = r < 5 || (9..<14).contains(r) || r >= 17
        return edge || bar
    }

    /// A faint pencil line at 200°, two columns wide, with tiny breaks.
    func line(_ x: Int, _ y: Int) -> Bool { (400...401).contains(x) && y % 40 >= 2 }

    func picture(withLine: Bool) -> [SIMD3<Float>] {
        var rng = SplitMix64(seed: 5)
        var px: [SIMD3<Float>] = []
        for y in 0..<height {
            for x in 0..<width {
                if label(x, y) { px.append(ink); continue }
                if withLine && line(x, y) { px.append(pencil); continue }
                let n = Float(rng.unit() * 2 - 1) * 0.05
                px.append(simd_clamp(rock + SIMD3(repeating: n), SIMD3(repeating: 0), SIMD3(repeating: 1)))
            }
        }
        return px
    }

    func testThinLineWinsOverABoldLabel() {
        let m = try! XCTUnwrap(MarkFinder.detect(rgb: picture(withLine: true), width: width, height: height, circumferenceMM: 80))
        XCTAssertEqual(m.angle, 200.25, accuracy: 2)
        XCTAssertEqual(m.kind, .blackLine)
        XCTAssertGreaterThan(m.confidence, 0.35)
    }

    func testALabelAloneIsNotTakenForTheMark() {
        XCTAssertNil(MarkFinder.detect(rgb: picture(withLine: false), width: width, height: height, circumferenceMM: 80))
    }
}
