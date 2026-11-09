import Foundation

/// One movable piece in a room design: scanned furniture, something from the catalog, or an AI suggestion.
/// Positions are metres in the room's own frame: (0, 0) is the middle of the floor, x to the right, z towards the
/// viewer (the far wall is at z = -depth/2). Wall pieces also have a height `y` (their middle above the floor).
public struct DesignPiece: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: String
    public var name: String
    public var x: Double
    public var z: Double
    public var y: Double
    public var width: Double
    public var depth: Double
    public var height: Double
    public var rotationDeg: Double
    public var onWall: Bool
    /// "scanned", "added" or "ai".
    public var source: String
    /// The storage spot this piece is, when it came from the room's scan.
    public var zoneID: UUID?
    public var note: String?

    public init(id: UUID = UUID(), kind: String, name: String, x: Double, z: Double, y: Double = 0, width: Double, depth: Double,
                height: Double, rotationDeg: Double = 0, onWall: Bool = false, source: String = "added", zoneID: UUID? = nil,
                note: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.x = x
        self.z = z
        self.y = y
        self.width = width
        self.depth = depth
        self.height = height
        self.rotationDeg = rotationDeg
        self.onWall = onWall
        self.source = source
        self.zoneID = zoneID
        self.note = note
    }

    /// Footprint corners (x, z).
    public var corners: [(Double, Double)] {
        let r = rotationDeg * .pi / 180, c = cos(r), s = sin(r)
        let hw = width / 2, hd = depth / 2
        let local: [(Double, Double)] = [(-hw, -hd), (hw, -hd), (hw, hd), (-hw, hd)]
        return local.map { p in (x + p.0 * c - p.1 * s, z + p.0 * s + p.1 * c) }
    }
}

public struct CatalogItem: Equatable, Sendable {
    public var kind: String
    public var name: String
    public var width: Double
    public var depth: Double
    public var height: Double
    public var onWall: Bool
    public var group: String
    public var symbol: String
}

