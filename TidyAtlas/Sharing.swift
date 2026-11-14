import Foundation
import SwiftData
import SwiftUI
import TidyCore
import UniformTypeIdentifiers

// Sharing a place or a room with someone else who has Tidy Atlas: everything about it (rooms, map, storage spots,
// things, plans, designs, scans, map versions, change history, shopping ideas, photos) goes into one .tidyatlas
// file. Send it by AirDrop, Messages, Mail or Drive; their Tidy Atlas opens it and adds it. Sending it again later
// updates their copy (rooms keep their ids, so the same rooms are replaced, not doubled).

extension UTType {
    static let tidyAtlasShare = UTType(exportedAs: ShareArchive.typeIdentifier, conformingTo: .data)
}

// MARK: Package (the database part of a share file)

struct SharePackage: Codable {
    var format = 1
    var appVersion = ""
    var sharedAt = Date()
    var sharedBy = ""
    var note = ""
    var wholePlace = true
    var place: SPlace
    var rooms: [SRoom] = []
    var scans: [SScan] = []
    var mapVersions: [SMapVersion] = []
    var activity: [SEvent] = []
    var shopping: [SShopping] = []

    var title: String { wholePlace || rooms.count != 1 ? place.name : "\(rooms[0].name) (\(place.name))" }
    var thingCount: Int { rooms.reduce(0) { $0 + $1.items.count } }
    var photoCount: Int { rooms.reduce(0) { $0 + $1.captures.count } }
}

struct SPlace: Codable {
    var uid: UUID
    var name: String
    var kindRaw: String
    var createdAt: Date
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var geoAccuracyM: Double?
    var floorLevel: Int?
    var address: String?
    var northBearing: Double?
    var houseScanFile: String?
    var houseScannedAt: Date?
    var worldMapFile: String?
}

struct SRoom: Codable {
    var uid: UUID
    var name: String
    var roomType: String
    var summary: String
    var widthM: Double
    var depthM: Double
    var heightM: Double
    var clutterScore: Int?
    var sizeFromScan: Bool
    var layoutData: Data?
    var usdzFile: String?
    var worldMapFile: String?
    var createdAt: Date
    var fromHouseScan: Bool
    var sectionLabel: String?
    var designChatData: Data?
    var northBearingOverride: Double?
    var entranceRaw: String?
    var mapX: Double?
    var mapZ: Double?
    var mapRotationDeg: Double
    var needsName: Bool
    var tags: [String]
    var capturedRoomFile: String?
    var isKitchenOverride: Bool?
    var activePlanID: UUID?
    var boundaryEdited: Bool
    var sectionsSplit: Bool
    var zones: [SZone]
    var items: [SItem]
    var steps: [SStep]
    var captures: [SCapture]
    var designs: [SDesign]
    var plans: [SPlan]
}

struct SZone: Codable {
    var uid: UUID, name: String, kindRaw: String
    var posX: Double, posY: Double, posZ: Double, sizeW: Double, sizeH: Double, sizeD: Double, yaw: Double
    var isIdea: Bool, createdAt: Date
    var arX: Double?, arY: Double?, arZ: Double?
    var parentID: UUID?, notes: String, kitchenZone: String?
}

struct SItem: Codable {
    var uid: UUID, name: String, category: String, tags: [String], notes: String, quantity: Int
    var hasBox: Bool, boxX: Double, boxY: Double, boxW: Double, boxH: Double
    var posX: Double, posY: Double, posZ: Double
    var outOfPlace: Bool, actionRaw: String, reason: String, isSorted: Bool
    var zoneID: UUID?, suggestedZoneID: UUID?, captureID: UUID?, thumbFile: String?
    var createdAt: Date, updatedAt: Date
    var sizeLengthCM: Double?, sizeWidthCM: Double?, sizeHeightCM: Double?, sizeSource: String?
    var expiresAt: Date?
    var arX: Double?, arY: Double?, arZ: Double?
}

struct SStep: Codable {
    var uid: UUID, title: String, detail: String, minutes: Int, trip: Int, sortKey: Double, statusRaw: String
    var completedAt: Date?, itemID: UUID?, createdAt: Date, planID: UUID?
}

