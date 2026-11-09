import Foundation

/// Shared vocabulary for the AI prompts, the database and the screens.
public enum PlaceKind: String, CaseIterable, Codable, Sendable {
    case home, office, other

    public var label: String {
        switch self {
        case .home: return "Home"
        case .office: return "Office"
        case .other: return "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .office: return "briefcase.fill"
        case .other: return "mappin.circle.fill"
        }
    }
}

public enum ZoneKind: String, CaseIterable, Codable, Sendable {
    case shelf, drawer, closet, cabinet, bin, desk, table, floor, wall, hook, bed, other
    // Added in 1.5 for nested storage and kitchens (stored as text, so older data is unaffected).
    case tray, box, pantry, fridge, freezer, rack

    public var label: String { rawValue.capitalized }
}

public enum ItemAction: String, CaseIterable, Codable, Sendable {
    case keep, move, donate, trash, decide

    public var label: String {
        switch self {
        case .keep: return "Stays here"
        case .move: return "Move it"
        case .donate: return "Donate"
        case .trash: return "Toss / recycle"
        case .decide: return "Decide later"
        }
    }
}

public enum Energy: String, CaseIterable, Codable, Sendable {
    case low, medium, high

    public var label: String {
        switch self {
        case .low: return "Low energy"
        case .medium: return "Okay"
        case .high: return "Energised"
        }
    }

    public var symbol: String {
        switch self {
        case .low: return "battery.25percent"
        case .medium: return "face.smiling"
        case .high: return "bolt.fill"
        }
    }
}

public enum Categories {
    public static let all: [String] = [
        "clothing", "laundry", "papers & documents", "electronics & cables", "kitchen & dishes",
        "food & snacks", "books & media", "toys & games", "tools & hardware", "office supplies",
        "personal care", "medicine", "bags & accessories", "sports & outdoor", "decor", "furniture",
        "trash & recycling", "other",
    ]

    public static func normalise(_ c: String) -> String {
        let lower = c.lowercased().trimmingCharacters(in: .whitespaces)
        return all.contains(lower) ? lower : "other"
    }

    public static func symbol(_ c: String) -> String {
        switch c {
        case "clothing", "laundry": return "tshirt"
        case "papers & documents": return "doc.text"
        case "electronics & cables": return "cable.connector"
        case "kitchen & dishes": return "fork.knife"
        case "food & snacks": return "carrot"
        case "books & media": return "book"
        case "toys & games": return "gamecontroller"
        case "tools & hardware": return "wrench.and.screwdriver"
        case "office supplies": return "paperclip"
        case "personal care": return "comb"
        case "medicine": return "pills"
        case "bags & accessories": return "bag"
        case "sports & outdoor": return "figure.run"
        case "decor": return "photo.artframe"
        case "furniture": return "sofa"
        case "trash & recycling": return "trash"
        default: return "shippingbox"
        }
    }
}

/// Rough position of something in a room, each axis 0...1:
/// x 0 = left wall, 1 = right wall; z 0 = far wall, 1 = near wall; y 0 = floor, 1 = ceiling.
public struct UnitPoint3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// A box in a photo, normalised 0...1, x/y = top-left corner.
public struct PhotoBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public enum Clamp {
    public static func unit(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0.5 }

    public static func range(_ v: Double, _ lo: Double, _ hi: Double, fallback: Double) -> Double {
        v.isFinite ? min(hi, max(lo, v)) : fallback
    }

    public static func text(_ s: String, _ max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > max ? String(t.prefix(max)) : t
    }
}