/// Furniture and decor to add to a design (typical sizes in metres; every piece can be resized).
public enum FurnitureCatalog {
    public static let items: [CatalogItem] = [
        .init(kind: "sofa_2", name: "Two-seat sofa", width: 1.6, depth: 0.9, height: 0.85, onWall: false, group: "Seating", symbol: "sofa"),
        .init(kind: "sofa_3", name: "Three-seat sofa", width: 2.2, depth: 0.95, height: 0.85, onWall: false, group: "Seating", symbol: "sofa"),
        .init(kind: "sofa_l", name: "L-shaped sofa", width: 2.6, depth: 1.7, height: 0.85, onWall: false, group: "Seating", symbol: "sofa.fill"),
        .init(kind: "armchair", name: "Armchair", width: 0.85, depth: 0.85, height: 0.9, onWall: false, group: "Seating", symbol: "chair.lounge"),
        .init(kind: "chair", name: "Chair", width: 0.5, depth: 0.55, height: 0.9, onWall: false, group: "Seating", symbol: "chair"),
        .init(kind: "office_chair", name: "Desk chair", width: 0.65, depth: 0.65, height: 1.1, onWall: false, group: "Seating", symbol: "chair"),
        .init(kind: "bench", name: "Bench", width: 1.2, depth: 0.4, height: 0.45, onWall: false, group: "Seating", symbol: "rectangle"),
        .init(kind: "floor_cushion", name: "Meditation cushion", width: 0.6, depth: 0.6, height: 0.2, onWall: false, group: "Seating", symbol: "circle.fill"),
        .init(kind: "bed_single", name: "Single bed", width: 0.95, depth: 2.0, height: 0.5, onWall: false, group: "Beds", symbol: "bed.double"),
        .init(kind: "bed_double", name: "Double bed", width: 1.4, depth: 2.0, height: 0.5, onWall: false, group: "Beds", symbol: "bed.double.fill"),
        .init(kind: "bed_queen", name: "Queen bed", width: 1.6, depth: 2.05, height: 0.5, onWall: false, group: "Beds", symbol: "bed.double.fill"),
        .init(kind: "bed_king", name: "King bed", width: 1.95, depth: 2.1, height: 0.5, onWall: false, group: "Beds", symbol: "bed.double.fill"),
        .init(kind: "nightstand", name: "Bedside table", width: 0.45, depth: 0.4, height: 0.55, onWall: false, group: "Beds", symbol: "square"),
        .init(kind: "desk", name: "Desk", width: 1.4, depth: 0.7, height: 0.75, onWall: false, group: "Work", symbol: "table.furniture"),
        .init(kind: "desk_l", name: "L-shaped desk", width: 1.6, depth: 1.4, height: 0.75, onWall: false, group: "Work", symbol: "table.furniture.fill"),
        .init(kind: "standing_desk", name: "Standing desk", width: 1.4, depth: 0.7, height: 1.1, onWall: false, group: "Work", symbol: "table.furniture"),
        .init(kind: "dining_4", name: "Dining table (4)", width: 1.2, depth: 0.8, height: 0.75, onWall: false, group: "Tables", symbol: "table.furniture"),
        .init(kind: "dining_6", name: "Dining table (6)", width: 1.8, depth: 0.9, height: 0.75, onWall: false, group: "Tables", symbol: "table.furniture"),
        .init(kind: "table_round", name: "Round table", width: 1.0, depth: 1.0, height: 0.75, onWall: false, group: "Tables", symbol: "circle"),
        .init(kind: "coffee_table", name: "Coffee table", width: 1.1, depth: 0.6, height: 0.42, onWall: false, group: "Tables", symbol: "rectangle"),
        .init(kind: "side_table", name: "Side table", width: 0.5, depth: 0.5, height: 0.55, onWall: false, group: "Tables", symbol: "square"),
        .init(kind: "bookshelf", name: "Bookshelf", width: 0.9, depth: 0.32, height: 1.9, onWall: false, group: "Storage", symbol: "books.vertical"),
        .init(kind: "dresser", name: "Chest of drawers", width: 1.0, depth: 0.5, height: 0.85, onWall: false, group: "Storage", symbol: "archivebox"),
        .init(kind: "wardrobe", name: "Wardrobe", width: 1.2, depth: 0.6, height: 2.0, onWall: false, group: "Storage", symbol: "cabinet"),
        .init(kind: "cube_storage", name: "Cube storage with bins", width: 1.1, depth: 0.4, height: 1.1, onWall: false, group: "Storage", symbol: "square.grid.3x3"),
        .init(kind: "shoe_rack", name: "Shoe rack", width: 0.8, depth: 0.3, height: 0.5, onWall: false, group: "Storage", symbol: "shoeprints.fill"),
        .init(kind: "toy_storage", name: "Toy storage", width: 0.9, depth: 0.4, height: 0.7, onWall: false, group: "Storage", symbol: "teddybear"),
        .init(kind: "hamper", name: "Laundry basket", width: 0.45, depth: 0.45, height: 0.6, onWall: false, group: "Storage", symbol: "basket"),
        .init(kind: "drop_zone", name: "Entry drop zone (keys, bag)", width: 0.8, depth: 0.35, height: 0.9, onWall: false, group: "Storage", symbol: "key"),
        .init(kind: "tv_stand", name: "TV stand", width: 1.6, depth: 0.4, height: 0.5, onWall: false, group: "Media", symbol: "tv"),
        .init(kind: "rug_small", name: "Rug (small)", width: 1.6, depth: 1.0, height: 0.01, onWall: false, group: "Decor", symbol: "rectangle.dashed"),
        .init(kind: "rug_large", name: "Rug (large)", width: 2.4, depth: 1.7, height: 0.01, onWall: false, group: "Decor", symbol: "rectangle.dashed"),
        .init(kind: "plant_floor", name: "Floor plant", width: 0.5, depth: 0.5, height: 1.4, onWall: false, group: "Decor", symbol: "leaf.fill"),
        .init(kind: "plant_small", name: "Small plant", width: 0.25, depth: 0.25, height: 0.4, onWall: false, group: "Decor", symbol: "leaf"),
        .init(kind: "floor_lamp", name: "Floor lamp", width: 0.4, depth: 0.4, height: 1.6, onWall: false, group: "Lighting", symbol: "lamp.floor"),
        .init(kind: "table_lamp", name: "Table lamp", width: 0.3, depth: 0.3, height: 0.5, onWall: false, group: "Lighting", symbol: "lamp.table"),
        .init(kind: "tv", name: "Wall TV", width: 1.25, depth: 0.06, height: 0.72, onWall: true, group: "Wall", symbol: "tv"),
        .init(kind: "wall_art", name: "Wall art", width: 0.9, depth: 0.04, height: 0.6, onWall: true, group: "Wall", symbol: "photo.artframe"),
        .init(kind: "gallery_wall", name: "Gallery wall", width: 1.6, depth: 0.04, height: 1.0, onWall: true, group: "Wall", symbol: "square.grid.2x2"),
        .init(kind: "mirror", name: "Mirror", width: 0.6, depth: 0.04, height: 1.2, onWall: true, group: "Wall", symbol: "rectangle.portrait"),
        .init(kind: "wall_shelf", name: "Wall shelf", width: 1.0, depth: 0.22, height: 0.05, onWall: true, group: "Wall", symbol: "minus.rectangle"),
        .init(kind: "pegboard", name: "Pegboard organizer", width: 0.9, depth: 0.03, height: 0.6, onWall: true, group: "Wall", symbol: "circle.grid.3x3"),
        .init(kind: "wall_hooks", name: "Wall hooks", width: 0.6, depth: 0.08, height: 0.1, onWall: true, group: "Wall", symbol: "line.3.horizontal"),
        .init(kind: "curtains", name: "Curtains", width: 1.8, depth: 0.1, height: 2.2, onWall: true, group: "Wall", symbol: "curtains.closed"),
        .init(kind: "wall_clock", name: "Wall clock", width: 0.35, depth: 0.05, height: 0.35, onWall: true, group: "Wall", symbol: "clock"),
    ]