struct SCapture: Codable {
    var uid: UUID, file: String, statusRaw: String, error: String?, itemCount: Int, createdAt: Date
    var latitude: Double?, longitude: Double?, geoAccuracyM: Double?
}

struct SDesign: Codable {
    var uid: UUID, name: String, style: String, rationale: String, tips: [String]
    var scoreOverall: Double?, scoreFlow: Double?, scoreCalm: Double?
    var isCurrent: Bool, piecesData: Data?, renderFile: String?, createdAt: Date
    var provider: String?, parentID: UUID?, version: Int
}

struct SPlan: Codable {
    var uid: UUID, provider: String, energy: String, minutes: Int, pepTalk: String, feedback: String
    var version: Int, parentID: UUID?, createdAt: Date
}

struct SScan: Codable {
    var uid: UUID, kind: String, date: Date, roomNames: [String], roomFilesData: Data?, usdzFile: String?, joinedMap: Bool
}

struct SMapVersion: Codable {
    var uid: UUID, name: String, date: Date, snapshotData: Data?
}

struct SEvent: Codable {
    var uid: UUID, date: Date, kind: String, text: String, placeName: String, roomName: String
    var roomID: UUID?, itemID: UUID?, source: String
}

struct SShopping: Codable {
    var uid: UUID, name: String, category: String, priceUSD: Double?, why: String, provider: String
    var roomName: String, bought: Bool, createdAt: Date
}

struct ShareOptions {
    var photos = true
    var location = true
    var history = true
    var sharedBy = ""
    var note = ""
}

// MARK: Export

