import XCTest
import simd
@testable import ScanMath

final class ShapeFitTests: XCTestCase {
    /// Deterministic noise in [-1, 1].
    struct LCG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    /// Surface points of a core plug (side and both caps), metres, axis tilted about x by `tilt` degrees.
    func plug(radius: Double, length: Double, tilt: Double, noise: Double, base: Bool) -> [SIMD3<Float>] {
        var rng = LCG(s: 42)
        var out: [SIMD3<Double>] = []
        for i in 0..<180 { for j in 0..<60 {
            let a = Double(i) * 2 * .pi / 180, h = Double(j) / 59 * length
            out.append(SIMD3(radius * cos(a), h, radius * sin(a)))
        } }
        for k in 0..<1500 { // caps
            let r = radius * (Double(k % 30) / 30), a = Double(k) * 0.37
            out.append(SIMD3(r * cos(a), 0, r * sin(a)))
            out.append(SIMD3(r * cos(a), length, r * sin(a)))
        }
        let t = tilt * .pi / 180
        out = out.map { p in SIMD3(p.x, p.y * cos(t) - p.z * sin(t), p.y * sin(t) + p.z * cos(t)) }
        if base { // a lump of putty under it, wider than the plug and not round
            for k in 0..<3000 {
                let a = Double(k) * 0.11, r = radius * (1.25 + 0.15 * sin(3 * a))
                out.append(SIMD3(r * cos(a), -0.012 * Double(k % 10) / 10, r * sin(a)))
            }
        }
        return out.map { p in SIMD3<Float>(p + SIMD3(rng.next(), rng.next(), rng.next()) * noise) }
    }

    func testCorePlugIsCylinder() {
        let pts = plug(radius: 0.0254, length: 0.150, tilt: 3, noise: 0.0002, base: true)
        let f = ScanMath.fitShape(pts)!
        XCTAssertEqual(f.kind, .cylinder)
        XCTAssertEqual(f.diameter * 1000, 50.8, accuracy: 0.4)
        XCTAssertEqual(f.length * 1000, 150, accuracy: 3)
        XCTAssertEqual(f.tiltDegrees, 3, accuracy: 1)
        XCTAssertGreaterThan(f.axis.y, 0)
    }

    func testShortDiscIsCylinder() {
        let pts = plug(radius: 0.020, length: 0.025, tilt: 0, noise: 0.0001, base: false)
        let f = ScanMath.fitShape(pts)!
        XCTAssertEqual(f.kind, .cylinder)
        XCTAssertEqual(f.diameter * 1000, 40, accuracy: 0.4)
    }

    func testBallIsSphere() {
        var rng = LCG(s: 7)
        var pts: [SIMD3<Float>] = []
        for i in 0..<4000 {
            let z = Double(i) / 3999 * 2 - 1, a = Double(i) * 2.399963
            let r = (1 - z * z).squareRoot()
            let p = SIMD3(r * cos(a), z, r * sin(a)) * 0.03 + SIMD3(0.1, 0.05, -0.02)
            pts.append(SIMD3<Float>(p + SIMD3(rng.next(), rng.next(), rng.next()) * 0.0001))
        }
        let f = ScanMath.fitShape(pts)!
        XCTAssertEqual(f.kind, .sphere)
        XCTAssertEqual(f.radius * 1000, 30, accuracy: 0.3)
        XCTAssertEqual(f.center.x, 0.1, accuracy: 0.0005)
    }

    func testBoxIsIrregular() {
        var pts: [SIMD3<Float>] = []
        for i in 0..<30 { for j in 0..<30 {
            let a = Float(i) / 29 - 0.5, b = Float(j) / 29 - 0.5
            pts += [SIMD3(a * 0.06, b * 0.04, 0.01), SIMD3(a * 0.06, b * 0.04, -0.01),
                    SIMD3(a * 0.06, 0.02, b * 0.02), SIMD3(a * 0.06, -0.02, b * 0.02),
                    SIMD3(0.03, a * 0.04, b * 0.02), SIMD3(-0.03, a * 0.04, b * 0.02)]
        } }
        XCTAssertEqual(ScanMath.fitShape(pts)?.kind, .irregular)
    }

    func testFootprintRect() {
        // 40 × 10 rectangle rotated 30°, centred at (5, -3).
        let t = 30.0 * .pi / 180
        var pts: [SIMD2<Double>] = []
        for i in 0...20 { for j in 0...5 {
            let x = Double(i) * 2 - 20, y = Double(j) * 2 - 5
            pts.append(SIMD2(x * cos(t) - y * sin(t) + 5, x * sin(t) + y * cos(t) - 3))
        } }
        let r = ScanMath.footprintRect(pts)!
        XCTAssertEqual(r.long, 40, accuracy: 1e-6)
        XCTAssertEqual(r.short, 10, accuracy: 1e-6)
        XCTAssertEqual(r.center.x, 5, accuracy: 1e-6)
        XCTAssertEqual(r.center.y, -3, accuracy: 1e-6)
        XCTAssertEqual(abs(r.longDir.x * cos(t) + r.longDir.y * sin(t)), 1, accuracy: 1e-6)
    }

    func testRotationText() {
        XCTAssertEqual(Rotation.normalized(270), -90, accuracy: 1e-9)
        XCTAssertEqual(Rotation.normalized(-180), 180, accuracy: 1e-9)
        XCTAssertEqual(Rotation.normalized(540), 180, accuracy: 1e-9)
        XCTAssertEqual(Rotation.text(90.834), "+90.83°")
        XCTAssertEqual(Rotation.text(-12.5), "−12.50°")
        XCTAssertEqual(Rotation.text(360), "0.00°")
        XCTAssertEqual(Rotation.token(90.83), "Rot_pos90p83")
        XCTAssertEqual(Rotation.token(-45), "Rot_neg45p00")
        XCTAssertEqual(Rotation.token(-0.001), "Rot_pos0p00")
        XCTAssertEqual(Rotation.direction(10), "CCW")
        XCTAssertEqual(Rotation.direction(-10), "CW")
    }

    func testRulerTicks() {
        let t = RulerTicks.ticks(coveringMM: 152.3)
        XCTAssertEqual(t.count, 161) // 0…160 mm
        XCTAssertEqual(t.filter { $0.level == 2 }.count, 17)
        XCTAssertEqual(t[100].label, "10")
        XCTAssertEqual(t[105].level, 1)
        XCTAssertNil(t[7].label)
    }
}