    public static func item(_ kind: String) -> CatalogItem? { items.first { $0.kind == kind } }
    public static var kinds: [String] { items.map(\.kind) + ["custom"] }

    /// Default heights for wall pieces (middle above the floor).
    public static func wallHeight(_ kind: String) -> Double {
        switch kind {
        case "tv": return 1.2
        case "curtains": return 1.3
        case "mirror": return 1.3
        case "wall_hooks": return 1.6
        case "wall_clock": return 1.9
        default: return 1.5
        }
    }

    /// A piece for RoomPlan's furniture categories.
    public static func scannedKind(_ label: String) -> (kind: String, name: String) {
        switch label.lowercased() {
        case "bed": return ("bed_double", "Bed")
        case "sofa": return ("sofa_3", "Sofa")
        case "chair": return ("chair", "Chair")
        case "table": return ("dining_4", "Table")
        case "storage": return ("dresser", "Storage")
        case "television": return ("tv_stand", "TV")
        case "refrigerator": return ("fridge", "Fridge")
        case "stove", "oven": return ("stove", "Stove")
        case "sink": return ("sink", "Sink")
        case "washerdryer": return ("washer", "Washer / dryer")
        case "dishwasher": return ("dishwasher", "Dishwasher")
        case "toilet": return ("toilet", "Toilet")
        case "bathtub": return ("bathtub", "Bathtub")
        case "fireplace": return ("fireplace", "Fireplace")
        case "stairs": return ("stairs", "Stairs")
        default: return ("custom", label.capitalized)
        }
    }

    /// Built in: moving these isn't realistic, so the editor marks them.
    public static func isFixed(_ kind: String) -> Bool {
        ["sink", "toilet", "bathtub", "fireplace", "stairs", "stove", "dishwasher"].contains(kind)
    }
}