enum ShareExport {
    /// Builds the share file in a temporary folder and returns its URL.
    @MainActor
    static func make(place: Place, room: Room?, options: ShareOptions, context: ModelContext) async throws -> URL {
        let rooms = room.map { [$0] } ?? place.sortedRooms
        var files: [ShareArchive.Source] = []
        func add(_ folder: String, _ name: String?, _ url: (String) -> URL) {
            guard let name, !name.isEmpty else { return }
            files.append(ShareArchive.Source(folder: folder, name: name, url: url(name)))
        }

        var pkg = SharePackage(place: SPlace(
            uid: place.uid, name: place.name, kindRaw: place.kindRaw, createdAt: place.createdAt,
            latitude: options.location ? place.latitude : nil, longitude: options.location ? place.longitude : nil,
            altitude: options.location ? place.altitude : nil, geoAccuracyM: options.location ? place.geoAccuracyM : nil,
            floorLevel: place.floorLevel, address: options.location ? place.address : nil, northBearing: place.northBearing,
            houseScanFile: room == nil ? place.houseScanFile : nil, houseScannedAt: place.houseScannedAt,
            worldMapFile: room == nil ? place.worldMapFile : nil))
        pkg.appVersion = AppInfo.version
        pkg.sharedBy = options.sharedBy.trimmingCharacters(in: .whitespaces)
        pkg.note = options.note.trimmingCharacters(in: .whitespacesAndNewlines)
        pkg.wholePlace = room == nil
        if room == nil {
            add("RoomScans", place.houseScanFile, Storage.roomScanURL)
            add("WorldMaps", place.worldMapFile, Storage.worldMapURL)
        }

        for r in rooms {
            let caps = options.photos ? r.captures : []
            pkg.rooms.append(SRoom(
                uid: r.uid, name: r.name, roomType: r.roomType, summary: r.summary, widthM: r.widthM, depthM: r.depthM,
                heightM: r.heightM, clutterScore: r.clutterScore, sizeFromScan: r.sizeFromScan, layoutData: r.layoutData,
                usdzFile: r.usdzFile, worldMapFile: r.worldMapFile, createdAt: r.createdAt, fromHouseScan: r.fromHouseScan,
                sectionLabel: r.sectionLabel, designChatData: r.designChatData, northBearingOverride: r.northBearingOverride,
                entranceRaw: r.entranceRaw, mapX: r.mapX, mapZ: r.mapZ, mapRotationDeg: r.mapRotationDeg, needsName: r.needsName,
                tags: r.tags, capturedRoomFile: r.capturedRoomFile, isKitchenOverride: r.isKitchenOverride,
                activePlanID: r.activePlanID, boundaryEdited: r.boundaryEdited, sectionsSplit: r.sectionsSplit,
                zones: r.zones.map(SZone.init),
                items: r.items.map { SItem($0, keepCapture: options.photos) },
                steps: r.steps.map(SStep.init),
                captures: caps.map { SCapture($0, location: options.location) },
                designs: r.designs.map(SDesign.init),
                plans: r.plans.map(SPlan.init)))
            add("RoomScans", r.usdzFile, Storage.roomScanURL)
            add("RoomScans", r.capturedRoomFile, Storage.roomScanURL)
            add("WorldMaps", r.worldMapFile, Storage.worldMapURL)
            r.items.forEach { add("Thumbs", $0.thumbFile, Storage.thumbURL) }
            r.designs.forEach { add("Designs", $0.renderFile, Storage.designURL) }
            for c in caps {
                add("Captures", c.file, Storage.captureURL)
                add("Depth", c.uid.uuidString + ".depth") { _ in DepthStore.url(c.uid) }
            }
        }

        let ids = Set(rooms.map(\.uid))
        for s in place.scans {
            let roomFiles = s.roomFiles.filter { ids.contains(UUID(uuidString: $0.key) ?? UUID()) }
            guard room == nil || !roomFiles.isEmpty else { continue }
            var data = s.roomFilesData
            if room != nil { data = try? JSONEncoder().encode(roomFiles) }
            pkg.scans.append(SScan(uid: s.uid, kind: s.kind, date: s.date, roomNames: s.roomNames, roomFilesData: data,
                                   usdzFile: room == nil ? s.usdzFile : nil, joinedMap: s.joinedMap))
            roomFiles.values.forEach { add("RoomScans", $0, Storage.roomScanURL) }
            if room == nil { add("RoomScans", s.usdzFile, Storage.roomScanURL) }
        }
        if room == nil {
            pkg.mapVersions = place.mapVersions.map { SMapVersion(uid: $0.uid, name: $0.name, date: $0.date, snapshotData: $0.snapshotData) }
        }
        if options.history {
            let events = (try? context.fetch(FetchDescriptor<ActivityEvent>(sortBy: [SortDescriptor(\.date)]))) ?? []
            pkg.activity = events.filter { e in e.roomID.map { ids.contains($0) } ?? (room == nil && e.placeName == place.name) }
                .map(SEvent.init)
        }
        let roomNames = Set(rooms.map(\.name))
        let shopping = (try? context.fetch(FetchDescriptor<ShoppingItem>())) ?? []
        pkg.shopping = shopping.filter { roomNames.contains($0.roomName) }.map(SShopping.init)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifest = try encoder.encode(pkg)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(TidyPackage.safe(pkg.title)).\(ShareArchive.fileExtension)")
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.folder + "/" + $0.name).inserted }
        try await Task.detached(priority: .userInitiated) {
            try ShareArchive.write(manifest: manifest, files: unique, to: url)
        }.value
        return url
    }
}

extension SZone {
    init(_ z: Zone) {
        self.init(uid: z.uid, name: z.name, kindRaw: z.kindRaw, posX: z.posX, posY: z.posY, posZ: z.posZ, sizeW: z.sizeW,
                  sizeH: z.sizeH, sizeD: z.sizeD, yaw: z.yaw, isIdea: z.isIdea, createdAt: z.createdAt, arX: z.arX, arY: z.arY,
                  arZ: z.arZ, parentID: z.parentID, notes: z.notes, kitchenZone: z.kitchenZone)
    }
}

