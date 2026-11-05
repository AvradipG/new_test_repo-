import Foundation

/// Where an item is or should go, after resolving Claude's short refs.
public enum ZoneTarget: Equatable, Sendable {
    case none
    case existing(UUID)
    case new(String)
}

public struct MergedItem: Equatable, Sendable {
    public var name: String
    public var category: String
    public var tags: [String]
    public var description: String
    public var quantity: Int
    public var bbox: PhotoBox
    public var position: UnitPoint3
    public var outOfPlace: Bool
    public var action: ItemAction
    public var reason: String
    public var currentZone: ZoneTarget
    public var suggestedZone: ZoneTarget
    /// Things Claude says can stay where they are start out as already sorted.
    public var startsSorted: Bool { action == .keep && !outOfPlace }
}

public struct MergedZone: Equatable, Sendable {
    public var ref: String
    public var name: String
    public var kind: ZoneKind
    public var position: UnitPoint3
    public var sizeW: Double
    public var sizeH: Double
    public var sizeD: Double
    public var isIdea: Bool
}

public struct MergePlan: Equatable, Sendable {
    public enum Op: Equatable, Sendable {
        case update(UUID, MergedItem)
        case insert(MergedItem)
    }

    public var roomType: String
    public var clutterScore: Int
    public var summary: String
    public var widthM: Double
    public var depthM: Double
    public var heightM: Double
    public var newZones: [MergedZone]
    public var ops: [Op]

    public var insertCount: Int { ops.filter { if case .insert = $0 { return true } else { return false } }.count }
    public var updateCount: Int { ops.count - insertCount }
}

/// Turns one photo analysis into concrete database changes: short refs ("i3", "z2", "new-1") are resolved,
/// numbers are clamped to sane ranges and items seen again are updated instead of duplicated.
public enum MergePlanner {
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    public static func plan(_ a: PhotoAnalysis, knownItems: [String: UUID], knownZones: [String: UUID]) -> MergePlan {
        let newZones = a.newZones.prefix(20).map { z in
            MergedZone(
                ref: z.ref,
                name: Clamp.text(z.name, 80),
                kind: ZoneKind(rawValue: z.kind) ?? .other,
                position: UnitPoint3(x: Clamp.unit(z.posX), y: Clamp.unit(z.posY), z: Clamp.unit(z.posZ)),
                sizeW: Clamp.range(z.sizeW, 0.1, 6, fallback: 0.8),
                sizeH: Clamp.range(z.sizeH, 0.05, 3, fallback: 0.8),
                sizeD: Clamp.range(z.sizeD, 0.05, 3, fallback: 0.4),
                isIdea: !z.existsNow
            )
        }
        let newRefs = Set(newZones.map(\.ref))

        func zone(_ ref: String?) -> ZoneTarget {
            guard let ref else { return .none }
            if let id = knownZones[ref] { return .existing(id) }
            if newRefs.contains(ref) { return .new(ref) }
            return .none
        }

        var seen = Set<UUID>()
        var ops: [MergePlan.Op] = []
        for it in a.items.prefix(60) {
            let tags = it.tags
                .map { Clamp.text($0.lowercased(), 30) }
                .filter { !$0.isEmpty }
            let merged = MergedItem(
                name: Clamp.text(it.name, 120),
                category: Categories.normalise(it.category),
                tags: Array(unique(tags).prefix(6)),
                description: Clamp.text(it.description, 300),
                quantity: Int(Clamp.range(Double(it.quantity), 1, 999, fallback: 1)),
                bbox: PhotoBox(
                    x: Clamp.unit(it.bbox.x),
                    y: Clamp.unit(it.bbox.y),
                    w: Clamp.range(it.bbox.w, 0.01, 1, fallback: 0.1),
                    h: Clamp.range(it.bbox.h, 0.01, 1, fallback: 0.1)
                ),
                position: UnitPoint3(x: Clamp.unit(it.posX), y: Clamp.unit(it.posY), z: Clamp.unit(it.posZ)),
                outOfPlace: it.outOfPlace,
                action: ItemAction(rawValue: it.action) ?? .decide,
                reason: Clamp.text(it.reason, 300),
                currentZone: zone(it.currentZoneRef),
                suggestedZone: zone(it.suggestedZoneRef)
            )
            if let ref = it.existingItemRef, let id = knownItems[ref], !seen.contains(id) {
                seen.insert(id)
                ops.append(.update(id, merged))
            } else {
                ops.append(.insert(merged))
            }
        }

        return MergePlan(
            roomType: Clamp.text(a.room.roomType, 60),
            clutterScore: Int(Clamp.range(Double(a.room.clutterScore), 0, 10, fallback: 5)),
            summary: Clamp.text(a.room.summary, 400),
            widthM: Clamp.range(a.room.widthM, 1, 40, fallback: 4),
            depthM: Clamp.range(a.room.depthM, 1, 40, fallback: 4),
            heightM: Clamp.range(a.room.heightM, 2, 6, fallback: 2.6),
            newZones: Array(newZones),
            ops: ops
        )
    }
}
