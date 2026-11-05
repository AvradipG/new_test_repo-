import XCTest
import simd
@testable import TidyCore

final class DepthMeasureTests: XCTestCase {
    /// A flat 0.4 m square object 1 m in front of the camera, a wall 2 m away behind it.
    func syntheticFrame() -> DepthFrame {
        let w = 64, h = 48
        var depth = [Float](repeating: 2, count: w * h)
        for j in 14..<34 { for i in 22..<42 { depth[j * w + i] = 1 } }
        return DepthFrame(width: w, height: h, depth: depth, confidence: nil, fx: 50, fy: 50, cx: 32, cy: 24,
                          cameraToWorld: matrix_identity_float4x4)
    }

    func testPortraitBoxMapsToLandscape() {
        let r = DepthMeasure.landscapeRect(PhotoBox(x: 0.1, y: 0.2, w: 0.3, h: 0.4))
        XCTAssertEqual(r.x0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r.x1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(r.y0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(r.y1, 0.9, accuracy: 1e-9)
    }

    func testMeasuresObjectAndDropsWall() throws {
        let f = syntheticFrame()
        // Claude's box, loose by a few pixels on every side, in portrait coordinates.
        let x0 = 20.0 / 64, x1 = 44.0 / 64, y0 = 12.0 / 48, y1 = 36.0 / 48
        let box = PhotoBox(x: 1 - y1, y: x0, w: y1 - y0, h: x1 - x0)
        let pts = DepthMeasure.points(for: box, in: f)
        XCTAssertFalse(pts.isEmpty)
        XCTAssertTrue(pts.allSatisfy { abs($0.z + 1) < 0.01 }, "wall points behind the object are removed")
        let m = try XCTUnwrap(DepthMeasure.measure(box, in: f))
        XCTAssertEqual(m.heightCM, 40, accuracy: 6)
        XCTAssertEqual(m.lengthCM, 40, accuracy: 6)
        XCTAssertLessThan(m.widthCM, 1, "only the front face is visible")
        XCTAssertEqual(m.centerZ, -1, accuracy: 0.01)
        XCTAssertEqual(DepthMeasure.label(length: m.lengthCM, width: m.widthCM, height: m.heightCM).hasSuffix("cm"), true)
    }

    func testWorldPoseIsApplied() throws {
        var f = syntheticFrame()
        f.cameraToWorld = simd_float4x4(translation: SIMD3<Float>(1, 1.5, 0))
        let box = PhotoBox(x: 1 - 34.0 / 48, y: 22.0 / 64, w: 20.0 / 48, h: 20.0 / 64)
        let m = try XCTUnwrap(DepthMeasure.measure(box, in: f))
        XCTAssertEqual(m.centerX, 1, accuracy: 0.05)
        XCTAssertEqual(m.centerY, 1.5, accuracy: 0.05)
    }

    func testLabel() {
        XCTAssertEqual(DepthMeasure.label(length: 30.2, width: 0.3, height: 12.6), "30 × 13 cm")
        XCTAssertEqual(DepthMeasure.label(length: 0, width: 0, height: 0), "")
    }
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    }
}
