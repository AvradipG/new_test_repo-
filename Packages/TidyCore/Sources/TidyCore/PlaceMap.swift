import Foundation

/// Where a room sits on its place's map: the position of its floor centre in the place's scan frame and how far
/// it is turned (degrees, clockwise seen from above). Used to correct the map by hand and to place rooms that were
/// scanned on their own or only photographed.
public struct RoomPlacement: Codable, Equatable, Sendable {
    public var x: Double
    public var z: Double
    public var rotationDeg: Double

    public init(x: Double, z: Double, rotationDeg: Double = 0) {
        self.x = x
        self.z = z
        self.rotationDeg = rotationDeg
    }

    /// A point in the room's own frame (metres from its floor centre) in the place frame.
    public func toPlace(x lx: Double, z lz: Double) -> (x: Double, z: Double) {
        let r = rotationDeg * .pi / 180, c = cos(r), s = sin(r)
        return (x + lx * c - lz * s, z + lx * s + lz * c)
    }

    /// The inverse: a place point in the room's own frame.
    public func toRoom(x px: Double, z pz: Double) -> (x: Double, z: Double) {
        let r = rotationDeg * .pi / 180, c = cos(r), s = sin(r)
        let dx = px - x, dz = pz - z
        return (dx * c + dz * s, -dx * s + dz * c)
    }

    /// Footprint corners of a width × depth room on the place map.
    public func corners(width: Double, depth: Double) -> [(Double, Double)] {
        [(-width / 2, -depth / 2), (width / 2, -depth / 2), (width / 2, depth / 2), (-width / 2, depth / 2)]
            .map { p in let q = toPlace(x: p.0, z: p.1); return (q.x, q.z) }
    }

    /// A free spot to the right of everything already on the map, for a room being added by hand.
    public static func nextFree(after footprints: [[(Double, Double)]], width: Double) -> RoomPlacement {
        let maxX = footprints.flatMap { $0 }.map(\.0).max() ?? -width / 2 - 0.5
        let zs = footprints.flatMap { $0 }.map(\.1)
        let midZ = zs.isEmpty ? 0 : (zs.min()! + zs.max()!) / 2
        return RoomPlacement(x: maxX + 0.5 + width / 2, z: midZ)
    }
}

/// Nested storage: a desk holds drawers, a drawer holds trays, and so on. Nodes are ids with optional parents.
public enum StorageTree {
    public struct Node: Equatable, Sendable {
        public var id: UUID
        public var parent: UUID?
        public var name: String
        public init(id: UUID, parent: UUID?, name: String) {
            self.id = id
            self.parent = parent
            self.name = name
        }
    }

    /// "Desk › Top drawer › Tray". Stops at a missing parent or a loop.
    public static func path(of id: UUID, in nodes: [Node], separator: String = " › ") -> String {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var names: [String] = []
        var seen = Set<UUID>()
        var cur: UUID? = id
        while let c = cur, let n = byID[c], !seen.contains(c) {
            seen.insert(c)
            names.insert(n.name, at: 0)
            cur = n.parent
        }
        return names.joined(separator: separator)
    }

    public static func children(of id: UUID?, in nodes: [Node]) -> [Node] {
        let ids = Set(nodes.map(\.id))
        return nodes.filter { n in id == nil ? (n.parent == nil || !ids.contains(n.parent!)) : n.parent == id }
    }

    /// The node and everything inside it.
    public static func subtree(of id: UUID, in nodes: [Node]) -> Set<UUID> {
        var out: Set<UUID> = [id]
        var frontier = [id]
        while let f = frontier.popLast() {
            for c in nodes where c.parent == f && !out.contains(c.id) {
                out.insert(c.id)
                frontier.append(c.id)
            }
        }
        return out
    }

    /// A spot can go inside another unless that would put it inside itself.
    public static func canMove(_ id: UUID, under parent: UUID?, in nodes: [Node]) -> Bool {
        guard let parent else { return true }
        return !subtree(of: id, in: nodes).contains(parent)
    }

    public static func depth(of id: UUID, in nodes: [Node]) -> Int {
        max(0, path(of: id, in: nodes, separator: "\u{1}").components(separatedBy: "\u{1}").count - 1)
    }
}

/// Kitchen planning: the work triangle and the five classic kitchen zones.
public enum Kitchen {
    public enum ZoneType: String, CaseIterable, Codable, Sendable {
        case consumables, nonConsumables, cleaning, preparation, cooking

        public var label: String {
            switch self {
            case .consumables: return "Food (pantry, fridge)"
            case .nonConsumables: return "Dishes, glasses, cutlery"
            case .cleaning: return "Cleaning (under the sink)"
            case .preparation: return "Preparation (knives, boards, bowls)"
            case .cooking: return "Cooking (pots, pans, spices)"
            }
        }

        public var hint: String {
            switch self {
            case .consumables: return "Near the fridge; oldest food at the front"
            case .nonConsumables: return "Near the dishwasher or sink, so unloading is one step"
            case .cleaning: return "Under or beside the sink"
            case .preparation: return "The longest free counter, between sink and stove"
            case .cooking: return "Beside the stove: pans below, spices and utensils within reach"
            }
        }

        public var symbol: String {
            switch self {
            case .consumables: return "carrot"
            case .nonConsumables: return "fork.knife"
            case .cleaning: return "sparkles"
            case .preparation: return "scissors"
            case .cooking: return "frying.pan"
            }
        }
    }

    public struct Triangle: Equatable, Sendable {
        public var fridgeToSink: Double
        public var sinkToStove: Double
        public var stoveToFridge: Double
        public var total: Double { fridgeToSink + sinkToStove + stoveToFridge }

        /// Common guideline: each leg 1.2–2.7 m and the total 4–7.9 m.
        public var verdict: String {
            let legs = [fridgeToSink, sinkToStove, stoveToFridge]
            if legs.contains(where: { $0 < 1.2 }) { return "Cramped: some stations are under 1.2 m apart" }
            if legs.contains(where: { $0 > 2.7 }) || total > 7.9 { return "Spread out: lots of walking between stations" }
            if total < 4 { return "Very compact" }
            return "Good working triangle"
        }

        public var isGood: Bool { verdict == "Good working triangle" }
    }

    /// Work triangle from the floor positions (metres) of fridge, sink and stove.
    public static func triangle(fridge: (Double, Double), sink: (Double, Double), stove: (Double, Double)) -> Triangle {
        func d(_ a: (Double, Double), _ b: (Double, Double)) -> Double { ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1)).squareRoot() }
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        return Triangle(fridgeToSink: r(d(fridge, sink)), sinkToStove: r(d(sink, stove)), stoveToFridge: r(d(stove, fridge)))
    }

    /// Food that runs out within `days` days (or already has), soonest first.
    public static func useSoon<T>(_ items: [(T, Date)], now: Date = Date(), days: Int = 3) -> [(T, Date)] {
        let limit = now.addingTimeInterval(Double(days) * 86_400)
        return items.filter { $0.1 <= limit }.sorted { $0.1 < $1.1 }
    }
}
