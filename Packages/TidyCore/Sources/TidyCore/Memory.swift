import Foundation

/// Splitting one scan into rooms: RoomPlan labels sections of a scan (kitchen, bedroom…) with a centre point;
/// every wall, door and piece of furniture goes to the nearest section.
public enum SectionSplit {
    /// Index of the nearest centre for every point (x, z).
    public static func assign(_ points: [(Double, Double)], centers: [(Double, Double)]) -> [Int] {
        guard !centers.isEmpty else { return points.map { _ in 0 } }
        return points.map { p in
            var best = 0, bestD = Double.infinity
            for (i, c) in centers.enumerated() {
                let d = (p.0 - c.0) * (p.0 - c.0) + (p.1 - c.1) * (p.1 - c.1)
                if d < bestD { bestD = d; best = i }
            }
            return best
        }
    }
}

/// The shared memory both AIs read before answering, so Claude and ChatGPT always know what has happened.
public enum MemoryDigest {
    public struct Note: Sendable {
        public var date: Date
        public var source: String
        public var text: String
        public init(date: Date, source: String, text: String) {
            self.date = date
            self.source = source
            self.text = text
        }
    }

    /// Newest first, capped, one line each.
    public static func render(memories: [Note], events: [Note], maxMemories: Int = 40, maxEvents: Int = 30) -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]
        let m = memories.sorted { $0.date > $1.date }.prefix(maxMemories)
            .map { "- [\(df.string(from: $0.date)) \($0.source)] \($0.text)" }
        let e = events.sorted { $0.date > $1.date }.prefix(maxEvents)
            .map { "- [\(df.string(from: $0.date))] \($0.text)" }
        var out: [String] = []
        if !m.isEmpty { out.append("Things to remember about the owner and their home:\n" + m.joined(separator: "\n")) }
        if !e.isEmpty { out.append("What happened recently:\n" + e.joined(separator: "\n")) }
        return out.joined(separator: "\n\n")
    }
}

/// What Claude, ChatGPT (with Google Drive access) or the owner writes into bridge/from-ai.md on Drive, read back
/// by the app. Lines like "SUGGEST: title — detail", "REMEMBER: fact", or a JSON object with "suggestions" and
/// "remember".
public enum BridgeInbox {
    public struct Suggestion: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var room: String?
    }

    public struct Parsed: Equatable, Sendable {
        public var suggestions: [Suggestion] = []
        public var remember: [String] = []
    }

    public static func parse(_ text: String) -> Parsed {
        var out = Parsed()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] {
            for s in obj["suggestions"] as? [[String: Any]] ?? [] {
                guard let t = s["title"] as? String, !t.isEmpty else { continue }
                out.suggestions.append(Suggestion(title: Clamp.text(t, 120), detail: Clamp.text(s["detail"] as? String ?? "", 600),
                                                  room: s["room"] as? String))
            }
            out.remember = (obj["remember"] as? [String] ?? []).map { Clamp.text($0, 300) }.filter { !$0.isEmpty }
            return out
        }
        var lines = text.components(separatedBy: .newlines)
        // The file starts with instructions (with example lines) above a "---" line; only what follows counts.
        if let sep = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = Array(lines[(sep + 1)...])
        }
        for raw in lines {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = String(line.dropFirst(2)) }
            let upper = line.uppercased()
            if upper.hasPrefix("SUGGEST:") {
                let body = line.dropFirst("SUGGEST:".count).trimmingCharacters(in: .whitespaces)
                var room: String?
                var rest = body
                if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                    room = String(rest[rest.index(after: rest.startIndex)..<close])
                    rest = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
                }
                let parts = rest.components(separatedBy: " — ").count > 1 ? rest.components(separatedBy: " — ") : rest.components(separatedBy: " - ")
                let title = parts.first ?? rest
                let detail = parts.dropFirst().joined(separator: " - ")
                if !title.isEmpty { out.suggestions.append(Suggestion(title: Clamp.text(title, 120), detail: Clamp.text(detail, 600), room: room)) }
            } else if upper.hasPrefix("REMEMBER:") {
                let fact = line.dropFirst("REMEMBER:".count).trimmingCharacters(in: .whitespaces)
                if !fact.isEmpty { out.remember.append(Clamp.text(fact, 300)) }
            }
        }
        return out
    }

    /// A short stable key for a line, so the same suggestion isn't imported twice.
    public static func key(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.lowercased().utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }

    public static let template = """
    # Messages for Tidy Atlas
    Write here and the Tidy Atlas app on the owner's iPhone reads it at its next sync (it never deletes this file).
    One line each:
    SUGGEST: [Kitchen] Short title — what to do and why
    REMEMBER: a fact the app and its AIs should keep in mind (e.g. keys always go on the hook by the door)

    ---
    """
}

/// The voice and text assistant: understands what the owner says and picks one action.
public enum Assistant {
    public static let system = """
    You are the voice of Tidy Atlas, a private home organiser for an owner with ADHD. You get what the owner just \
    said (often spoken, so it may have small transcription errors), the list of places and rooms with refs, the \
    things they own with refs and where they are, and the shared memory of what happened before. Reply in one or two \
    short, warm spoken sentences. Choose one action: open_room (room_ref), find (item_ref of the best match, and say \
    exactly where it is in the reply), put_away (item_ref: the owner says they put something away), rename_room \
    (room_ref and text = new name; "call this room…" means the current room), start_focus (room_ref: start the tidy \
    steps), remember (text = the fact to keep), suggest (when they ask what to do next), or none. Use remember also \
    for preferences they mention in passing. Never invent refs.
    """

    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["reply","action","room_ref","item_ref","text","remember"],"properties":{
     "reply":{"type":"string"},
     "action":{"type":"string","enum":["open_room","find","put_away","rename_room","start_focus","remember","suggest","none"]},
     "room_ref":{"anyOf":[{"type":"string"},{"type":"null"}]},
     "item_ref":{"anyOf":[{"type":"string"},{"type":"null"}]},
     "text":{"type":"string"},
     "remember":{"type":"array","items":{"type":"string"}}}}
    """

    public struct Result: Codable, Equatable, Sendable {
        public var reply: String
        public var action: String
        public var roomRef: String?
        public var itemRef: String?
        public var text: String
        public var remember: [String]
    }

    public static let reviewSystem = """
    You are the home coach inside Tidy Atlas, for an owner with ADHD. You get the inventory summary, what changed \
    recently (moves, things put away, scans, plans, designs) and the shared memory. Notice patterns (things that keep \
    ending up out of place, rooms that slip, plans not finished) and give 3-6 concrete, kind suggestions, each tied to \
    a room when possible. Also list short facts worth remembering for next time.
    """

    public static let reviewSchema = """
    {"type":"object","additionalProperties":false,"required":["suggestions","remember"],"properties":{
     "suggestions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["title","detail","room"],
      "properties":{"title":{"type":"string"},"detail":{"type":"string"},"room":{"anyOf":[{"type":"string"},{"type":"null"}]}}}},
     "remember":{"type":"array","items":{"type":"string"}}}}
    """

    public struct Review: Codable, Equatable, Sendable {
        public struct Item: Codable, Equatable, Sendable {
            public var title: String
            public var detail: String
            public var room: String?
        }
        public var suggestions: [Item]
        public var remember: [String]
    }
}
