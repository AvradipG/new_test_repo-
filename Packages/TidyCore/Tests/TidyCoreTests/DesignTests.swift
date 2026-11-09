import XCTest
@testable import TidyCore

final class DesignTests: XCTestCase {
    func piece(_ x: Double, _ z: Double, w: Double = 1, d: Double = 1, rot: Double = 0, kind: String = "dresser") -> DesignPiece {
        DesignPiece(kind: kind, name: kind, x: x, z: z, width: w, depth: d, height: 0.8, rotationDeg: rot)
    }

    func testOverlap() {
        XCTAssertTrue(DesignGeometry.overlaps(piece(0, 0), piece(0.5, 0)))
        XCTAssertFalse(DesignGeometry.overlaps(piece(0, 0), piece(1.2, 0)))
        // A 2 m long piece turned 90° reaches 1 m along z.
        XCTAssertTrue(DesignGeometry.overlaps(piece(0, 0, w: 2, d: 0.2, rot: 90), piece(0, 0.9, w: 0.5, d: 0.5)))
        XCTAssertFalse(DesignGeometry.overlaps(piece(0, 0), piece(0.3, 0, kind: "rug_large")), "rugs go under furniture")
        XCTAssertEqual(DesignGeometry.clashes([piece(0, 0), piece(0.5, 0), piece(3, 3)]).count, 2)
    }

    func testClampAndWallSnap() {
        let c = DesignGeometry.clamp(piece(1.9, 0, w: 1), width: 4, depth: 4)
        XCTAssertEqual(c.x, 1.5, accuracy: 1e-9, "the whole footprint stays inside")
        var art = DesignPiece(kind: "wall_art", name: "Art", x: 0.3, z: -1.7, y: 1.5, width: 0.9, depth: 0.04, height: 0.6, onWall: true)
        art = DesignGeometry.clamp(art, width: 4, depth: 4)
        XCTAssertEqual(art.z, -1.98, accuracy: 1e-9, "flat on the far wall")
        XCTAssertEqual(art.rotationDeg, 0)
        var side = art
        side.x = 1.9
        side.z = 0.2
        side = DesignGeometry.snapToWall(side, width: 4, depth: 4)
        XCTAssertEqual(side.rotationDeg, 270, "on the right wall, facing into the room")
        XCTAssertEqual(side.x, 1.98, accuracy: 1e-9)
    }

    func testWalkways() {
        let tight = DesignGeometry.tightGaps([piece(0, 0), piece(1.3, 0)])
        XCTAssertEqual(tight.count, 1, "30 cm between two pieces is too tight")
        XCTAssertTrue(DesignGeometry.tightGaps([piece(0, 0), piece(2, 0)]).isEmpty)
        XCTAssertEqual(DesignGeometry.openFloor([piece(0, 0, w: 2, d: 2)], width: 4, depth: 4), 0.75, accuracy: 1e-9)
    }

    func testDirectionsAndBagua() {
        // Far wall faces north: far = N, right = E.
        XCTAssertEqual(SpaceWisdom.direction(x: 0, z: -1, bearing: 0), "N")
        XCTAssertEqual(SpaceWisdom.direction(x: 1, z: 0, bearing: 0), "E")
        XCTAssertEqual(SpaceWisdom.direction(x: -1, z: 1, bearing: 0), "SW")
        XCTAssertEqual(SpaceWisdom.direction(x: 0, z: -1, bearing: 90), "E", "far wall faces east")
        XCTAssertNotNil(SpaceWisdom.vastu["NE"])
        // Entrance on the near wall: far-left is wealth, near-right is helpful people.
        XCTAssertEqual(SpaceWisdom.bagua(x: -1.5, z: -1.5, width: 4, depth: 4, entrance: .near), "Wealth")
        XCTAssertEqual(SpaceWisdom.bagua(x: 1.5, z: 1.5, width: 4, depth: 4, entrance: .near), "Helpful people & travel")
        XCTAssertEqual(SpaceWisdom.bagua(x: 0, z: 0, width: 4, depth: 4, entrance: .left), "Centre (balance)")
        // Entrance on the far wall: the map turns round, so the near-right corner becomes wealth.
        XCTAssertEqual(SpaceWisdom.bagua(x: 1.5, z: 1.5, width: 4, depth: 4, entrance: .far), "Wealth")
    }

    func testSchemaAndApply() throws {
        XCTAssertFalse(DesignAI.schemaObject().isEmpty)
        let pieces = [piece(0, 0, kind: "bed_double"), piece(1, 1, kind: "sink"), piece(-1, -1)]
        let json = """
        {"reply":"Try this","ranking":[],"proposal":{"title":"Calm","style":"Japandi","rationale":"Open centre",
         "moves":[{"piece_ref":"p1","x":5,"z":0,"rotation_deg":-90},{"piece_ref":"p2","x":0,"z":0,"rotation_deg":0}],
         "additions":[{"kind":"sofa_l","name":"","x":0,"z":0,"y":0,"rotation_deg":0,"width":0,"depth":0,"height":0,"why":"Seats"},
                      {"kind":"wall_art","name":"Print","x":0.2,"z":-1.5,"y":0,"rotation_deg":0,"width":0.9,"depth":0.04,"height":0.6,"why":"Calm"}],
         "removals":["p3"],"tips":["Keep the NE open"],"scores":{"flow":7,"light":6,"calm":8,"function":7,"overall":7}}}
        """
        let answer = try AIResults.decoder.decode(DesignAI.Answer.self, from: Data(json.utf8))
        let p = try XCTUnwrap(answer.proposal)
        let out = DesignAI.apply(p, to: pieces, width: 4, depth: 4)
        XCTAssertEqual(out.count, 4, "one removed, two added")
        let bed = try XCTUnwrap(out.first { $0.kind == "bed_double" })
        XCTAssertEqual(bed.rotationDeg, 270)
        XCTAssertLessThanOrEqual(bed.corners.map(\.0).max()!, 2.0000001, "moved, but kept inside the room")
        XCTAssertEqual(out.first { $0.kind == "sink" }?.x, 1, "fixed pieces don't move")
        let sofa = try XCTUnwrap(out.first { $0.kind == "sofa_l" })
        XCTAssertEqual(sofa.width, 2.6, "missing sizes come from the catalog")
        XCTAssertEqual(sofa.name, "L-shaped sofa")
        let art = try XCTUnwrap(out.first { $0.kind == "wall_art" })
        XCTAssertTrue(art.onWall)
        XCTAssertEqual(art.y, 1.5, "wall height defaults when the AI gives none")
        XCTAssertEqual(art.z, -1.98, accuracy: 1e-9)
        let ctx = DesignAI.roomContext(name: "Bedroom", width: 4, depth: 4, height: 2.5, bearing: 0, openings: [], pieces: out)
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: ctx))
    }
}
