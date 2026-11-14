import XCTest
@testable import TidyCore

final class MapEditTests: XCTestCase {
    func testResizeKeepsOppositeSide() {
        let pl = RoomPlacement(x: 2, z: 1)
        let r = MapEdit.resize(pl, width: 4, depth: 3, edge: .right, dragX: 1, dragZ: 0)
        XCTAssertEqual(r.width, 5, accuracy: 1e-9)
        XCTAssertEqual(r.depth, 3, accuracy: 1e-9)
        // Left side stays at x = 0.
        XCTAssertEqual(r.placement.x - r.width / 2, 0, accuracy: 1e-9)
        let l = MapEdit.resize(pl, width: 4, depth: 3, edge: .left, dragX: 1, dragZ: 0)
        XCTAssertEqual(l.width, 3, accuracy: 1e-9)
        XCTAssertEqual(l.placement.x + l.width / 2, 4, accuracy: 1e-9, "right side stays at x = 4")
        let tiny = MapEdit.resize(pl, width: 4, depth: 3, edge: .front, dragX: 0, dragZ: -10)
        XCTAssertEqual(tiny.depth, MapEdit.minSize, accuracy: 1e-9)
    }

    func testResizeRotatedRoom() {
        // Turned 90°: the room's +x points along the place's +z.
        let pl = RoomPlacement(x: 0, z: 0, rotationDeg: 90)
        let r = MapEdit.resize(pl, width: 4, depth: 2, edge: .right, dragX: 0, dragZ: 1)
        XCTAssertEqual(r.width, 5, accuracy: 1e-6)
        XCTAssertEqual(r.placement.z, 0.5, accuracy: 1e-6)
        XCTAssertEqual(r.placement.x, 0, accuracy: 1e-6)
    }

    func testDrawAndContains() {
        let r = MapEdit.rect(from: (1, 1), to: (-2, 3))
        XCTAssertEqual(r.width, 3, accuracy: 1e-9)
        XCTAssertEqual(r.depth, 2, accuracy: 1e-9)
        XCTAssertEqual(r.placement.x, -0.5, accuracy: 1e-9)
        XCTAssertTrue(MapEdit.contains(r.placement, width: r.width, depth: r.depth, x: 0, z: 2))
        XCTAssertFalse(MapEdit.contains(r.placement, width: r.width, depth: r.depth, x: 2, z: 2))
        XCTAssertEqual(MapEdit.handle(.back, width: 3, depth: 2).z, -1)
    }

    func testSnapshotChanges() {
        let id = UUID(), gone = UUID()
        func state(_ id: UUID, _ name: String, x: Double?, w: Double = 3) -> MapRoomState {
            MapRoomState(id: id, name: name, needsName: false, tags: [], mapX: x, mapZ: 0, rotationDeg: 0, width: w, depth: 3,
                         height: 2.5, layout: nil, boundaryEdited: false)
        }
        let a = MapSnapshot(rooms: [state(id, "Room 2", x: 0), state(gone, "Hall", x: 4)])
        let b = MapSnapshot(rooms: [state(id, "Study", x: 1, w: 3.5), state(UUID(), "Porch", x: 9)])
        let c = b.changes(from: a)
        XCTAssertTrue(c.contains("Renamed Room 2 to Study"))
        XCTAssertTrue(c.contains("Moved Study"))
        XCTAssertTrue(c.contains("Changed the size of Study"))
        XCTAssertTrue(c.contains("Added Porch"))
        XCTAssertTrue(c.contains("Removed Hall"))
        XCTAssertEqual(MapSnapshot.decode(b.encoded()), b)
    }

    func testSplitBySections() {
        // Two 3 m rooms side by side in one scan: x from 0 to 3 and from 3 to 6.
        func wall(_ cx: Double, _ cz: Double, _ len: Double, _ yaw: Double) -> WorldBox {
            WorldBox(cx: cx, cy: 1.25, cz: cz, width: len, height: 2.5, depth: 0.1, yaw: yaw, label: "wall")
        }
        let walls = [wall(1.5, 0, 3, 0), wall(1.5, 3, 3, 0), wall(0, 1.5, 3, .pi / 2),
                     wall(4.5, 0, 3, 0), wall(4.5, 3, 3, 0), wall(6, 1.5, 3, .pi / 2)]
        let bed = WorldBox(cx: 4.5, cy: 0.3, cz: 1.5, width: 1.6, height: 0.6, depth: 2, yaw: 0, label: "bed")
        let layout = RoomLayout.from(walls: walls, objects: [bed])!
        let parts = SectionSplit.split(layout, centers: [(1.5, 1.5), (4.5, 1.5)])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1].layout.objects.first?.label, "bed")
        XCTAssertEqual(parts[0].layout.originX ?? 0, 1.5, accuracy: 0.1)
        XCTAssertEqual(parts[1].layout.originX ?? 0, 4.5, accuracy: 0.1)
        XCTAssertTrue(SectionSplit.split(layout, centers: [(1.5, 1.5)]).isEmpty)
    }
}