extension SItem {
    init(_ i: Item, keepCapture: Bool) {
        self.init(uid: i.uid, name: i.name, category: i.category, tags: i.tags, notes: i.notes, quantity: i.quantity,
                  hasBox: i.hasBox, boxX: i.boxX, boxY: i.boxY, boxW: i.boxW, boxH: i.boxH, posX: i.posX, posY: i.posY,
                  posZ: i.posZ, outOfPlace: i.outOfPlace, actionRaw: i.actionRaw, reason: i.reason, isSorted: i.isSorted,
                  zoneID: i.zoneID, suggestedZoneID: i.suggestedZoneID, captureID: keepCapture ? i.captureID : nil,
                  thumbFile: i.thumbFile, createdAt: i.createdAt, updatedAt: i.updatedAt, sizeLengthCM: i.sizeLengthCM,
                  sizeWidthCM: i.sizeWidthCM, sizeHeightCM: i.sizeHeightCM, sizeSource: i.sizeSource, expiresAt: i.expiresAt,
                  arX: i.arX, arY: i.arY, arZ: i.arZ)
    }
}

extension SStep {
    init(_ s: TidyStep) {
        self.init(uid: s.uid, title: s.title, detail: s.detail, minutes: s.minutes, trip: s.trip, sortKey: s.sortKey,
                  statusRaw: s.statusRaw, completedAt: s.completedAt, itemID: s.itemID, createdAt: s.createdAt, planID: s.planID)
    }
}

extension SCapture {
    init(_ c: Capture, location: Bool) {
        self.init(uid: c.uid, file: c.file, statusRaw: c.statusRaw, error: c.error, itemCount: c.itemCount, createdAt: c.createdAt,
                  latitude: location ? c.latitude : nil, longitude: location ? c.longitude : nil,
                  geoAccuracyM: location ? c.geoAccuracyM : nil)
    }
}

extension SDesign {
    init(_ d: DesignVariant) {
        self.init(uid: d.uid, name: d.name, style: d.style, rationale: d.rationale, tips: d.tips, scoreOverall: d.scoreOverall,
                  scoreFlow: d.scoreFlow, scoreCalm: d.scoreCalm, isCurrent: d.isCurrent, piecesData: d.piecesData,
                  renderFile: d.renderFile, createdAt: d.createdAt, provider: d.provider, parentID: d.parentID, version: d.version)
    }
}

extension SPlan {
    init(_ p: TidyPlan) {
        self.init(uid: p.uid, provider: p.provider, energy: p.energy, minutes: p.minutes, pepTalk: p.pepTalk,
                  feedback: p.feedback, version: p.version, parentID: p.parentID, createdAt: p.createdAt)
    }
}

extension SEvent {
    init(_ e: ActivityEvent) {
        self.init(uid: e.uid, date: e.date, kind: e.kind, text: e.text, placeName: e.placeName, roomName: e.roomName,
                  roomID: e.roomID, itemID: e.itemID, source: e.source)
    }
}

extension SShopping {
    init(_ s: ShoppingItem) {
        self.init(uid: s.uid, name: s.name, category: s.category, priceUSD: s.priceUSD, why: s.why, provider: s.provider,
                  roomName: s.roomName, bought: s.bought, createdAt: s.createdAt)
    }
}

// MARK: Import

/// A share file someone sent, opened and checked, waiting for "Add".
struct IncomingShare: Identifiable {
    let id = UUID()
    let url: URL
    let package: SharePackage
    let fileCount: Int
    let bytes: Int64
}

enum ShareImport {
    static let folders: [String: URL] = [
        "Captures": Storage.captures, "Thumbs": Storage.thumbs, "RoomScans": Storage.roomScans,
        "WorldMaps": Storage.worldMaps, "Designs": Storage.designs, "Depth": DepthStore.folder,
    ]

