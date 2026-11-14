import Foundation
import SwiftData
import TidyCore

/// Kinds of change kept in the activity log.
enum ActivityKind: String {
    case putAway, moved, found, scan, plan, step, design, map, rename, memory, suggestion, voice

    var symbol: String {
        switch self {
        case .putAway, .step: return "checkmark.circle"
        case .moved: return "arrow.left.arrow.right"
        case .found: return "camera"
        case .scan: return "viewfinder"
        case .plan: return "list.bullet"
        case .design: return "sofa"
        case .map: return "map"
        case .rename: return "tag"
        case .memory: return "brain"
        case .suggestion: return "lightbulb"
        case .voice: return "mic"
        }
    }
}

/// The change log: what happened in the home, kept on the phone, sent to Google Drive and read by both AIs.
enum ActivityLog {
    static func add(_ kind: ActivityKind, _ text: String, room: Room? = nil, item: Item? = nil, source: String = "you",
                    in context: ModelContext?) {
        guard let context else { return }
        let e = ActivityEvent(kind: kind.rawValue, text: Clamp.text(text, 300))
        e.roomID = room?.uid
        e.roomName = room?.name ?? ""
        e.placeName = room?.place?.name ?? ""
        e.itemID = item?.uid
        e.source = source
        context.insert(e)
    }
}

/// What the voice assistant decided to do.
struct AssistantOutcome {
    var reply: String
    var openRoom: Room?
    var focusRoom: Room?
    var item: Item?
}

/// Shared memory, suggestions, the AI review, the voice assistant and the Google Drive bridge.
extension Organizer {
    static let lastReviewKey = "ai.lastReview"
    static let autoReviewKey = "ai.autoReview"
    static let bridgeSeenKey = "bridge.seenKeys"

