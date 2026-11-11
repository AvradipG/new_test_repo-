import XCTest
import simd
@testable import ScanMath

/// 3.12: pieces fitted back into the original cylinder. The synthetic case follows the real piece set it was made
/// for: a disc (Ø 38 × 15 mm) with a quarter cut out, lying flat on a table (its underside not scanned), and the
/// quarter broken in two along an uneven break; the two parts lie elsewhere on the table, turned any way.
final class CylinderFitTests: XCTestCase {
    let R = 0.019
    let L = 0.015
    let h = 0.001

    /// Angle (radians) of the break between the two parts of the quarter, at radius r and height y.
    func breakAngle(_ r: Double, _ y: Double) -> Double {
        let w1: Double = 7 * sin(r * 310 + 0.4) * cos(y * 380)
        let w2: Double = 4 * sin(y * 650 + r * 170)
        let deg: Double = 135 + w1 + w2
        return deg * .pi / 180
    }

    /// Samples of the part of the disc between angles lo(r, y) and hi(r, y) (radians), with outward normals.
    func sector(lo: @escaping (Double, Double) -> Double, hi: @escaping (Double, Double) -> Double, bottom: Bool = true)
        -> (points: [SIMD3<Double>], normals: [SIMD3<Double>]) {
        var P: [SIMD3<Double>] = [], N: [SIMD3<Double>] = []
        func inside(_ th: Double, _ r: Double, _ y: Double) -> Bool {
            var t = th
            let a = lo(r, y)
            while t < a { t += 2 * .pi }
            while t > a + 2 * .pi { t -= 2 * .pi }
            return t <= hi(r, y)
        }
        // Curved outside.
        let around = Int(2 * .pi * R / h)
        for k in 0..<around {
            let th = 2 * .pi * Double(k) / Double(around)
            var y = h / 2
            while y < L {
                if inside(th, R, y) {
                    P.append(SIMD3(R * cos(th), y, R * sin(th)))
                    N.append(SIMD3(cos(th), 0, sin(th)))
                }
                y += h
            }
        }
        // Flat ends.
        var r = h / 2
        while r < R {
            let m = Swift.max(6, Int(2 * .pi * r / h))
            for k in 0..<m {
                let th = 2 * .pi * Double(k) / Double(m)
                if inside(th, r, L) {
                    P.append(SIMD3(r * cos(th), L, r * sin(th)))
                    N.append(SIMD3(0, 1, 0))
                }
                if bottom && inside(th, r, 0) {
                    P.append(SIMD3(r * cos(th), 0, r * sin(th)))
                    N.append(SIMD3(0, -1, 0))
                }
            }
            r += h
        }
        // The two side faces (flat cuts or breaks): surfaces θ = f(r, y).
        for (f, sign) in [(lo, -1.0), (hi, 1.0)] {
            var r = h / 2
            while r < R {
                var y = h / 2
                while y < L {
                    let th = f(r, y)
                    let p = SIMD3(r * cos(th), y, r * sin(th))
                    let e = 1e-6
                    let tr: Double = (f(r + e, y) - f(r - e, y)) / (2 * e)
                    let ty: Double = (f(r, y + e) - f(r, y - e)) / (2 * e)
                    let c: Double = cos(th), s: Double = sin(th)
                    let rs: Double = r * s, rc: Double = r * c
                    let dr = SIMD3<Double>(c - rs * tr, 0, s + rc * tr)
                    let dy = SIMD3<Double>(-rs * ty, 1, rc * ty)
                    var n = simd_normalize(simd_cross(dr, dy))
                    let eTheta = SIMD3(-sin(th), 0, cos(th))
                    if simd_dot(n, eTheta) * sign < 0 { n = -n }
                    P.append(p)
                    N.append(n)
                    y += h
                }
                r += h
            }
        }
        return (P, N)
    }

    func moved(_ s: (points: [SIMD3<Double>], normals: [SIMD3<Double>]), by G: Pose) -> (points: [SIMD3<Double>], normals: [SIMD3<Double>]) {
        (s.points.map { G.apply($0) }, s.normals.map { G.rotate($0) })
    }

    /// The disc with the quarter (90°–180°) cut out, lying on the table at y = 0, underside not seen.
    func mainPiece() -> Piece {
        let s = sector(lo: { _, _ in .pi }, hi: { _, _ in 2.5 * .pi }, bottom: false)
        return Piece(id: 1, points: s.points, normals: s.normals, spacing: h)
    }

    func testSmallestEigenvector() {
        // diag(3, 1, 2) turned: the eigenvector of 1 is the turned y axis.
        let Q = Pose.rotation(axis: SIMD3(0.4, -0.2, 0.9), degrees: 37)
        let D = simd_double3x3(columns: (SIMD3(3, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 2)))
        let M = Q * D * Q.transpose
        let m: [[Double]] = (0..<3).map { r in (0..<3).map { c in M[c][r] } }
        let v = CylinderFinder.smallestEigenvector(m)
        XCTAssertGreaterThan(abs(simd_dot(v, Q * SIMD3(0, 1, 0))), 0.999999)
    }