    /// Copies an opened file into the app (it may be a security-scoped file in Files or Drive) and reads it.
    static func open(_ url: URL) throws -> IncomingShare {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(UUID().uuidString + "." + ShareArchive.fileExtension)
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            do { try FileManager.default.copyItem(at: u, to: local) } catch { copyError = error }
        }
        if let e = coordError ?? copyError { throw e }
        // AirDrop and Mail leave a copy in Documents/Inbox; it isn't needed once copied.
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        let reader = try ShareArchive.Reader(url: local)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let pkg = try? decoder.decode(SharePackage.self, from: reader.manifest) else { throw ShareArchive.Failure.damaged }
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
        return IncomingShare(url: local, package: pkg, fileCount: reader.index.entries.count, bytes: size)
    }

    /// Adds (or updates) the shared place and rooms. Returns the place.
    @MainActor
    static func add(_ share: IncomingShare, context: ModelContext) async throws -> Place {
        let url = share.url
        let folders = Self.folders
        try await Task.detached(priority: .userInitiated) {
            let reader = try ShareArchive.Reader(url: url)
            for (i, e) in reader.index.entries.enumerated() {
                guard let dir = folders[e.folder] else { continue }
                try reader.extract(i, to: dir.appendingPathComponent(e.name))
            }
        }.value

        let pkg = share.package
        let places = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        let place: Place
        if let existing = places.first(where: { $0.uid == pkg.place.uid }) {
            place = existing
        } else {
            place = Place(name: pkg.place.name, kind: .home)
            place.uid = pkg.place.uid
            place.kindRaw = pkg.place.kindRaw
            place.createdAt = pkg.place.createdAt
            context.insert(place)
        }
        let p = pkg.place
        if pkg.wholePlace || place.latitude == nil {
            if let v = p.latitude { place.latitude = v }
            if let v = p.longitude { place.longitude = v }
            if let v = p.altitude { place.altitude = v }
            if let v = p.geoAccuracyM { place.geoAccuracyM = v }
            if let v = p.floorLevel { place.floorLevel = v }
            if let v = p.address { place.address = v }
            if let v = p.northBearing { place.northBearing = v }
        }
        if pkg.wholePlace {
            place.name = p.name
            if let v = p.houseScanFile { place.houseScanFile = v }
            if let v = p.houseScannedAt { place.houseScannedAt = v }
            if let v = p.worldMapFile { place.worldMapFile = v }
        }

        // Rooms shared before are replaced by the new version.
        let ids = Set(pkg.rooms.map(\.uid))
        let allRooms = (try? context.fetch(FetchDescriptor<Room>())) ?? []
        for old in allRooms where ids.contains(old.uid) { context.delete(old) }
        try? context.save()

        for s in pkg.rooms { insert(s, into: place, context: context) }

        let scanIDs = Set(((try? context.fetch(FetchDescriptor<ScanRecord>())) ?? []).map(\.uid))
        for s in pkg.scans where !scanIDs.contains(s.uid) {
            let r = ScanRecord(kind: s.kind)
            r.uid = s.uid
            r.date = s.date
            r.roomNames = s.roomNames
            r.roomFilesData = s.roomFilesData
            r.usdzFile = s.usdzFile
            r.joinedMap = s.joinedMap
            r.place = place
            context.insert(r)
        }
        let versionIDs = Set(((try? context.fetch(FetchDescriptor<MapVersion>())) ?? []).map(\.uid))
        for v in pkg.mapVersions where !versionIDs.contains(v.uid) {
            let m = MapVersion(name: v.name)
            m.uid = v.uid
            m.date = v.date
            m.snapshotData = v.snapshotData
            m.place = place
            context.insert(m)
        }
        let eventIDs = Set(((try? context.fetch(FetchDescriptor<ActivityEvent>())) ?? []).map(\.uid))
        for e in pkg.activity where !eventIDs.contains(e.uid) {
            let a = ActivityEvent(kind: e.kind, text: e.text)
            a.uid = e.uid
            a.date = e.date
            a.placeName = e.placeName
            a.roomName = e.roomName
            a.roomID = e.roomID
            a.itemID = e.itemID
            a.source = e.source
            context.insert(a)
        }
        let shopIDs = Set(((try? context.fetch(FetchDescriptor<ShoppingItem>())) ?? []).map(\.uid))
        for s in pkg.shopping where !shopIDs.contains(s.uid) {
            let i = ShoppingItem(name: s.name)
            i.uid = s.uid
            i.category = s.category
            i.priceUSD = s.priceUSD
            i.why = s.why
            i.provider = s.provider
            i.roomName = s.roomName
            i.bought = s.bought
            i.createdAt = s.createdAt
            context.insert(i)
        }
        let from = pkg.sharedBy.isEmpty ? "someone" : pkg.sharedBy
        ActivityLog.add(.map, "Received \(pkg.title) from \(from)" + (pkg.note.isEmpty ? "" : ": \(pkg.note)"),
                        source: "shared", in: context)
        try context.save()
        try? FileManager.default.removeItem(at: url)
        return place
    }

    @MainActor
    private static func insert(_ s: SRoom, into place: Place, context: ModelContext) {
        let r = Room(name: s.name)
        r.uid = s.uid
        r.roomType = s.roomType
        r.summary = s.summary
        r.widthM = s.widthM
        r.depthM = s.depthM
        r.heightM = s.heightM
        r.clutterScore = s.clutterScore
        r.sizeFromScan = s.sizeFromScan
        r.layoutData = s.layoutData
        r.usdzFile = s.usdzFile
        r.worldMapFile = s.worldMapFile
        r.createdAt = s.createdAt
        r.fromHouseScan = s.fromHouseScan
        r.sectionLabel = s.sectionLabel
        r.designChatData = s.designChatData
        r.northBearingOverride = s.northBearingOverride
        r.entranceRaw = s.entranceRaw
        r.mapX = s.mapX
        r.mapZ = s.mapZ
        r.mapRotationDeg = s.mapRotationDeg
        r.needsName = s.needsName
        r.tags = s.tags
        r.capturedRoomFile = s.capturedRoomFile
        r.isKitchenOverride = s.isKitchenOverride
        r.activePlanID = s.activePlanID
        r.boundaryEdited = s.boundaryEdited
        r.sectionsSplit = s.sectionsSplit
        r.place = place
        context.insert(r)

        for z in s.zones {
            let m = Zone(name: z.name, kind: .other)
            m.uid = z.uid
            m.kindRaw = z.kindRaw
            m.posX = z.posX
            m.posY = z.posY
            m.posZ = z.posZ
            m.sizeW = z.sizeW
            m.sizeH = z.sizeH
            m.sizeD = z.sizeD
            m.yaw = z.yaw
            m.isIdea = z.isIdea
            m.createdAt = z.createdAt
            m.arX = z.arX
            m.arY = z.arY
            m.arZ = z.arZ
            m.parentID = z.parentID
            m.notes = z.notes
            m.kitchenZone = z.kitchenZone
            m.room = r
            context.insert(m)
        }
        for i in s.items {
            let m = Item(name: i.name)
            m.uid = i.uid
            m.category = i.category
            m.tags = i.tags
            m.notes = i.notes
            m.quantity = i.quantity
            m.hasBox = i.hasBox
            m.boxX = i.boxX
            m.boxY = i.boxY
            m.boxW = i.boxW
            m.boxH = i.boxH
            m.posX = i.posX
            m.posY = i.posY
            m.posZ = i.posZ
            m.outOfPlace = i.outOfPlace
            m.actionRaw = i.actionRaw
            m.reason = i.reason
            m.isSorted = i.isSorted
            m.zoneID = i.zoneID
            m.suggestedZoneID = i.suggestedZoneID
            m.captureID = i.captureID
            m.thumbFile = i.thumbFile
            m.createdAt = i.createdAt
            m.updatedAt = i.updatedAt
            m.sizeLengthCM = i.sizeLengthCM
            m.sizeWidthCM = i.sizeWidthCM
            m.sizeHeightCM = i.sizeHeightCM
            m.sizeSource = i.sizeSource
            m.expiresAt = i.expiresAt
            m.arX = i.arX
            m.arY = i.arY
            m.arZ = i.arZ
            m.room = r
            context.insert(m)
        }
        for st in s.steps {
            let m = TidyStep(title: st.title)
            m.uid = st.uid
            m.detail = st.detail
            m.minutes = st.minutes
            m.trip = st.trip
            m.sortKey = st.sortKey
            m.statusRaw = st.statusRaw
            m.completedAt = st.completedAt
            m.itemID = st.itemID
            m.createdAt = st.createdAt
            m.planID = st.planID
            m.room = r
            context.insert(m)
        }
        for c in s.captures {
            let m = Capture(file: c.file)
            m.uid = c.uid
            m.statusRaw = c.statusRaw
            m.error = c.error
            m.itemCount = c.itemCount
            m.createdAt = c.createdAt
            m.latitude = c.latitude
            m.longitude = c.longitude
            m.geoAccuracyM = c.geoAccuracyM
            m.room = r
            context.insert(m)
        }
        for d in s.designs {
            let m = DesignVariant(name: d.name)
            m.uid = d.uid
            m.style = d.style
            m.rationale = d.rationale
            m.tips = d.tips
            m.scoreOverall = d.scoreOverall
            m.scoreFlow = d.scoreFlow
            m.scoreCalm = d.scoreCalm
            m.isCurrent = d.isCurrent
            m.piecesData = d.piecesData
            m.renderFile = d.renderFile
            m.createdAt = d.createdAt
            m.provider = d.provider
            m.parentID = d.parentID
            m.version = d.version
            m.room = r
            context.insert(m)
        }
        for p in s.plans {
            let m = TidyPlan(provider: p.provider)
            m.uid = p.uid
            m.energy = p.energy
            m.minutes = p.minutes
            m.pepTalk = p.pepTalk
            m.feedback = p.feedback
            m.version = p.version
            m.parentID = p.parentID
            m.createdAt = p.createdAt
            m.room = r
            context.insert(m)
        }
    }
}

