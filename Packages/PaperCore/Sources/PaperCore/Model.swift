import Foundation

/// The three marks of the tracker: a dashed circle (to do), a spinning arc (in progress) and a green tick (done).
/// "Done" means the owner is satisfied with it, so only the owner (or an inbox op they asked Claude for) sets it.
public enum Status: String, Codable, CaseIterable, Sendable {
    case todo
    case inProgress = "in_progress"
    case done

    /// Tapping a mark walks to do → in progress → done → to do.
    public var next: Status {
        switch self {
        case .todo: return .inProgress
        case .inProgress: return .done
        case .done: return .todo
        }
    }

    public var label: String {
        switch self {
        case .todo: return "To do"
        case .inProgress: return "In progress"
        case .done: return "Done"
        }
    }

    /// Accepts the JSON spellings and a few natural ones ("doing", "complete", "open").
    public init?(loose: String) {
        switch loose.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_") {
        case "todo", "to_do", "open", "pending", "not_started": self = .todo
        case "in_progress", "inprogress", "doing", "started", "working": self = .inProgress
        case "done", "complete", "completed", "finished", "satisfied": self = .done
        default: return nil
        }
    }
}

/// One entry of the tree: a section, a subsection or a component. Whether it is a "leaf" depends only on
/// whether it has live children; parents take their mark from their children.
public struct Node: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var parentID: String?
    public var title: String
    /// Secondary line, e.g. the LaTeX label of an equation or the full text of a review flag.
    public var detail: String
    public var status: Status
    public var order: Double
    public var note: String
    /// Manuscript object this entry is about ("eq:harmonic", "fig:limit", "sec-intro"), if any.
    public var anchor: String?
    public var updatedAt: Date
    public var completedAt: Date?
    /// Tombstone: kept so a delete on one device wins over an older copy on another.
    public var deleted: Bool

    public init(id: String, parentID: String?, title: String, detail: String = "", status: Status = .todo,
                order: Double = 0, note: String = "", anchor: String? = nil, updatedAt: Date,
                completedAt: Date? = nil, deleted: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.detail = detail
        self.status = status
        self.order = order
        self.note = note
        self.anchor = anchor
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.deleted = deleted
    }

    enum CodingKeys: String, CodingKey {
        case id, parentID = "parent_id", title, detail, status, order, note, anchor
        case updatedAt = "updated_at", completedAt = "completed_at", deleted
    }

    // Lenient: files written by hand or by Claude may leave fields out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        let raw = try c.decodeIfPresent(String.self, forKey: .status) ?? "todo"
        status = Status(loose: raw) ?? .todo
        order = try c.decodeIfPresent(Double.self, forKey: .order) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        anchor = try c.decodeIfPresent(String.self, forKey: .anchor)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

/// A finished leaf, kept for the streak and the daily goal. XP itself is always computed from the tree, so
/// un-ticking something takes its XP away again.
public struct Win: Codable, Hashable, Sendable {
    public var id: String
    public var nodeID: String
    public var at: Date

    public init(id: String, nodeID: String, at: Date) {
        self.id = id
        self.nodeID = nodeID
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case id, nodeID = "node_id", at }
}

/// One paper and its whole tree. Saved as progress.json on the phone and in Google Drive › Paper Quest.
public struct Paper: Codable, Identifiable, Hashable, Sendable {
    public static let schemaID = "paper-quest.progress/1"

    public var schema: String
    public var id: String
    public var title: String
    public var subtitle: String
    /// Where the manuscript itself lives (the Firebase Manuscript Studio link for Green–Christoffel).
    public var manuscriptURL: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var nodes: [Node]
    public var wins: [Win]
    /// Names of Claude inbox files already applied, so each is applied once.
    public var appliedInbox: [String]

    public init(id: String, title: String, subtitle: String = "", manuscriptURL: String? = nil, now: Date,
                nodes: [Node] = [], wins: [Win] = [], appliedInbox: [String] = []) {
        schema = Self.schemaID
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.manuscriptURL = manuscriptURL
        createdAt = now
        updatedAt = now
        self.nodes = nodes
        self.wins = wins
        self.appliedInbox = appliedInbox
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, title, subtitle, manuscriptURL = "manuscript_url", createdAt = "created_at"
        case updatedAt = "updated_at", nodes, wins, appliedInbox = "applied_inbox"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? Self.schemaID
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled paper"
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        manuscriptURL = try c.decodeIfPresent(String.self, forKey: .manuscriptURL)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        nodes = try c.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        wins = try c.decodeIfPresent([Win].self, forKey: .wins) ?? []
        appliedInbox = try c.decodeIfPresent([String].self, forKey: .appliedInbox) ?? []
    }
}

/// JSON with ISO 8601 dates (fractional seconds when writing; with or without when reading).
public enum PaperJSON {
    private static func formatter(_ fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(formatter(true).string(from: date))
        }
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = formatter(true).date(from: s) ?? formatter(false).date(from: s) { return date }
            if let day = ISO8601DateFormatter.dayOnly.date(from: s) { return day }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unreadable date \(s)")
        }
        return d
    }

    public static func encode(_ paper: Paper) throws -> Data { try encoder.encode(paper) }
    public static func decode(_ data: Data) throws -> Paper { try decoder.decode(Paper.self, from: data) }
}

extension ISO8601DateFormatter {
    static let dayOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