/// Geometry checks for a design inside a rectangular room (width × depth, centred on the origin).
public enum DesignGeometry {
    /// Do two footprints overlap (separating-axis test on the rotated rectangles)? Rugs and wall pieces never clash.
    public static func overlaps(_ a: DesignPiece, _ b: DesignPiece) -> Bool {
        if a.onWall || b.onWall || a.kind.hasPrefix("rug") || b.kind.hasPrefix("rug") { return false }
        let pa = a.corners, pb = b.corners
        for poly in [pa, pb] {
            for i in 0..<4 {
                let e = (poly[(i + 1) % 4].0 - poly[i].0, poly[(i + 1) % 4].1 - poly[i].1)
                let axis = (-e.1, e.0)
                let projA = pa.map { $0.0 * axis.0 + $0.1 * axis.1 }, projB = pb.map { $0.0 * axis.0 + $0.1 * axis.1 }
                if projA.max()! <= projB.min()! + 1e-6 || projB.max()! <= projA.min()! + 1e-6 { return false }
            }
        }
        return true
    }

    /// Ids of pieces that overlap another piece.
    public static func clashes(_ pieces: [DesignPiece]) -> Set<UUID> {
        var out = Set<UUID>()
        for i in pieces.indices { for j in pieces.indices where j > i {
            if overlaps(pieces[i], pieces[j]) { out.insert(pieces[i].id); out.insert(pieces[j].id) }
        } }
        return out
    }

    /// Keeps a floor piece inside the room (whole footprint).
    public static func clamp(_ p: DesignPiece, width: Double, depth: Double) -> DesignPiece {
        if p.onWall { return snapToWall(p, width: width, depth: depth) }
        var q = p
        let xs = p.corners.map(\.0), zs = p.corners.map(\.1)
        let hw = width / 2, hd = depth / 2
        if xs.min()! < -hw { q.x += -hw - xs.min()! }
        if xs.max()! > hw { q.x -= xs.max()! - hw }
        if zs.min()! < -hd { q.z += -hd - zs.min()! }
        if zs.max()! > hd { q.z -= zs.max()! - hd }
        return q
    }

    /// Puts a wall piece flat against the nearest wall, facing into the room, and slides it along that wall.
    public static func snapToWall(_ p: DesignPiece, width: Double, depth: Double) -> DesignPiece {
        var q = p
        let hw = width / 2, hd = depth / 2
        let d = [("far", p.z + hd), ("near", hd - p.z), ("left", p.x + hw), ("right", hw - p.x)].min { $0.1 < $1.1 }!.0
        let half = p.width / 2, t = p.depth / 2
        switch d {
        case "far": q.z = -hd + t; q.rotationDeg = 0; q.x = min(max(p.x, -hw + half), hw - half)
        case "near": q.z = hd - t; q.rotationDeg = 180; q.x = min(max(p.x, -hw + half), hw - half)
        case "left": q.x = -hw + t; q.rotationDeg = 90; q.z = min(max(p.z, -hd + half), hd - half)
        default: q.x = hw - t; q.rotationDeg = 270; q.z = min(max(p.z, -hd + half), hd - half)
        }
        return q
    }

    /// Share of the floor not covered by furniture (rugs and wall pieces excluded), 0...1.
    public static func openFloor(_ pieces: [DesignPiece], width: Double, depth: Double) -> Double {
        let used = pieces.filter { !$0.onWall && !$0.kind.hasPrefix("rug") }.reduce(0) { $0 + $1.width * $1.depth }
        return max(0, 1 - used / max(width * depth, 0.01))
    }

    /// Pairs of floor pieces closer than `walkway` metres (but not overlapping): too tight to walk between.
    public static func tightGaps(_ pieces: [DesignPiece], walkway: Double = 0.6) -> [(UUID, UUID)] {
        let floor = pieces.filter { !$0.onWall && !$0.kind.hasPrefix("rug") && $0.height > 0.3 }
        var out: [(UUID, UUID)] = []
        for i in floor.indices { for j in floor.indices where j > i {
            let a = floor[i], b = floor[j]
            var gap = Double.infinity
            for p in a.corners { gap = min(gap, distance(p, to: b)) }
            for p in b.corners { gap = min(gap, distance(p, to: a)) }
            if gap > 0.01 && gap < walkway && !overlaps(a, b) { out.append((a.id, b.id)) }
        } }
        return out
    }

