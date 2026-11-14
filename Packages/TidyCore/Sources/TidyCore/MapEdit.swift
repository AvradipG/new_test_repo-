import Foundation

/// Editing the place map by hand: room boundaries, drawing new rooms, and saved versions of the whole map.
public enum MapEdit {
    /// The four sides of a room on the map, in the room's own frame: left = −x, right = +x, back = −z, front = +z.
    public enum Edge: String, CaseIterable, Sendable {
        case left, right, back, front
    }

    public static let minSize = 0.5

    /// Rounds to whole centimetres × `step` so hand edits stay tidy numbers.
    public static func snap(_ v: Double, step: Double = 0.05) -> Double { (v / step).rounded() * step }

    /// Middle of one side, in the room's own frame.
    public static func handle(_ edge: Edge, width: Double, depth: Double) -> (x: Double, z: Double) {
        switch edge {
        case .left: return (-width / 2, 0)
        case .right: return (width / 2, 0)
        case .back: return (0, -depth / 2)
        case .front: return (0, depth / 2)
        }
    }

    /// Moves one side of a room by a drag (metres, place frame). The opposite side stays where it is.
    public static func resize(_ pl: RoomPlacement, width: Double, depth: Double, edge: Edge,
                              dragX: Double, dragZ: Double) -> (placement: RoomPlacement, width: Double, depth: Double) {
        let r = pl.rotationDeg * .pi / 180, c = cos(r), s = sin(r)
        let lx = dragX * c + dragZ * s, lz = -dragX * s + dragZ * c
        var w = width, d = depth, sx = 0.0, sz = 0.0
        switch edge {
        case .right:
            w = max(minSize, snap(width + lx))
            sx = (w - width) / 2
        case .left:
            w = max(minSize, snap(width - lx))
            sx = -(w - width) / 2
        case .front:
            d = max(minSize, snap(depth + lz))
            sz = (d - depth) / 2
        case .back:
            d = max(minSize, snap(depth - lz))
            sz = -(d - depth) / 2
        }
        let q = pl.toPlace(x: sx, z: sz)
        return (RoomPlacement(x: q.x, z: q.z, rotationDeg: pl.rotationDeg), w, d)
    }

    /// A new room drawn by dragging a finger from `a` to `b` (place frame).
    public static func rect(from a: (Double, Double), to b: (Double, Double)) -> (placement: RoomPlacement, width: Double, depth: Double) {
        let w = max(minSize, snap(abs(b.0 - a.0))), d = max(minSize, snap(abs(b.1 - a.1)))
        return (RoomPlacement(x: (a.0 + b.0) / 2, z: (a.1 + b.1) / 2), w, d)
    }

    /// True when the point (place frame) is inside the room's footprint.
    public static func contains(_ pl: RoomPlacement, width: Double, depth: Double, x: Double, z: Double) -> Bool {
        let p = pl.toRoom(x: x, z: z)
        return abs(p.x) <= width / 2 && abs(p.z) <= depth / 2
    }
}

/// One room as it is on the map, for undo and saved map versions.
public struct MapRoomState: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var needsName: Bool
    public var tags: [String]
    public var mapX: Double?
    public var mapZ: Double?
    public var rotationDeg: Double
    public var width: Double
    public var depth: Double
    public var height: Double
    public var layout: Data?
    public var boundaryEdited: Bool

    public init(id: UUID, name: String, needsName: Bool, tags: [String], mapX: Double?, mapZ: Double?, rotationDeg: Double,
                width: Double, depth: Double, height: Double, layout: Data?, boundaryEdited: Bool) {
        self.id = id
        self.name = name
        self.needsName = needsName
        self.tags = tags
        self.mapX = mapX
        self.mapZ = mapZ
        self.rotationDeg = rotationDeg
        self.width = width
        self.depth = depth
        self.height = height
        self.layout = layout
        self.boundaryEdited = boundaryEdited
    }
}

/// The whole map at one moment.
public struct MapSnapshot: Codable, Equatable, Sendable {
    public var rooms: [MapRoomState]

    public init(rooms: [MapRoomState]) { self.rooms = rooms }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data?) -> MapSnapshot? {
        data.flatMap { try? JSONDecoder().decode(MapSnapshot.self, from: $0) }
    }

    /// Plain words for what changed from `old` to this one ("Moved Kitchen", "Renamed Room 2 to Study").
    public func changes(from old: MapSnapshot) -> [String] {
        let before = Dictionary(old.rooms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        func near(_ a: Double?, _ b: Double?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return abs(x - y) < 0.02
            default: return false
            }
        }
        for r in rooms {
            guard let o = before[r.id] else {
                out.append("Added \(r.name)")
                continue
            }
            if o.name != r.name { out.append("Renamed \(o.name) to \(r.name)") }
            if !near(o.mapX, r.mapX) || !near(o.mapZ, r.mapZ) { out.append(r.mapX == nil ? "Took \(r.name) off the map" : "Moved \(r.name)") }
            if abs(o.rotationDeg - r.rotationDeg) > 0.5 { out.append("Turned \(r.name)") }
            if abs(o.width - r.width) > 0.02 || abs(o.depth - r.depth) > 0.02 { out.append("Changed the size of \(r.name)") }
            if o.layout != r.layout { out.append("Changed the walls of \(r.name)") }
        }
        let now = Set(rooms.map(\.id))
        for o in old.rooms where !now.contains(o.id) { out.append("Removed \(o.name)") }
        return out
    }
}

extension SectionSplit {
    /// Splits one scanned room into one layout per RoomPlan section (centres in the scan's own frame): every wall,
    /// door, window and piece of furniture goes to the nearest section. Empty when there is nothing to split.
    public static func split(_ layout: RoomLayout, centers: [(Double, Double)]) -> [(section: Int, layout: RoomLayout)] {
        guard centers.count > 1 else { return [] }
        let ox = layout.originX ?? 0, oz = layout.originZ ?? 0, oy = layout.floorY ?? 0
        func world(_ b: WorldBox) -> WorldBox {
            var w = b
            w.cx += ox
            w.cz += oz
            w.cy += oy
            return w
        }
        let walls = layout.walls.map(world), objects = layout.objects.map(world), openings = (layout.openings ?? []).map(world)
        let wi = assign(walls.map { ($0.cx, $0.cz) }, centers: centers)
        let oi = assign(objects.map { ($0.cx, $0.cz) }, centers: centers)
        let pi = assign(openings.map { ($0.cx, $0.cz) }, centers: centers)
        var out: [(section: Int, layout: RoomLayout)] = []
        for s in centers.indices {
            let w = walls.indices.filter { wi[$0] == s }.map { walls[$0] }
            let o = objects.indices.filter { oi[$0] == s }.map { objects[$0] }
            let p = openings.indices.filter { pi[$0] == s }.map { openings[$0] }
            guard w.count >= 2 || !o.isEmpty, let l = RoomLayout.from(walls: w, objects: o, openings: p) else { continue }
            out.append((section: s, layout: l))
        }
        return out.count > 1 ? out : []
    }
}