// MARK: Views

/// "Share": pick what goes in, make the file, send it.
struct ShareSheetView: View {
    let place: Place
    var room: Room?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("share.senderName") private var sharedBy = ""
    @State private var options = ShareOptions()
    @State private var url: URL?
    @State private var making = false
    @State private var errorText: String?

    private var title: String { room.map { "\($0.name) (\(place.name))" } ?? place.name }
    private var rooms: [Room] { room.map { [$0] } ?? place.sortedRooms }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title).font(.display(.title3))
                    let things = rooms.reduce(0) { $0 + $1.items.count }
                    let photos = rooms.reduce(0) { $0 + $1.captures.count }
                    Text("\(rooms.count) room\(rooms.count == 1 ? "" : "s") · \(things) things · \(photos) photos")
                        .font(.footnote).foregroundStyle(.secondary)
                } footer: {
                    Text("Everything goes along: the map and room boundaries, storage spots, things and where they go, tidy plans, designs and the design chat, LiDAR scans and scan history, map versions, the change history and shopping ideas. The other person needs Tidy Atlas; sending it again later updates their copy.")
                }
                Section("What to include") {
                    Toggle("Photos", isOn: $options.photos)
                    Toggle("Location (GPS and address)", isOn: $options.location)
                    Toggle("Change history", isOn: $options.history)
                }
                Section("Message") {
                    TextField("Your name", text: $sharedBy)
                    TextField("A note (optional)", text: $options.note, axis: .vertical)
                }
                Section {
                    if let url {
                        ShareLink(item: url, preview: SharePreview("Tidy Atlas: \(title)")) {
                            Label("Send…", systemImage: "square.and.arrow.up").font(.headline)
                        }
                        Text("AirDrop, Messages, Mail, WhatsApp or Google Drive all work. On their iPhone, tapping the file opens it in Tidy Atlas.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button {
                            make()
                        } label: {
                            if making { ProgressView() } else { Label("Make the share file", systemImage: "shippingbox") }
                        }
                        .disabled(making)
                    }
                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
                }
                if let model = model3D {
                    Section {
                        ShareLink(item: model) { Label("Share just the 3D model", systemImage: "cube") }
                    } footer: {
                        Text("A USDZ file anyone can open in AR on an iPhone, iPad or Mac, without Tidy Atlas.")
                    }
                }
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: options.photos) { _, _ in url = nil }
            .onChange(of: options.location) { _, _ in url = nil }
            .onChange(of: options.history) { _, _ in url = nil }
            .onChange(of: options.note) { _, _ in url = nil }
            .onChange(of: sharedBy) { _, _ in url = nil }
        }
    }

    private var model3D: URL? {
        let file = room.map { $0.usdzFile } ?? place.houseScanFile
        guard let file else { return nil }
        let u = Storage.roomScanURL(file)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func make() {
        making = true
        errorText = nil
        var o = options
        o.sharedBy = sharedBy
        Task {
            defer { making = false }
            do {
                url = try await ShareExport.make(place: place, room: room, options: o, context: context)
                ActivityLog.add(.map, "Shared \(title)", room: room, in: context)
                try? context.save()
            } catch {
                errorText = "Couldn't make the share file: \(error.localizedDescription)"
            }
        }
    }
}

