import Foundation
import RoomPlan
import SwiftData
import TidyCore

/// Scan history, map corrections, kitchen organising, naming and the shopping list.
extension Organizer {
    static func loadCaptured(_ file: String?) -> CapturedRoom? {
        guard let file, let data = try? Data(contentsOf: Storage.roomScanURL(file)) else { return nil }
        return try? JSONDecoder().decode(CapturedRoom.self, from: data)
    }

    /// Puts one room back the way an earlier scan saw it (the scan stays in the history).
    func restore(_ room: Room, from record: ScanRecord, context: ModelContext) -> Bool {
        guard let file = record.roomFiles[room.uid.uuidString], let captured = Self.loadCaptured(file) else { return false }
        let placement = room.mapX != nil ? room.placement : nil
        applyRoomScan(captured, to: room, context: context, quiet: true, keepRaw: false)
        room.capturedRoomFile = file
        if let placement {
            room.mapX = placement.x
            room.mapZ = placement.z
            room.mapRotationDeg = placement.rotationDeg
        }
        try? context.save()
        scheduleDriveSync()
        return true
    }

    /// Re-reads every saved raw scan with this version of the app (doors, windows and other things newer versions
    /// understand). Map corrections, things, storage spots and designs stay. Returns how many rooms were updated.
    func refreshScans(of place: Place, context: ModelContext) -> Int {
        var n = 0
        for room in place.rooms {
            guard let captured = Self.loadCaptured(room.capturedRoomFile) else { continue }
            let file = room.capturedRoomFile
            let manual = room.mapX != nil ? room.placement : nil
            applyRoomScan(captured, to: room, context: context, quiet: true, keepRaw: false)
            room.capturedRoomFile = file
            if let manual {
                room.mapX = manual.x
                room.mapZ = manual.z
                room.mapRotationDeg = manual.rotationDeg
            }
            n += 1
        }
        try? context.save()
        scheduleDriveSync()
        return n
    }

    /// Joins the latest scan of every room that shares the place's map into one model of the place.
    func rebuildPlaceModel(_ place: Place, context: ModelContext) async -> Bool {
        let rooms = place.rooms.filter { $0.fromHouseScan && $0.mapX == nil }.compactMap { Self.loadCaptured($0.capturedRoomFile) }
        guard !rooms.isEmpty else { return false }
        busy = true
        defer { busy = false }
        let name = "\(place.uid.uuidString)-place-\(Int(Date().timeIntervalSince1970)).usdz"
        do {
            let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
            try structure.export(to: Storage.roomScanURL(name))
            place.houseScanFile = name
            try? context.save()
            scheduleDriveSync()
            return true
        } catch {
            return false
        }
    }

    /// Name ideas and tags for a room, from its furniture, things and RoomPlan's guess.
    func suggestRoomNames(_ room: Room, provider: AIProvider? = nil) async throws -> RoomNameResult {
        busy = true
        defer { busy = false }
        let ctx: [String: Any] = [
            "roomplan_guess": room.sectionLabel ?? "unknown",
            "size_m": ["width": room.widthM, "depth": room.depthM],
            "furniture": (room.layout?.objects ?? []).map(\.label),
            "storage_spots": room.zones.map(\.name),
            "things_by_category": Dictionary(grouping: room.items, by: \.category).mapValues(\.count),
            "other_rooms_in_place": room.place?.rooms.filter { $0.uid != room.uid }.map(\.name) ?? [],
        ]
        let text = String(data: try JSONSerialization.data(withJSONObject: ctx), encoding: .utf8) ?? "{}"
        return try await AIService.call(RoomNameResult.self, system: Prompts.roomNameSystem, content: [.text(text)],
                                        schema: Prompts.roomNameSchema, effort: .low, maxTokens: 2000, only: provider)
    }

    /// Kitchen organiser: every storage spot gets a kitchen zone and what should go in it; organisers worth buying
    /// go to the shopping list.
    func organizeKitchen(_ room: Room, provider: AIProvider? = nil, context: ModelContext) async throws -> String {
        busy = true
        defer { busy = false }
        let zones = room.zones.sorted { $0.createdAt < $1.createdAt }
        var refs: [String: Zone] = [:]
        let spots: [[String: Any]] = zones.enumerated().map { n, z in
            let ref = "s\(n + 1)"
            refs[ref] = z
            let inside = room.items.filter { $0.zoneID == z.uid }.prefix(15).map(\.name)
            return ["ref": ref, "path": room.zonePath(z.uid) ?? z.name, "kind": z.kindRaw,
                    "height_off_floor": z.posY < 0.3 ? "low" : (z.posY < 0.6 ? "middle" : "high"),
                    "zone_now": jsonValue(z.kitchenZone), "contains": inside]
        }
        let fixtures = (room.currentDesign(context: context).pieces)
            .filter { ["fridge", "sink", "stove", "dishwasher"].contains($0.kind) }
            .map { ["kind": $0.kind, "x_m": $0.x, "z_m": $0.z] as [String: Any] }
        let food = room.items.filter { ["food & snacks", "kitchen & dishes"].contains($0.category) }.prefix(80).map(\.name)
        let ctx: [String: Any] = ["spots": spots, "fixtures": fixtures, "kitchen_things": food,
                                  "room_size_m": ["width": room.widthM, "depth": room.depthM]]
        let text = String(data: try JSONSerialization.data(withJSONObject: ctx), encoding: .utf8) ?? "{}"
        let r = try await AIService.call(KitchenResult.self, system: Prompts.kitchenSystem, content: [.text(text)],
                                         schema: Prompts.kitchenSchema, effort: .medium, only: provider)
        for s in r.spots {
            guard let z = refs[s.ref], Kitchen.ZoneType(rawValue: s.zone) != nil else { continue }
            z.kitchenZone = s.zone
            z.notes = Clamp.text(s.contents, 200)
        }
        saveShopping(r.shopping, room: room, context: context)
        try? context.save()
        scheduleDriveSync()
        return r.summary
    }

    /// Adds buy suggestions to the shopping list (skipping ones already there and not bought).
    func saveShopping(_ buys: [DesignAI.Buy], room: Room, context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<ShoppingItem>())) ?? []
        let open = Set(existing.filter { !$0.bought }.map { $0.name.lowercased() })
        for b in buys.prefix(12) where !open.contains(b.name.lowercased()) && !b.name.isEmpty {
            let s = ShoppingItem(name: Clamp.text(b.name, 80))
            s.category = Clamp.text(b.category, 40)
            s.priceUSD = b.priceUsd.isFinite && b.priceUsd > 0 ? b.priceUsd : nil
            s.why = Clamp.text(b.why, 200)
            s.provider = AIService.lastProvider?.label ?? ""
            s.roomName = room.name
            context.insert(s)
        }
    }
}
