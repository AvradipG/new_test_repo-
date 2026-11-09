import Foundation

/// What Claude returns for one photo. Keys arrive in snake_case; decode with `AIResults.decoder`.
public struct PhotoAnalysis: Codable, Equatable, Sendable {
    public struct Room: Codable, Equatable, Sendable {
        public var roomType: String
        public var widthM: Double
        public var depthM: Double
        public var heightM: Double
        public var clutterScore: Int
        public var summary: String
    }

    public struct NewZone: Codable, Equatable, Sendable {
        public var ref: String
        public var name: String
        public var kind: String
        public var posX: Double
        public var posY: Double
        public var posZ: Double
        public var sizeW: Double
        public var sizeH: Double
        public var sizeD: Double
        public var existsNow: Bool
    }

    public struct Item: Codable, Equatable, Sendable {
        public var existingItemRef: String?
        public var name: String
        public var category: String
        public var tags: [String]
        public var description: String
        public var quantity: Int
        public var bbox: PhotoBox
        public var posX: Double
        public var posY: Double
        public var posZ: Double
        public var currentZoneRef: String?
        public var outOfPlace: Bool
        public var suggestedZoneRef: String?
        public var action: String
        public var reason: String
        /// Claude's rough size estimate (added in 1.1; optional so older answers still decode).
        public var sizeCm: SizeEstimate?
    }

    public struct SizeEstimate: Codable, Equatable, Sendable {
        public var length: Double
        public var width: Double
        public var height: Double
    }

    public var room: Room
    public var newZones: [NewZone]
    public var items: [Item]
}

public struct PlanResult: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var title: String
        public var detail: String
        public var minutes: Int
        public var trip: Int
        public var itemRef: String?
    }

    public var pepTalk: String
    public var steps: [Step]
}

public struct BreakdownResult: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var title: String
        public var minutes: Int
    }

    public var steps: [Step]
}

public struct RoomNameResult: Codable, Equatable, Sendable {
    public var names: [String]
    public var tags: [String]
}

public struct KitchenResult: Codable, Equatable, Sendable {
    public struct Spot: Codable, Equatable, Sendable {
        public var ref: String
        public var zone: String
        public var contents: String
    }

    public var summary: String
    public var spots: [Spot]
    public var shopping: [DesignAI.Buy]
}

public struct AskResult: Codable, Equatable, Sendable {
    public var answer: String
    public var itemRefs: [String]
}

public enum AIResults {
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}
