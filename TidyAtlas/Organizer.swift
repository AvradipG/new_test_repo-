import Foundation
import RoomPlan
import SwiftData
import SwiftUI
import TidyCore
import UIKit

struct ScanProgress: Equatable {
    var label: String
    var done: Int
    var total: Int
}

struct ScanOutcome {
    var photos = 0
    var added = 0
    var updated = 0
    var failed = 0
    var lastError: String?
}

enum OrganizerError: LocalizedError {
    case nothingFound
    case nothingToPlan
    case noPhoto

    var errorDescription: String? {
        switch self {
        case .nothingFound: return "Claude didn't spot any items in that photo. Try a wider shot with more light."
        case .nothingToPlan: return "Nothing left to sort here. Scan the room first, or enjoy the tidy space!"
        case .noPhoto: return "That photo is missing on the phone."
        }
    }
}

/// Everything that talks to Claude or changes several records at once.
@MainActor
final class Organizer: ObservableObject {
    /// The one organizer, reachable from iOS background callbacks (uploads finishing with the app closed).
    static weak var current: Organizer?
    let container: ModelContainer

    @Published var progress: ScanProgress?
    @Published var busy = false
    @Published var latestRemote: RemoteVersion?
    @Published var lastUpdateCheck: Date?

    // Google Drive
    @Published var driveSignedIn = false
    @Published var driveEmail: String?
    @Published var isSyncing = false
    @Published var driveStatus: String?
    @Published var folderLinked = false
    @Published var folderName: String?
    @Published var lastDriveSync: Date?
    var pendingUploads = 0
    var pendingSync: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
        Organizer.current = self
        refreshDriveAccount()
    }

    // MARK: Scanning

    /// Photos and videos → stills → Claude, one photo at a time, merged into the room.
    func scan(_ media: [PickedMedia], into room: Room, context: ModelContext) async -> ScanOutcome {
        var outcome = ScanOutcome()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            progress = nil
        }
        progress = ScanProgress(label: "Preparing photos…", done: 0, total: 1)
        var stills: [Data] = []
        for m in media {
            switch m {
            case let .image(img):
                let jpeg = await Task.detached(operation: { ImageTools.jpeg(img) }).value
                if let jpeg { stills.append(jpeg) }
            case let .movie(url):
                progress = ScanProgress(label: "Pulling the sharpest frames from your video…", done: 0, total: 1)
                stills += (try? await ImageTools.frames(from: url, count: 6)) ?? []
                try? FileManager.default.removeItem(at: url)
            }
        }
        outcome.photos = stills.count
        for (i, data) in stills.enumerated() {
            progress = ScanProgress(label: "Claude is looking at photo \(i + 1) of \(stills.count)…", done: i, total: stills.count)
            guard let file = try? Storage.saveCapture(data) else { continue }
            let capture = Capture(file: file)
            await geotag(capture)
            capture.room = room
            context.insert(capture)
            try? context.save()
            do {
                let plan = try await analyze(capture, in: room, context: context)
                outcome.added += plan.insertCount
                outcome.updated += plan.updateCount
            } catch {
                outcome.failed += 1
                outcome.lastError = error.localizedDescription
            }
        }
        try? context.save()
        if outcome.failed < outcome.photos { Haptics.success() }
        scheduleDriveSync()
        return outcome
    }

    /// One AR snapshot: the upright photo plus the LiDAR depth taken at the same instant. Things Claude finds are
    /// measured from the depth and pinned to their real place in the room's AR world.
    func scanAR(jpeg: Data, depth: DepthFrame?, into room: Room, context: ModelContext) async throws -> MergePlan {
        progress = ScanProgress(label: "Claude is looking and measuring…", done: 0, total: 1)
        defer { progress = nil }
        let file = try Storage.saveCapture(jpeg)
        let capture = Capture(file: file)
        await geotag(capture)
        capture.room = room
        context.insert(capture)
        if let depth { DepthStore.save(depth, for: capture.uid) }
        try? context.save()
        let plan = try await analyze(capture, in: room, context: context)
        Haptics.success()
        scheduleDriveSync()
        return plan
    }

    /// Runs (or re-runs) Claude on one stored photo and merges the answer into the room.
    @discardableResult
    func analyze(_ capture: Capture, in room: Room, context: ModelContext) async throws -> MergePlan {
        capture.status = .analyzing
        capture.error = nil
        try? context.save()
        do {
            guard let jpeg = try? Data(contentsOf: Storage.captureURL(capture.file)) else { throw OrganizerError.noPhoto }
            let firstPhoto = !room.captures.contains { $0.status == .analyzed }

            var zoneRefs: [String: UUID] = [:]
            var zoneRefByID: [UUID: String] = [:]
            var zonesCtx: [[String: Any]] = []
            for (n, z) in room.zones.sorted(by: { $0.createdAt < $1.createdAt }).enumerated() {
                let ref = "z\(n + 1)"
                zoneRefs[ref] = z.uid
                zoneRefByID[z.uid] = ref
                zonesCtx.append(["ref": ref, "name": z.name, "kind": z.kindRaw, "pos_x": z.posX, "pos_z": z.posZ])
            }
            var itemRefs: [String: UUID] = [:]
            var itemsCtx: [[String: Any]] = []
            for (n, it) in room.items.sorted(by: { $0.createdAt > $1.createdAt }).prefix(250).enumerated() {
                let ref = "i\(n + 1)"
                itemRefs[ref] = it.uid
                itemsCtx.append(["ref": ref, "name": it.name, "category": it.category,
                                 "zone": jsonValue(it.zoneID.flatMap { zoneRefByID[$0] })])
            }
            let ctx: [String: Any] = [
                "room": ["name": room.name, "type": room.roomType.isEmpty ? "unknown" : room.roomType,
                         "width_m": room.widthM, "depth_m": room.depthM],
                "known_zones": zonesCtx,
                "known_items": itemsCtx,
            ]
            let ctxText = String(data: try JSONSerialization.data(withJSONObject: ctx), encoding: .utf8) ?? "{}"

            let analysis = try await AIService.call(
                PhotoAnalysis.self,
                system: Prompts.analyzeSystem,
                content: [.jpeg(jpeg), .text("Room context (JSON):\n\(ctxText)\n\nAnalyse this photo.")],
                schema: Prompts.analysisSchema,
                effort: .medium
            )
            let plan = MergePlanner.plan(analysis, knownItems: itemRefs, knownZones: zoneRefs)
            if plan.ops.isEmpty && plan.newZones.isEmpty { throw OrganizerError.nothingFound }
            let placed = apply(plan, capture: capture, room: room, firstPhoto: firstPhoto, context: context)
            measure(placed, depth: DepthStore.load(for: capture.uid))
            capture.status = .analyzed
            capture.itemCount = plan.ops.count
            try? context.save()
            return plan
        } catch {
            capture.status = .failed
            capture.error = error.localizedDescription
            try? context.save()
            throw error
        }
    }

    /// Sizes from LiDAR depth when the photo has it (measured, pinned in AR), otherwise Claude's estimate.
    private func measure(_ placed: [(Item, PhotoBox, MergedItem)], depth: DepthFrame?) {
        for (item, box, merged) in placed {
            if let depth, let m = DepthMeasure.measure(box, in: depth) {
                item.sizeLengthCM = m.lengthCM
                item.sizeWidthCM = m.widthCM
                item.sizeHeightCM = m.heightCM
                item.sizeSource = "LiDAR"
                item.arX = m.centerX
                item.arY = m.centerY
                item.arZ = m.centerZ
            } else if item.sizeSource != "LiDAR", let s = merged.sizeEstimate {
                item.sizeLengthCM = s.length
                item.sizeWidthCM = s.width
                item.sizeHeightCM = s.height
                item.sizeSource = "estimate"
            }
        }
    }

    @discardableResult
    private func apply(_ plan: MergePlan, capture: Capture, room: Room, firstPhoto: Bool, context: ModelContext)
        -> [(Item, PhotoBox, MergedItem)] {
        var placed: [(Item, PhotoBox, MergedItem)] = []
        if room.roomType.isEmpty { room.roomType = plan.roomType }
        room.clutterScore = plan.clutterScore
        room.summary = plan.summary
        if firstPhoto && !room.sizeFromScan {
            room.widthM = plan.widthM
            room.depthM = plan.depthM
            room.heightM = plan.heightM
        }

        var newZoneIDs: [String: UUID] = [:]
        for z in plan.newZones {
            let zone = Zone(name: z.name, kind: z.kind)
            zone.posX = z.position.x
            zone.posY = z.position.y
            zone.posZ = z.position.z
            zone.sizeW = z.sizeW
            zone.sizeH = z.sizeH
            zone.sizeD = z.sizeD
            zone.isIdea = z.isIdea
            zone.room = room
            context.insert(zone)
            newZoneIDs[z.ref] = zone.uid
        }
        func resolve(_ t: ZoneTarget) -> UUID? {
            switch t {
            case .none: return nil
            case let .existing(id): return id
            case let .new(ref): return newZoneIDs[ref]
            }
        }

        for op in plan.ops {
            switch op {
            case let .update(id, m):
                guard let item = room.items.first(where: { $0.uid == id }), !item.isSorted else { continue }
                item.category = m.category
                item.tags = m.tags
                if !m.description.isEmpty { item.notes = m.description }
                item.quantity = m.quantity
                item.outOfPlace = m.outOfPlace
                item.action = m.action
                item.reason = m.reason
                item.zoneID = resolve(m.currentZone)
                item.suggestedZoneID = resolve(m.suggestedZone)
                item.updatedAt = Date()
                placed.append((item, m.bbox, m))
            case let .insert(m):
                let item = Item(name: m.name)
                item.category = m.category
                item.tags = m.tags
                item.notes = m.description
                item.quantity = m.quantity
                item.hasBox = true
                item.boxX = m.bbox.x
                item.boxY = m.bbox.y
                item.boxW = m.bbox.w
                item.boxH = m.bbox.h
                item.posX = m.position.x
                item.posY = m.position.y
                item.posZ = m.position.z
                item.outOfPlace = m.outOfPlace
                item.action = m.action
                item.reason = m.reason
                item.isSorted = m.startsSorted
                item.zoneID = resolve(m.currentZone)
                item.suggestedZoneID = resolve(m.suggestedZone)
                item.captureID = capture.uid
                item.thumbFile = Storage.saveThumbnail(from: capture.file, box: m.bbox)
                item.room = room
                context.insert(item)
                placed.append((item, m.bbox, m))
            }
        }
        return placed
    }

    /// A finished whole-place scan: geotag on the place, and every scanned room created (or updated, matched by
    /// name) with its walls, size, position in the place and furniture as storage spots.
    func applyHouseScan(_ scanned: [ScannedRoom], geotag: ScanGeotag?, modelFile: String?, to place: Place, context: ModelContext) {
        if let g = geotag {
            place.latitude = g.location.coordinate.latitude
            place.longitude = g.location.coordinate.longitude
            place.altitude = g.location.altitude
            place.geoAccuracyM = g.location.horizontalAccuracy
            place.floorLevel = g.location.floor?.level
            place.northBearing = g.northBearing
            if let a = g.address { place.address = a }
        }
        if let modelFile {
            place.houseScanFile = modelFile
            place.houseScannedAt = Date()
        }
        for s in scanned {
            let room = place.rooms.first { $0.name.lowercased() == s.name.lowercased() } ?? {
                let r = Room(name: s.name)
                r.place = place
                context.insert(r)
                return r
            }()
            room.fromHouseScan = true
            room.sectionLabel = s.room.sections.first.map { String(describing: $0.label) }
            if room.roomType.isEmpty, let label = room.sectionLabel, label != "unidentified" { room.roomType = label }
            applyRoomScan(s.room, to: room, context: context, quiet: true)
        }
        try? context.save()
        Haptics.success()
        scheduleDriveSync()
    }

    /// A finished LiDAR room scan: real size, wall layout, and furniture as starting storage zones.
    func applyRoomScan(_ captured: CapturedRoom, to room: Room, context: ModelContext, quiet: Bool = false) {
        if let layout = RoomScanSupport.layout(of: captured) {
            room.layout = layout
            room.widthM = layout.widthM
            room.depthM = layout.depthM
            room.heightM = layout.heightM
            room.sizeFromScan = true
            for obj in layout.objects {
                guard let s = RoomLayout.zoneSuggestion(forLabel: obj.label) else { continue }
                let p = layout.unit(x: obj.cx, y: obj.cy - obj.height / 2, z: obj.cz)
                let exists = room.zones.contains { $0.kind == s.kind && abs($0.posX - p.x) < 0.15 && abs($0.posZ - p.z) < 0.15 }
                if exists { continue }
                let zone = Zone(name: s.name, kind: s.kind)
                zone.posX = p.x
                zone.posY = p.y
                zone.posZ = p.z
                zone.sizeW = max(0.1, obj.width)
                zone.sizeH = max(0.05, obj.height)
                zone.sizeD = max(0.05, obj.depth)
                zone.yaw = obj.yaw
                zone.room = room
                context.insert(zone)
            }
        }
        let name = room.uid.uuidString + ".usdz"
        let url = Storage.roomScanURL(name)
        try? FileManager.default.removeItem(at: url)
        if (try? captured.export(to: url, metadataURL: nil, modelProvider: nil, exportOptions: .mesh)) != nil {
            room.usdzFile = name
        }
        if quiet { return }
        try? context.save()
        Haptics.success()
        scheduleDriveSync()
    }

    /// GPS on a new photo (only when location is allowed; never asks).
    private func geotag(_ capture: Capture) async {
        guard let l = await LocationService.shared.current(timeout: 3) else { return }
        capture.latitude = l.coordinate.latitude
        capture.longitude = l.coordinate.longitude
        capture.geoAccuracyM = l.horizontalAccuracy
    }

    /// The place you're at, from GPS (generous radius: indoor GPS drifts).
    func placeHere(_ places: [Place]) async -> Place? {
        guard let l = await LocationService.shared.current() else { return nil }
        let here = GeoPoint(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)
        let id = GeoMath.nearest(places.compactMap { p in p.geo.map { (p.uid, $0) } }, to: here, within: 250)
        return places.first { $0.uid == id }
    }

    // MARK: Coaching

    /// Claude turns the room's unsorted things into tiny steps that fit the energy and time available.
    func makePlan(for room: Room, energy: Energy, minutes: Int, context: ModelContext) async throws -> String {
        let toSort = Array(room.toSort.prefix(200))
        guard !toSort.isEmpty else { throw OrganizerError.nothingToPlan }
        busy = true
        defer { busy = false }
        var refs: [String: UUID] = [:]
        let items: [[String: Any]] = toSort.enumerated().map { n, it in
            let ref = "i\(n + 1)"
            refs[ref] = it.uid
            return [
                "ref": ref, "name": it.name, "qty": it.quantity,
                "now_in": room.zone(it.zoneID)?.name ?? "loose / floor",
                "goes_to": jsonValue(room.zone(it.suggestedZoneID)?.name),
                "action": it.actionRaw, "out_of_place": it.outOfPlace, "note": it.reason,
            ]
        }
        let ctx: [String: Any] = [
            "room": room.name, "energy": energy.rawValue, "minutes_available": minutes,
            "zones": room.zones.map { ["name": $0.name, "kind": $0.kindRaw, "needs_setting_up": $0.isIdea] },
            "items": items,
        ]
        let text = String(data: try JSONSerialization.data(withJSONObject: ctx), encoding: .utf8) ?? "{}"
        let plan = try await AIService.call(PlanResult.self, system: Prompts.planSystem,
                                                content: [.text(text)], schema: Prompts.planSchema,
                                                effort: .medium)
        guard !plan.steps.isEmpty else { throw ClaudeWire.Failure.unreadable }
        for s in room.steps where s.status == .todo { context.delete(s) }
        for (n, s) in plan.steps.prefix(40).enumerated() {
            let step = TidyStep(title: Clamp.text(s.title, 120))
            step.detail = Clamp.text(s.detail, 300)
            step.minutes = Int(Clamp.range(Double(s.minutes), 1, 15, fallback: 2))
            step.trip = max(1, s.trip)
            step.sortKey = Double(n + 1)
            step.itemID = s.itemRef.flatMap { refs[$0] }
            step.room = room
            context.insert(step)
        }
        try? context.save()
        scheduleDriveSync()
        return plan.pepTalk
    }

    func complete(_ step: TidyStep, in room: Room, context: ModelContext) {
        step.status = .done
        step.completedAt = Date()
        if let id = step.itemID, let item = room.items.first(where: { $0.uid == id }) { item.putAway() }
        try? context.save()
        Haptics.success()
        scheduleDriveSync()
    }

    func skip(_ step: TidyStep, context: ModelContext) {
        step.status = .skipped
        try? context.save()
    }

    /// "Too big": Claude splits one step into 2–4 almost effortless ones in its place.
    func breakDown(_ step: TidyStep, in room: Room, context: ModelContext) async throws -> Int {
        busy = true
        defer { busy = false }
        let text = String(data: try JSONSerialization.data(withJSONObject: ["step": step.title, "detail": step.detail]),
                          encoding: .utf8) ?? "{}"
        let r = try await AIService.call(BreakdownResult.self, system: Prompts.breakdownSystem,
                                             content: [.text(text)], schema: Prompts.breakdownSchema,
                                             effort: .low)
        let subs = Array(r.steps.prefix(4))
        guard !subs.isEmpty else { throw ClaudeWire.Failure.unreadable }
        let next = room.todoSteps.first { $0.sortKey > step.sortKey }?.sortKey ?? step.sortKey + 1
        for (n, s) in subs.enumerated() {
            let sub = TidyStep(title: Clamp.text(s.title, 120))
            sub.minutes = Int(Clamp.range(Double(s.minutes), 1, 5, fallback: 1))
            sub.trip = step.trip
            sub.sortKey = step.sortKey + (next - step.sortKey) * Double(n) / Double(subs.count)
            sub.itemID = n == subs.count - 1 ? step.itemID : nil
            sub.room = room
            context.insert(sub)
        }
        context.delete(step)
        try? context.save()
        return subs.count
    }

    // MARK: Finding

    func ask(_ question: String, items: [Item]) async throws -> (String, [Item]) {
        guard !items.isEmpty else {
            return ("Your inventory is empty so far. Scan a room first and I'll remember where everything is.", [])
        }
        busy = true
        defer { busy = false }
        var byRef: [String: Item] = [:]
        let lines: [InventoryText.Line] = items.prefix(2000).enumerated().map { n, it in
            let ref = "i\(n + 1)"
            byRef[ref] = it
            return InventoryText.Line(ref: ref, name: it.name, category: it.category, tags: it.tags,
                                      place: it.room?.place?.name ?? "?", room: it.room?.name ?? "?",
                                      spot: it.room?.zone(it.zoneID)?.name, notPutAway: !it.isSorted)
        }
        let r = try await AIService.call(
            AskResult.self, system: Prompts.askSystem,
            content: [.text("Inventory:\n\(InventoryText.render(lines))\n\nQuestion: \(question)")],
            schema: Prompts.askSchema, effort: .low, maxTokens: 4000
        )
        return (r.answer, r.itemRefs.compactMap { byRef[$0] })
    }
}

/// A JSON value for an optional string: the string, or null.
func jsonValue(_ s: String?) -> Any {
    if let s { return s }
    return NSNull()
}

enum Haptics {
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
