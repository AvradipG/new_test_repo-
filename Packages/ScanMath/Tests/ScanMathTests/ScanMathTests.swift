import XCTest
@testable import ScanMath

final class ScanMathTests: XCTestCase {
    /// Axis-aligned box mesh with outward-facing triangles.
    func box(_ sx: Float, _ sy: Float, _ sz: Float) -> ([SIMD3<Float>], [UInt32]) {
        var p: [SIMD3<Float>] = []
        for i in 0..<8 {
            p.append(SIMD3((i & 1 == 0 ? -sx : sx) / 2, (i & 2 == 0 ? -sy : sy) / 2, (i & 4 == 0 ? -sz : sz) / 2))
        }
        let f: [UInt32] = [
            0, 2, 3, 0, 3, 1, // -z
            4, 5, 7, 4, 7, 6, // +z
            0, 1, 5, 0, 5, 4, // -y
            2, 6, 7, 2, 7, 3, // +y
            0, 4, 6, 0, 6, 2, // -x
            1, 3, 7, 1, 7, 5, // +x
        ]
        return (p, f)
    }

    func rotate(_ p: [SIMD3<Float>], z: Float, x: Float) -> [SIMD3<Float>] {
        p.map { v in
            let a = SIMD3(v.x * cos(z) - v.y * sin(z), v.x * sin(z) + v.y * cos(z), v.z)
            return SIMD3(a.x, a.y * cos(x) - a.z * sin(x), a.y * sin(x) + a.z * cos(x))
        }
    }

    func testBoxVolumeAndClosure() {
        let (p, f) = box(2, 3, 4)
        XCTAssertEqual(ScanMath.signedVolume(positions: p, indices: f), 24, accuracy: 1e-9)
        XCTAssertTrue(ScanMath.isClosed(indices: f))
        XCTAssertFalse(ScanMath.isClosed(indices: Array(f.dropLast(3))))
    }

    func testRotatedBoxAxes() {
        let (p, _) = box(0.04, 0.02, 0.01) // metres
        let r = rotate(p, z: 0.52, x: 0.35)
        let e = ScanMath.principalExtents(r)
        XCTAssertEqual(e.x, 0.04, accuracy: 1e-6)
        XCTAssertEqual(e.y, 0.02, accuracy: 1e-6)
        XCTAssertEqual(e.z, 0.01, accuracy: 1e-6)
    }

    func testSectionsAcrossEachAxisOfRotatedBox() {
        let (p, f) = box(0.02, 0.03, 0.04)
        let r = rotate(p, z: 0.7, x: -0.4)
        let frame = ScanMath.principalFrame(r)
        XCTAssertEqual(frame.extents.x, 0.04, accuracy: 1e-6)
        let expected = [0.02 * 0.03, 0.02 * 0.04, 0.03 * 0.04]
        for axis in 0..<3 {
            let s = ScanMath.crossSections(positions: r, indices: f, frame: frame, axis: axis, spacing: 0.005)
            XCTAssertFalse(s.isEmpty)
            for sec in s {
                XCTAssertEqual(sec.loops.count, 1)
                XCTAssertTrue(sec.openChains.isEmpty)
                XCTAssertEqual(sec.area, expected[axis], accuracy: 1e-9)
            }
        }
        let along = ScanMath.crossSections(positions: r, indices: f, frame: frame, axis: 0, spacing: 0.01)
        XCTAssertEqual(along.map { ($0.depth * 1000).rounded() }, [5, 15, 25, 35])
    }

    func testHollowSectionSubtractsHole() {
        let (outer, fo) = box(4, 4, 4)
        let (inner, fi) = box(2, 2, 2)
        let p = outer + inner
        let f = fo + fi.map { $0 + 8 }
        let frame = ScanMath.principalFrame(p)
        let s = ScanMath.crossSection(positions: p, indices: f, frame: frame, axis: 2, at: 0.1)
        XCTAssertEqual(s.loops.count, 2)
        XCTAssertEqual(s.area, 12, accuracy: 1e-9)
        XCTAssertEqual(s.perimeter, 16 + 8, accuracy: 1e-9)
    }

    func testFrameIsRightHanded() {
        let (p, _) = box(0.05, 0.03, 0.01)
        let fr = ScanMath.principalFrame(rotate(p, z: 2.1, x: 1.3))
        let a = fr.axes[0], b = fr.axes[1], c = fr.axes[2]
        let n = SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        XCTAssertEqual((n * c).sum(), 1, accuracy: 1e-9)
    }

    func testStatsInLabUnits() {
        let (p, f) = box(0.06, 0.04, 0.03) // 60 × 40 × 30 mm
        let s = ScanMath.stats(positions: rotate(p, z: 1.1, x: 0.2), indices: f)
        XCTAssertEqual(s.axisA, 60, accuracy: 1e-3)
        XCTAssertEqual(s.axisB, 40, accuracy: 1e-3)
        XCTAssertEqual(s.axisC, 30, accuracy: 1e-3)
        XCTAssertEqual(s.volumeCM3, 72, accuracy: 1e-3)
        XCTAssertEqual(s.triangleCount, 12)
        XCTAssertTrue(s.isClosed)
    }
}