/// Someone sent a place or room: show what's in it and add it.
struct ImportShareView: View {
    let share: IncomingShare
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var organizer: Organizer
    @Query private var places: [Place]
    @State private var adding = false
    @State private var done: Place?
    @State private var errorText: String?

    var body: some View {
        let pkg = share.package
        let existing = places.first { $0.uid == pkg.place.uid }
        let replacing = existing.map { p in p.rooms.filter { r in pkg.rooms.contains { $0.uid == r.uid } }.count } ?? 0
        NavigationStack {
            Form {
                Section {
                    Label(pkg.title, systemImage: "shippingbox.fill").font(.display(.title3))
                    Text("From \(pkg.sharedBy.isEmpty ? "someone" : pkg.sharedBy) · \(pkg.sharedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !pkg.note.isEmpty { Text("“\(pkg.note)”") }
                }
                Section("Inside") {
                    LabeledContent("Rooms", value: pkg.rooms.map(\.name).joined(separator: ", "))
                    LabeledContent("Things", value: "\(pkg.thingCount)")
                    LabeledContent("Photos", value: "\(pkg.photoCount)")
                    LabeledContent("Plans · designs", value: "\(pkg.rooms.reduce(0) { $0 + $1.plans.count }) · \(pkg.rooms.reduce(0) { $0 + $1.designs.count })")
                    LabeledContent("Scans · map versions", value: "\(pkg.scans.count) · \(pkg.mapVersions.count)")
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: share.bytes, countStyle: .file))
                }
                Section {
                    if let done {
                        Label("Added to \(done.name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Open the map") {
                            UserDefaults.standard.set(done.uid.uuidString, forKey: "map.placeID")
                            router.tab = 1
                            dismiss()
                        }
                    } else {
                        Button {
                            add()
                        } label: {
                            if adding { ProgressView() } else { Label(existing == nil ? "Add to Tidy Atlas" : "Update \(existing?.name ?? "")", systemImage: "square.and.arrow.down") }
                        }
                        .disabled(adding)
                    }
                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
                } footer: {
                    if existing != nil {
                        Text(replacing > 0
                             ? "You already have this place. \(replacing) room\(replacing == 1 ? "" : "s") you got before will be replaced by this newer version; your other rooms stay."
                             : "You already have this place; these rooms are added to it.")
                    } else {
                        Text("It's added as a new place. Your own places and rooms are not changed.")
                    }
                }
            }
            .navigationTitle("Shared with you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(done == nil ? "Cancel" : "Close") { dismiss() } } }
        }
    }

    private func add() {
        adding = true
        errorText = nil
        Task {
            defer { adding = false }
            do {
                done = try await ShareImport.add(share, context: context)
                Haptics.success()
                organizer.scheduleDriveSync()
            } catch {
                errorText = "Couldn't add it: \(error.localizedDescription)"
            }
        }
    }
}

/// Settings: open a share file saved in Files or Google Drive.
struct ReceiveShareSection: View {
    @EnvironmentObject private var router: AppRouter
    @State private var picking = false
    @State private var errorText: String?

    var body: some View {
        Section {
            Button { picking = true } label: { Label("Open a share file", systemImage: "tray.and.arrow.down") }
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Sharing")
        } footer: {
            Text("To share, tap the share button on a place or in a room's menu. Files someone sent you usually open by tapping them; use this for files saved in Files or Google Drive.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.tidyAtlasShare, .data]) { result in
            switch result {
            case let .success(url):
                do { router.incomingShare = try ShareImport.open(url) } catch { errorText = error.localizedDescription }
            case let .failure(error):
                errorText = error.localizedDescription
            }
        }
    }
}
