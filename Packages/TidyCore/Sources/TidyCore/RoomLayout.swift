import Foundation

/// A box in the room scan's world space (metres, y up), rotated by `yaw` radians about the vertical axis.
public struct WorldBox: Codable, Equatable, Sendable {
    public var cx: Double
    public var cy: Double
    public var cz: Double
    public var width: Double
    public var height: Double
    public var depth: Double
    public var yaw: Double
    public var label: String

    public init(cx: Double, cy: Double, cz: Double, width: Double, height: Double, depth: Double, yaw: Double, label: String) {
        self.cx = cx
        self.cy = cy
        self.cz = cz
        self.width = width
        self.height = height
        self.depth = depth
        self.yaw = yaw
        self.label = label
    }

    /// The four footprint corners (x, z).
    public var corners: [(Double, Double)] {
        let c = cos(yaw), s = sin(yaw)
        let hw = width / 2, hd = depth / 2
        let local: [(Double, Double)] = [(-hw, -hd), (hw, -hd), (hw, hd), (-hw, hd)]
        return local.map { p in
            let (dx, dz) = p
            return (cx + dx * c + dz * s, cz - dx * s + dz * c)
        }
    }
}

/// Room geometry from an Apple RoomPlan scan, re-centred so the floor's middle is the origin.
public struct RoomLayout: Codable, Equatable, Sendable {
    public var walls: [WorldBox]
    public var objects: [WorldBox]
    public var widthM: Double
    public var depthM: Double
    public var heightM: Double
    /// Where this room's local origin (floor centre) sits in the scan it came from (added for whole-place scans;
    /// nil in layouts saved before). Rooms of one whole-place scan share that frame.
    public var originX: Double?
    public var originZ: Double?
    public var floorY: Double?

    /// Builds a layout from raw RoomPlan walls and objects (world coordinates).
    public static func from(walls rawWalls: [WorldBox], objects rawObjects: [WorldBox]) -> RoomLayout? {
        let all = rawWalls + rawObjects
        guard !all.isEmpty else { return nil }
        let pts = (rawWalls.isEmpty ? rawObjects : rawWalls).flatMap(\.corners)
        let xs = pts.map { $0.0 }, zs = pts.map { $0.1 }
        let minX = xs.min()!, maxX = xs.max()!
        let minZ = zs.min()!, maxZ = zs.max()!
        let floorY = all.map { $0.cy - $0.height / 2 }.min()!
        let topY = (rawWalls.isEmpty ? all : rawWalls).map { $0.cy + $0.height / 2 }.max()!
        let midX = (minX + maxX) / 2, midZ = (minZ + maxZ) / 2
        func shift(_ b: WorldBox) -> WorldBox {
            var o = b
            o.cx -= midX
            o.cz -= midZ
            o.cy -= floorY
            return o
        }
        return RoomLayout(
            walls: rawWalls.map(shift),
            objects: rawObjects.map(shift),
            widthM: max(1, maxX - minX),
            depthM: max(1, maxZ - minZ),
            heightM: Clamp.range(topY - floorY, 2, 6, fallback: 2.6),
            originX: midX,
            originZ: midZ,
            floorY: floorY
        )
    }

    /// Unit-cube position (0...1 per axis) of a world point in this layout.
    public func unit(x: Double, y: Double, z: Double) -> UnitPoint3 {
        UnitPoint3(x: Clamp.unit(x / widthM + 0.5), y: Clamp.unit(y / heightM), z: Clamp.unit(z / depthM + 0.5))
    }

    /// Storage-like furniture becomes a starting set of zones.
    public static func zoneSuggestion(forLabel label: String) -> (name: String, kind: ZoneKind)? {
        switch label.lowercased() {
        case "storage": return ("Storage unit", .cabinet)
        case "bed": return ("Bed", .bed)
        case "table": return ("Table", .table)
        case "sofa": return ("Sofa", .other)
        case "chair": return ("Chair", .other)
        case "washerdryer": return ("Washer / dryer", .other)
        case "refrigerator": return ("Fridge", .cabinet)
        case "sink": return ("Sink", .other)
        case "dishwasher": return ("Dishwasher", .cabinet)
        default: return nil
        }
    }
}