    /// Distance from a point to a piece's footprint edges.
    static func distance(_ p: (Double, Double), to piece: DesignPiece) -> Double {
        let c = piece.corners
        var best = Double.infinity
        for i in 0..<4 {
            let a = c[i], b = c[(i + 1) % 4]
            let ab = (b.0 - a.0, b.1 - a.1), ap = (p.0 - a.0, p.1 - a.1)
            let t = max(0, min(1, (ap.0 * ab.0 + ap.1 * ab.1) / max(ab.0 * ab.0 + ab.1 * ab.1, 1e-9)))
            let q = (a.0 + ab.0 * t, a.1 + ab.1 * t)
            best = min(best, ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1)).squareRoot())
        }
        return best
    }
}

/// Feng Shui and Vastu Shastra helpers: which compass direction or bagua area a spot of the room is in.
public enum SpaceWisdom {
    /// Compass direction of a spot seen from the middle of the room. `bearing` is the compass bearing of the far
    /// wall (the room's −Z direction).
    public static func direction(x: Double, z: Double, bearing: Double) -> String {
        if abs(x) < 1e-9 && abs(z) < 1e-9 { return "Centre" }
        let angle = atan2(x, -z) * 180 / .pi
        return GeoMath.compassName(bearing + angle)
    }

    /// What Vastu Shastra traditionally recommends for each direction.
    public static let vastu: [String: String] = [
        "N": "Kubera, wealth: keep open and light; cash box or locker facing north",
        "NE": "Ishanya, the most sacred: keep clear, clean and light; prayer, meditation, water",
        "E": "Indra, health and new starts: windows, morning light, study",
        "SE": "Agni, fire: kitchen, stove, electronics",
        "S": "Yama: heavy furniture, storage; sleep with the head to the south",
        "SW": "Nairutya, stability: master bed, heavy wardrobes, safe",
        "W": "Varuna: dining, study, children's room, bookshelves",
        "NW": "Vayu, movement: guest room, laundry, things that come and go",
        "Centre": "Brahmasthan: keep the middle of the room open, nothing heavy",
    ]

    public enum Entrance: String, CaseIterable, Codable, Sendable { case near, far, left, right }

    /// Bagua area (Feng Shui, western/BTB method: the map is laid with the entrance wall at the bottom).
    public static func bagua(x: Double, z: Double, width: Double, depth: Double, entrance: Entrance) -> String {
        // Turn the room so the entrance wall is "near" (bottom of the plan).
        var u = x / width + 0.5, v = z / depth + 0.5   // u: left→right, v: far→near
        switch entrance {
        case .near: break
        case .far: (u, v) = (1 - u, 1 - v)
        case .left: (u, v) = (1 - v, u)
        case .right: (u, v) = (v, 1 - u)
        }
        let col = min(2, max(0, Int(u * 3))), row = min(2, max(0, Int(v * 3)))
        let grid = [["Wealth", "Fame & reputation", "Love & relationships"],
                    ["Family & health", "Centre (balance)", "Creativity & children"],
                    ["Knowledge & self-care", "Career & path", "Helpful people & travel"]]
        return grid[row][col]
    }

    /// Short guidance shared with the AI designer.
    public static let principles = """
    Feng Shui: commanding position (bed, desk and sofa see the door without being in line with it; solid wall behind \
    the head or back), clear paths for chi to flow (no furniture blocking doors or windows, walkways at least 60-90 cm), \
    balance of the five elements (wood, fire, earth, metal, water), no mirror facing the bed, declutter the entrance, \
    bagua areas laid from the entrance wall.
    Vastu Shastra: keep north-east open, light and clean; heavy furniture and the master bed in the south-west; head \
    to the south or east when sleeping; kitchen and electronics in the south-east; keep the centre open; study facing \
    east or north.
    Calm for ADHD: one clear home for every category, open surfaces kept few, closed storage near where things are \
    used, a landing spot by the door for keys and bags, visual quiet (fewer, larger decor pieces), good task lighting.
    """
}