    func testCylinderFoundOnTheMainPiece() {
        let A = mainPiece()
        let patch = try! XCTUnwrap(CylinderFinder.fit(A, radius: nil))
        XCTAssertEqual(patch.radius, R, accuracy: 0.0003)
        XCTAssertGreaterThan(abs(patch.axis.y), 0.999)
        XCTAssertGreaterThanOrEqual(patch.arcDegrees, 250)
        let c = CoreCylinder.fit(anchor: A, patch: patch, radiusGiven: false, length: nil, floorY: 0, volumeNeeded: A.volume)
        XCTAssertEqual(c.t1, L, accuracy: 0.0006)
        XCTAssertEqual(c.t0, 0, accuracy: 0.0012)
        XCTAssertTrue(c.topFound)
        XCTAssertTrue(c.note.contains("table"), c.note)
        XCTAssertLessThan(simd_length(c.base - SIMD3(0, 0, 0)), 0.0005)
        // Points inside and outside.
        XCTAssertLessThan(c.outside(SIMD3(0.01, 0.007, 0)), 0)
        XCTAssertGreaterThan(c.outside(SIMD3(0.025, 0.007, 0)), 0.005)
        // With the diameter given, only patches of that radius count.
        XCTAssertNil(CylinderFinder.fit(A, radius: 0.0125))
    }

    func testBrokenQuarterGoesBackIntoTheCylinder() {
        let A = mainPiece()
        let q1 = sector(lo: { _, _ in .pi / 2 }, hi: { r, y in self.breakAngle(r, y) })
        let q2 = sector(lo: { r, y in self.breakAngle(r, y) }, hi: { _, _ in .pi })
        // Lying elsewhere, turned.
        let G1 = Pose(R: Pose.rotation(axis: SIMD3(1, 0.3, -0.2), degrees: 95), t: SIMD3(0.05, 0.004, -0.03))
        let G2 = Pose(R: Pose.rotation(axis: SIMD3(-0.2, 1, 0.5), degrees: 160), t: SIMD3(-0.06, 0.006, 0.04))
        let m1 = moved(q1, by: G1), m2 = moved(q2, by: G2)
        let B = Piece(id: 2, points: m1.points, normals: m1.normals, spacing: h)
        let C = Piece(id: 3, points: m2.points, normals: m2.normals, spacing: h)
        let patch = try! XCTUnwrap(CylinderFinder.fit(A, radius: nil))
        let cyl = CoreCylinder.fit(anchor: A, patch: patch, radiusGiven: false, length: nil, floorY: 0, volumeNeeded: A.volume + B.volume + C.volume)
        let result = MouldAssembler.assemble([A, B, C], anchor: 1, cylinder: cyl)
        XCTAssertEqual(result.method, "cylinder")
        XCTAssertEqual(result.placed.count, 3, "unplaced: \(result.unplaced)")
        // The quarter's two parts end up where they belong relative to each other, and the quarter as a whole in
        // the notch. A quarter with flat cut faces looks the same turned over about its middle line (top and
        // bottom, and the two cut faces, swap), so that is the one other right answer: the scan can't tell them
        // apart.
        let W1 = try! XCTUnwrap(result.placed[2]?.pose), W2 = try! XCTUnwrap(result.placed[3]?.pose)
        let S1 = W1.compose(G1), S2 = W2.compose(G2)   // each part's move from where it was made
        let together = Pose.displacement(S1, S2, points: q1.points)
        XCTAssertLessThan(together, 0.0015, "the two parts are \(together * 1000) mm apart from fitting each other")
        let mid = SIMD3(cos(0.75 * Double.pi), 0, sin(0.75 * Double.pi))
        let flip = Pose(R: Pose.rotation(axis: mid, degrees: 180), t: SIMD3(0, L, 0))
        let asMade = Pose.displacement(S1, .identity, points: q1.points)
        let turned = Pose.displacement(S1, flip, points: q1.points)
        XCTAssertLessThan(Swift.min(asMade, turned), 0.0015, "quarter \(asMade * 1000) mm from where it was made, \(turned * 1000) mm from it turned over")
        for id in [2, 3] {
            XCTAssertGreaterThan(result.placed[id]?.gain ?? 0, 0.5)
            XCTAssertLessThan(result.placed[id]?.penetration ?? 1, 0.03)
        }
        XCTAssertTrue(result.placed[2]?.neighbours.contains(3) ?? false)
    }

    func testAPieceThatIsTooBigIsNotForcedIn() {
        // A whole second disc doesn't fit in the quarter that is free.
        let A = mainPiece()
        let whole = sector(lo: { _, _ in 0 }, hi: { _, _ in 2 * .pi })
        let m = moved(whole, by: Pose(R: Pose.rotation(axis: SIMD3(1, 0, 0), degrees: 90), t: SIMD3(0.07, 0.02, 0)))
        let B = Piece(id: 2, points: m.points, normals: m.normals, spacing: h)
        let patch = try! XCTUnwrap(CylinderFinder.fit(A, radius: nil))
        let cyl = CoreCylinder.fit(anchor: A, patch: patch, radiusGiven: false, length: nil, floorY: 0, volumeNeeded: A.volume)
        var params = MouldParams()
        params.directions = 8
        params.spins = 4
        let result = MouldAssembler.assemble([A, B], anchor: 1, cylinder: cyl, params: params)
        XCTAssertNil(result.placed[2])
        XCTAssertNotNil(result.unplaced[2])
    }

    func testCylinderWithoutDiameterStaysACylinder() {
        // The target as the app stores it when only "Cylinder" was chosen.
        let t = TargetShape(kind: .cylinder, aMM: nil, bMM: nil)
        let data = try! JSONEncoder().encode(t)
        let back = try! JSONDecoder().decode(TargetShape.self, from: data)
        XCTAssertEqual(back.kind, .cylinder)
        XCTAssertNil(back.aMM)
    }
}
