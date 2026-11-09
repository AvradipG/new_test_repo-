import Foundation
import SwiftData
import TidyCore

// The on-phone database (SwiftData). Enums are stored as raw strings, links between items and zones as ids,
// so older data keeps loading when fields are added later (add new fields with default values).

@Model
final class Place {
    var uid: UUID = UUID()
    var name: String = ""
    var kindRaw: String = PlaceKind.home.rawValue
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \Room.place) var rooms: [Room] = []
    // Geotag from the whole-place scan (or the first GPS fix): where the scan started, how accurate, and which
    // compass bearing the scan's −Z axis points to, so every scan position can be turned into GPS coordinates.
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var geoAccuracyM: Double?
    var floorLevel: Int?
    var address: String?
    var northBearing: Double?
    /// USDZ of the whole-place LiDAR scan in Documents/RoomScans.
    var houseScanFile: String?
    var houseScannedAt: Date?
    /// ARKit world map of the place (Documents/WorldMaps), so later scans join the same map.
    var worldMapFile: String?
    @Relationship(deleteRule: .cascade, inverse: \ScanRecord.place) var scans: [ScanRecord] = []

    init(name: String, kind: PlaceKind) {
        self.name = name
        self.kindRaw = kind.rawValue
    }

    var kind: PlaceKind {
        get { PlaceKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var sortedRooms: [Room] { rooms.sorted { $0.createdAt < $1.createdAt } }

    var geo: GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    /// Rooms that have a place on the map, and their footprints in the place frame.
    var mappedRooms: [(Room, RoomPlacement)] { sortedRooms.compactMap { r in r.placement.map { (r, $0) } } }

    /// GPS position of a point in the whole-place scan.
    func locate(x: Double, z: Double) -> GeoPoint? {
        guard let geo else { return nil }
        guard let b = northBearing else { return geo }
        return GeoMath.locate(x: x, z: z, origin: geo, bearingOfMinusZ: b)
    }
}

@Model
final class Room {
    var uid: UUID = UUID()
    var name: String = ""
    var roomType: String = ""
    var summary: String = ""
    var widthM: Double = 4
    var depthM: Double = 4
    var heightM: Double = 2.6
    var clutterScore: Int?
    /// True once a LiDAR room scan has set the size, so photos don't overwrite it.
    var sizeFromScan: Bool = false
    /// JSON of `RoomLayout` from a RoomPlan scan.
    var layoutData: Data?
    /// File name of the RoomPlan USDZ in Documents/RoomScans.
    var usdzFile: String?
    /// File name of the saved ARKit world map in Documents/WorldMaps, so AR labels come back in the same spots.
    var worldMapFile: String?
    var createdAt: Date = Date()
    var place: Place?
    /// Scanned as part of a whole-place scan: its layout's origin is in the place's shared scan frame.
    var fromHouseScan: Bool = false
    /// RoomPlan's own guess of the room type (bedroom, kitchen…).
    var sectionLabel: String?
    @Relationship(deleteRule: .cascade, inverse: \Zone.room) var zones: [Zone] = []
    @Relationship(deleteRule: .cascade, inverse: \Item.room) var items: [Item] = []
    @Relationship(deleteRule: .cascade, inverse: \TidyStep.room) var steps: [TidyStep] = []
    @Relationship(deleteRule: .cascade, inverse: \Capture.room) var captures: [Capture] = []
    @Relationship(deleteRule: .cascade, inverse: \DesignVariant.room) var designs: [DesignVariant] = []
    /// Design-studio chat (JSON of [DesignMessage]).
    var designChatData: Data?
    /// Compass bearing of the far wall, set by hand for rooms not scanned with the whole place.
    var northBearingOverride: Double?
    /// Which wall the entrance is on, for the Feng Shui bagua map.
    var entranceRaw: String?
    /// Hand correction of where the room sits on the place map (overrides the scan's own position).
    var mapX: Double?
    var mapZ: Double?
    var mapRotationDeg: Double = 0
    /// Scanned but not named yet ("Name later").
    var needsName: Bool = false
    var tags: [String] = []
    /// Latest raw RoomPlan scan of this room (JSON, Documents/RoomScans), kept so new app features can re-read it.
    var capturedRoomFile: String?
    /// nil = decide from the room's name and type.
    var isKitchenOverride: Bool?
    /// The tidy plan whose steps are shown (plans from Claude and ChatGPT are all kept).
    var activePlanID: UUID?
    @Relationship(deleteRule: .cascade, inverse: \TidyPlan.room) var plans: [TidyPlan] = []

    init(name: String) {
        self.name = name
    }

    /// Compass bearing of the far wall (the room's −Z direction), when known.
    var bearing: Double? {
        if let o = northBearingOverride { return o }
        if placement != nil, let b = place?.northBearing { return GeoMath.normalize(b + mapRotationDeg) }
        return nil
    }

    /// Where the room is on its place's map: a hand correction, or its position in the whole-place scan.
    var placement: RoomPlacement? {
        if let x = mapX, let z = mapZ { return RoomPlacement(x: x, z: z, rotationDeg: mapRotationDeg) }
        if fromHouseScan, let l = layout, let x = l.originX, let z = l.originZ { return RoomPlacement(x: x, z: z, rotationDeg: mapRotationDeg) }
        return nil
    }

    var isKitchen: Bool {
        if let o = isKitchenOverride { return o }
        return [name, roomType, sectionLabel ?? ""].contains { $0.lowercased().contains("kitchen") }
    }

    var displayName: String { needsName ? "\(name) (name me)" : name }

    /// Storage spots as a tree.
    var storageNodes: [StorageTree.Node] { zones.map { StorageTree.Node(id: $0.uid, parent: $0.parentID, name: $0.name) } }

    /// "Desk › Top drawer › Tray".
    func zonePath(_ id: UUID?) -> String? {
        guard let id, zones.contains(where: { $0.uid == id }) else { return nil }
        return StorageTree.path(of: id, in: storageNodes)
    }

    func children(of zone: Zone?) -> [Zone] {
        let ids = Set(StorageTree.children(of: zone?.uid, in: storageNodes).map(\.id))
        return zones.filter { ids.contains($0.uid) }.sorted { $0.createdAt < $1.createdAt }
    }

    var activePlan: TidyPlan? { plans.first { $0.uid == activePlanID } }

    var entrance: SpaceWisdom.Entrance {
        get { SpaceWisdom.Entrance(rawValue: entranceRaw ?? "") ?? .near }
        set { entranceRaw = newValue.rawValue }
    }

    var sortedDesigns: [DesignVariant] { designs.sorted { ($0.isCurrent ? 0 : 1, $0.createdAt) < ($1.isCurrent ? 0 : 1, $1.createdAt) } }

    /// The room as it is: scanned furniture (LiDAR) and storage spots as separate, movable pieces.
    func scannedPieces() -> [DesignPiece] {
        var pieces: [DesignPiece] = []
        var usedZones = Set<UUID>()
        if let l = layout {
            for o in l.objects {
                let k = FurnitureCatalog.scannedKind(o.label)
                // Link to the storage spot made from the same furniture, if any.
                let zone = zones.first { z in
                    abs((z.posX - 0.5) * widthM - o.cx) < 0.3 && abs((z.posZ - 0.5) * depthM - o.cz) < 0.3 && !usedZones.contains(z.uid)
                }
                if let zone { usedZones.insert(zone.uid) }
                pieces.append(DesignPiece(kind: k.kind, name: zone?.name ?? k.name, x: o.cx, z: o.cz,
                                          width: max(o.width, 0.1), depth: max(o.depth, 0.1), height: max(o.height, 0.05),
                                          rotationDeg: GeoMath.normalize(-o.yaw * 180 / .pi), source: "scanned", zoneID: zone?.uid))
            }
        }
        // Only top-level spots are furniture; drawers and trays inside them move with them.
        for z in zones where !usedZones.contains(z.uid) && !z.isIdea && z.parentID == nil {
            let kind: String
            switch z.kind {
            case .bed: kind = "bed_double"
            case .desk: kind = "desk"
            case .table: kind = "dining_4"
            case .shelf: kind = "bookshelf"
            case .closet: kind = "wardrobe"
            case .cabinet, .drawer: kind = "dresser"
            case .bin: kind = "cube_storage"
            case .hook: kind = "wall_hooks"
            default: kind = "custom"
            }
            let onWall = kind == "wall_hooks"
            var p = DesignPiece(kind: kind, name: z.name, x: (z.posX - 0.5) * widthM, z: (z.posZ - 0.5) * depthM,
                                y: onWall ? 1.6 : 0, width: max(z.sizeW, 0.2), depth: max(z.sizeD, 0.1), height: max(z.sizeH, 0.1),
                                rotationDeg: GeoMath.normalize(-z.yaw * 180 / .pi), onWall: onWall, source: "scanned", zoneID: z.uid)
            p = DesignGeometry.clamp(p, width: widthM, depth: depthM)
            pieces.append(p)
        }
        return pieces
    }

    /// The "As it is" design, made on first use.
    @discardableResult
    func currentDesign(context: ModelContext) -> DesignVariant {
        if let d = designs.first(where: \.isCurrent) { return d }
        let d = DesignVariant(name: "As it is")
        d.isCurrent = true
        d.pieces = scannedPieces()
        d.room = self
        context.insert(d)
        return d
    }

    var layout: RoomLayout? {
        get { layoutData.flatMap { try? JSONDecoder().decode(RoomLayout.self, from: $0) } }
        set { layoutData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var toSort: [Item] { items.filter { !$0.isSorted } }

    /// GPS position of a point given in this room's unit coordinates (rough), when the room has a geotag.
    func locate(unitX: Double, unitZ: Double) -> GeoPoint? {
        guard let place else { return nil }
        if let p = placement {
            let q = p.toPlace(x: (unitX - 0.5) * widthM, z: (unitZ - 0.5) * depthM)
            return place.locate(x: q.x, z: q.z)
        }
        return place.geo
    }

    var geo: GeoPoint? { locate(unitX: 0.5, unitZ: 0.5) }
    /// Steps of the active plan (steps made before plans were saved have no plan).
    var todoSteps: [TidyStep] {
        steps.filter { $0.status == .todo && $0.planID == activePlanID }.sorted { $0.sortKey < $1.sortKey }
    }
    func zone(_ id: UUID?) -> Zone? { id.flatMap { id in zones.first { $0.uid == id } } }
    func capture(_ id: UUID?) -> Capture? { id.flatMap { id in captures.first { $0.uid == id } } }
}

@Model
final class Zone {
    var uid: UUID = UUID()
    var name: String = ""
    var kindRaw: String = ZoneKind.other.rawValue
    var posX: Double = 0.5
    var posY: Double = 0
    var posZ: Double = 0.5
    var sizeW: Double = 0.8
    var sizeH: Double = 0.8
    var sizeD: Double = 0.4
    var yaw: Double = 0
    /// A storage idea from Claude that isn't set up in the room yet.
    var isIdea: Bool = false
    var createdAt: Date = Date()
    /// Position in the room's AR world map (metres), when placed in AR.
    var arX: Double?
    var arY: Double?
    var arZ: Double?
    /// The spot this one is inside (a drawer in a desk), nil at the top level.
    var parentID: UUID?
    /// Kitchen zone (Kitchen.ZoneType raw value) for kitchen storage.
    var kitchenZone: String?
    var room: Room?

    init(name: String, kind: ZoneKind) {
        self.name = name
        self.kindRaw = kind.rawValue
    }

    var kind: ZoneKind {
        get { ZoneKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var arPosition: SIMD3<Float>? {
        guard let x = arX, let y = arY, let z = arZ else { return nil }
        return SIMD3(Float(x), Float(y), Float(z))
    }
}

@Model
final class Item {
    var uid: UUID = UUID()
    var name: String = ""
    var category: String = "other"
    var tags: [String] = []
    var notes: String = ""
    var quantity: Int = 1
    var hasBox: Bool = false
    var boxX: Double = 0
    var boxY: Double = 0
    var boxW: Double = 0
    var boxH: Double = 0
    var posX: Double = 0.5
    var posY: Double = 0
    var posZ: Double = 0.5
    var outOfPlace: Bool = false
    var actionRaw: String = ItemAction.keep.rawValue
    var reason: String = ""
    var isSorted: Bool = false
    var zoneID: UUID?
    var suggestedZoneID: UUID?
    var captureID: UUID?
    var thumbFile: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Real size in centimetres, longest side first, then height. `sizeSource` is "LiDAR" or "estimate".
    var sizeLengthCM: Double?
    var sizeWidthCM: Double?
    var sizeHeightCM: Double?
    var sizeSource: String?
    /// Use-by date for food.
    var expiresAt: Date?
    /// Position in the room's AR world map (metres), when seen in AR with LiDAR.
    var arX: Double?
    var arY: Double?
    var arZ: Double?
    var room: Room?

    init(name: String) {
        self.name = name
    }

    var sizeText: String? {
        guard let l = sizeLengthCM, let w = sizeWidthCM, let h = sizeHeightCM else { return nil }
        let t = DepthMeasure.label(length: l, width: w, height: h)
        guard !t.isEmpty else { return nil }
        return sizeSource == "LiDAR" ? t + " (LiDAR)" : "≈ " + t
    }

    var arPosition: SIMD3<Float>? {
        guard let x = arX, let y = arY, let z = arZ else { return nil }
        return SIMD3(Float(x), Float(y), Float(z))
    }

    var action: ItemAction {
        get { ItemAction(rawValue: actionRaw) ?? .decide }
        set { actionRaw = newValue.rawValue }
    }

    var box: PhotoBox? { hasBox ? PhotoBox(x: boxX, y: boxY, w: boxW, h: boxH) : nil }

    /// "I put it away": moves it to its suggested spot and marks it done.
    func putAway() {
        if let s = suggestedZoneID { zoneID = s }
        isSorted = true
        outOfPlace = false
        updatedAt = Date()
    }
}

/// One design of a room: a set of movable pieces (the room as it is, or an idea from the owner or the AI designer).
@Model
final class DesignVariant {
    var uid: UUID = UUID()
    var name: String = ""
    var style: String = ""
    var rationale: String = ""
    var tips: [String] = []
    var scoreOverall: Double?
    var scoreFlow: Double?
    var scoreCalm: Double?
    /// The room as it really is (only one per room).
    var isCurrent: Bool = false
    /// JSON of [DesignPiece].
    var piecesData: Data?
    /// "How it will look" picture made by ChatGPT, in Documents/Designs.
    var renderFile: String?
    var createdAt: Date = Date()
    /// "Claude", "ChatGPT" or nil (made by hand).
    var provider: String?
    /// The design this one improves on.
    var parentID: UUID?
    var version: Int = 1
    var room: Room?

    init(name: String) {
        self.name = name
    }

    var pieces: [DesignPiece] {
        get { piecesData.flatMap { try? JSONDecoder().decode([DesignPiece].self, from: $0) } ?? [] }
        set { piecesData = try? JSONEncoder().encode(newValue) }
    }
}

/// One message in a room's design chat.
struct DesignMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var fromUser: Bool
    var text: String
    var provider: String?
    /// The design made from this answer's proposal, if any.
    var designID: UUID?
    var date = Date()
}

extension Room {
    var designChat: [DesignMessage] {
        get { designChatData.flatMap { try? JSONDecoder().decode([DesignMessage].self, from: $0) } ?? [] }
        set { designChatData = try? JSONEncoder().encode(newValue) }
    }
}

/// One saved tidy plan. Plans from Claude and ChatGPT are kept separately and can be improved into new versions.
@Model
final class TidyPlan {
    var uid: UUID = UUID()
    var provider: String = ""
    var energy: String = ""
    var minutes: Int = 15
    var pepTalk: String = ""
    /// What the owner asked to change, for improved versions.
    var feedback: String = ""
    var version: Int = 1
    var parentID: UUID?
    var createdAt: Date = Date()
    var room: Room?

    init(provider: String) {
        self.provider = provider
    }

    var label: String { "\(provider) v\(version) · \(createdAt.formatted(date: .abbreviated, time: .shortened))" }
}

/// One scan of a place, kept for good: the place model, every room's raw scan, and what it changed.
@Model
final class ScanRecord {
    var uid: UUID = UUID()
    /// "Whole place", "Added rooms", "Rescanned room" or "Single room".
    var kind: String = ""
    var date: Date = Date()
    var roomNames: [String] = []
    /// Raw RoomPlan scans (Documents/RoomScans) by room id, JSON of [String: String].
    var roomFilesData: Data?
    /// The place model as it was after this scan.
    var usdzFile: String?
    /// The scan found its way back into the saved map (false: rooms were placed by hand).
    var joinedMap: Bool = false
    var place: Place?

    init(kind: String) {
        self.kind = kind
    }

    var roomFiles: [String: String] {
        get { roomFilesData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
        set { roomFilesData = try? JSONEncoder().encode(newValue) }
    }
}

/// Something worth buying, suggested by the designer or the kitchen organiser.
@Model
final class ShoppingItem {
    var uid: UUID = UUID()
    var name: String = ""
    var category: String = ""
    var priceUSD: Double?
    var why: String = ""
    var provider: String = ""
    var roomName: String = ""
    var bought: Bool = false
    var createdAt: Date = Date()

    init(name: String) {
        self.name = name
    }

    var searchURL: URL? {
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "tbm", value: "shop"), URLQueryItem(name: "q", value: name)]
        return c?.url
    }
}

enum StepStatus: String { case todo, done, skipped }

@Model
final class TidyStep {
    var uid: UUID = UUID()
    var title: String = ""
    var detail: String = ""
    var minutes: Int = 2
    var trip: Int = 1
    var sortKey: Double = 0
    var statusRaw: String = StepStatus.todo.rawValue
    var completedAt: Date?
    var itemID: UUID?
    var createdAt: Date = Date()
    var planID: UUID?
    var room: Room?

    init(title: String) {
        self.title = title
    }

    var status: StepStatus {
        get { StepStatus(rawValue: statusRaw) ?? .todo }
        set { statusRaw = newValue.rawValue }
    }
}

enum CaptureStatus: String { case waiting, analyzing, analyzed, failed }

@Model
final class Capture {
    var uid: UUID = UUID()
    /// JPEG file name in Documents/Captures.
    var file: String = ""
    var statusRaw: String = CaptureStatus.waiting.rawValue
    var error: String?
    var itemCount: Int = 0
    var createdAt: Date = Date()
    /// Where the phone was when the photo was taken (GPS), if location is allowed.
    var latitude: Double?
    var longitude: Double?
    var geoAccuracyM: Double?
    var room: Room?

    init(file: String) {
        self.file = file
    }

    var status: CaptureStatus {
        get { CaptureStatus(rawValue: statusRaw) ?? .waiting }
        set { statusRaw = newValue.rawValue }
    }
}