    /// Facts to remember and the latest changes, as text both AIs read before answering.
    func memoryNotes(context: ModelContext) -> String {
        let mem = ((try? context.fetch(FetchDescriptor<AIMemory>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? [])
            .filter(\.active)
        var ed = FetchDescriptor<ActivityEvent>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        ed.fetchLimit = 40
        let events = (try? context.fetch(ed)) ?? []
        return MemoryDigest.render(
            memories: mem.map { MemoryDigest.Note(date: $0.date, source: $0.source, text: $0.text) },
            events: events.map { e in
                MemoryDigest.Note(date: e.date, source: e.source,
                                  text: (e.roomName.isEmpty ? "" : "\(e.roomName): ") + e.text + (e.source == "you" ? "" : " (\(e.source))"))
            })
    }

    func remember(_ text: String, source: String, context: ModelContext) {
        let t = Clamp.text(text, 300)
        guard !t.isEmpty else { return }
        let existing = (try? context.fetch(FetchDescriptor<AIMemory>())) ?? []
        guard !existing.contains(where: { $0.active && $0.text.lowercased() == t.lowercased() }) else { return }
        context.insert(AIMemory(text: t, source: source))
        ActivityLog.add(.memory, "Remembered: \(t)", source: source, in: context)
    }

    @discardableResult
    func addSuggestion(title: String, detail: String, room: String?, source: String, context: ModelContext) -> Bool {
        let t = Clamp.text(title, 120)
        guard !t.isEmpty else { return false }
        let key = BridgeInbox.key(t + "|" + (room ?? ""))
        let existing = (try? context.fetch(FetchDescriptor<AISuggestion>())) ?? []
        guard !existing.contains(where: { $0.key == key }) else { return false }
        let s = AISuggestion(title: t)
        s.detail = Clamp.text(detail, 600)
        s.roomName = room ?? ""
        s.source = source
        s.key = key
        context.insert(s)
        return true
    }

    private func homeSummary(context: ModelContext) -> String {
        let places = (try? context.fetch(FetchDescriptor<Place>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        var rooms: [[String: Any]] = []
        for p in places {
            for r in p.sortedRooms {
                let out = r.toSort.filter(\.outOfPlace)
                rooms.append([
                    "place": p.name, "room": r.name, "tags": r.tags, "needs_a_name": r.needsName,
                    "things": r.items.count, "to_sort": r.toSort.count, "out_of_place": out.count,
                    "out_of_place_things": out.prefix(15).map(\.name),
                    "storage_spots": r.zones.filter { $0.parentID == nil }.prefix(20).map(\.name),
                    "tidy_steps_left": r.todoSteps.count,
                    "clutter_score": r.clutterScore.map { $0 as Any } ?? NSNull(),
                ] as [String: Any])
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["rooms": rooms], options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// "Review my home": the AI reads the inventory, the change log and the memory and suggests what to do.
    @discardableResult
    func reviewHome(provider: AIProvider? = nil, context: ModelContext) async throws -> Int {
        busy = true
        defer { busy = false }
        let text = "Home:\n\(homeSummary(context: context))\n\n\(memoryNotes(context: context))"
        let r = try await AIService.call(Assistant.Review.self, system: Assistant.reviewSystem, content: [.text(text)],
                                         schema: Assistant.reviewSchema, effort: .medium, maxTokens: 6000, only: provider)
        let who = AIService.lastProvider?.label ?? provider?.label ?? "AI"
        var n = 0
        for s in r.suggestions.prefix(8) where addSuggestion(title: s.title, detail: s.detail, room: s.room, source: who, context: context) {
            n += 1
        }
        for m in r.remember.prefix(6) { remember(m, source: who, context: context) }
        ActivityLog.add(.suggestion, "\(who) reviewed the home: \(n) new suggestion\(n == 1 ? "" : "s")", source: who, in: context)
        UserDefaults.standard.set(Date(), forKey: Self.lastReviewKey)
        try? context.save()
        scheduleDriveSync()
        return n
    }

    /// Once a week, when there were changes, the AI looks over the home by itself (can be turned off).
    func autoReviewIfDue(context: ModelContext) async {
        let on = UserDefaults.standard.object(forKey: Self.autoReviewKey) as? Bool ?? true
        guard on, KeyStore.hasKey, !busy else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastReviewKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 86_400 else { return }
        let events = (try? context.fetch(FetchDescriptor<ActivityEvent>())) ?? []
        guard events.filter({ $0.date > last }).count >= 5 else { return }
        _ = try? await reviewHome(context: context)
    }

    /// What the owner said (by voice or typed) → one action, done here, and a short spoken reply.
    func assistant(_ said: String, currentRoomID: UUID?, context: ModelContext) async throws -> AssistantOutcome {
        busy = true
        defer { busy = false }
        let places = (try? context.fetch(FetchDescriptor<Place>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        var roomRefs: [String: Room] = [:]
        var roomLines: [String] = []
        var current: String?
        for p in places {
            for r in p.sortedRooms {
                let ref = "r\(roomRefs.count + 1)"
                roomRefs[ref] = r
                if r.uid == currentRoomID { current = ref }
                var line = "\(ref): \(r.name) (in \(p.name))"
                if r.needsName { line += " [not named yet]" }
                if !r.tags.isEmpty { line += " tags: " + r.tags.joined(separator: ", ") }
                roomLines.append(line)
            }
        }
        var itemRefs: [String: Item] = [:]
        let items = places.flatMap { $0.rooms.flatMap(\.items) }.sorted { $0.updatedAt > $1.updatedAt }
        let lines: [InventoryText.Line] = items.prefix(1500).enumerated().map { n, it in
            let ref = "i\(n + 1)"
            itemRefs[ref] = it
            return InventoryText.Line(ref: ref, name: it.name, category: it.category, tags: it.tags,
                                      place: it.room?.place?.name ?? "?", room: it.room?.name ?? "?",
                                      spot: it.room?.zonePath(it.zoneID), notPutAway: !it.isSorted)
        }
        var text = "The owner said: \"\(said)\"\n"
        if let current, let r = roomRefs[current] { text += "They are looking at room \(current) (\(r.name)).\n" }
        text += "\nRooms:\n" + (roomLines.isEmpty ? "(none yet)" : roomLines.joined(separator: "\n"))
        text += "\n\nThings:\n" + (lines.isEmpty ? "(none yet)" : InventoryText.render(lines))
        let memory = memoryNotes(context: context)
        if !memory.isEmpty { text += "\n\n" + memory }

        let r = try await AIService.call(Assistant.Result.self, system: Assistant.system, content: [.text(text)],
                                         schema: Assistant.schema, effort: .low, maxTokens: 3000)
        let who = AIService.lastProvider?.label ?? "AI"
        var out = AssistantOutcome(reply: r.reply)
        let room = r.roomRef.flatMap { roomRefs[$0] } ?? (r.action == "rename_room" ? current.flatMap { roomRefs[$0] } : nil)
        let item = r.itemRef.flatMap { itemRefs[$0] }
        switch r.action {
        case "open_room":
            out.openRoom = room
        case "find":
            out.item = item
            out.openRoom = item?.room ?? room
        case "put_away":
            item?.putAway()
            out.item = item
        case "rename_room":
            let name = Clamp.text(r.text, 60)
            if let room, !name.isEmpty {
                let old = room.name
                room.name = name
                room.needsName = false
                ActivityLog.add(.rename, "Renamed \(old) to \(name) by voice", room: room, source: "voice", in: context)
                out.openRoom = room
            }
        case "start_focus":
            out.focusRoom = room
        case "remember":
            remember(r.text, source: "you (voice)", context: context)
        default:
            break
        }
        for m in r.remember.prefix(4) where m.lowercased() != r.text.lowercased() { remember(m, source: who, context: context) }
        ActivityLog.add(.voice, "Said: \(said)", room: room, source: "voice", in: context)
        try? context.save()
        scheduleDriveSync()
        return out
    }

    /// Reads bridge/from-ai.md (written on Drive by Claude, ChatGPT or the owner) into suggestions and memory.
    @discardableResult
    func importBridge(_ text: String, context: ModelContext) -> Int {
        let parsed = BridgeInbox.parse(text)
        var seen = Set(UserDefaults.standard.stringArray(forKey: Self.bridgeSeenKey) ?? [])
        var n = 0
        for s in parsed.suggestions {
            guard seen.insert(BridgeInbox.key("s|" + s.title + "|" + s.detail)).inserted else { continue }
            if addSuggestion(title: s.title, detail: s.detail, room: s.room, source: "Drive", context: context) { n += 1 }
        }
        for f in parsed.remember {
            guard seen.insert(BridgeInbox.key("m|" + f)).inserted else { continue }
            remember(f, source: "Drive", context: context)
            n += 1
        }
        UserDefaults.standard.set(Array(seen), forKey: Self.bridgeSeenKey)
        if n > 0 {
            ActivityLog.add(.suggestion, "Read \(n) new note\(n == 1 ? "" : "s") from the AI bridge on Google Drive", source: "Drive", in: context)
            try? context.save()
        }
        return n
    }

    /// The bridge file from the Drive folder (Files-app route).
    static func readBridgeFromFolder() -> String? {
        guard let root = resolveFolder() else { return nil }
        var out: String?
        try? FolderCopy.withAccess(root) {
            let url = root.appendingPathComponent(TidyPackage.bridgeInbox)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            var err: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
                out = try? String(contentsOf: u, encoding: .utf8)
            }
        }
        return out
    }
}
