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

    init(name: String, kind: PlaceKind) {
        self.name = name
        self.kindRaw = kind.rawValue
    }

    var kind: PlaceKind {
        get { PlaceKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var sortedRooms: [Room] { rooms.sorted { $0.createdAt < $1.createdAt } }
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
    var createdAt: Date = Date()
    var place: Place?
    @Relationship(deleteRule: .cascade, inverse: \Zone.room) var zones: [Zone] = []
    @Relationship(deleteRule: .cascade, inverse: \Item.room) var items: [Item] = []
    @Relationship(deleteRule: .cascade, inverse: \TidyStep.room) var steps: [TidyStep] = []
    @Relationship(deleteRule: .cascade, inverse: \Capture.room) var captures: [Capture] = []

    init(name: String) {
        self.name = name
    }

    var layout: RoomLayout? {
        get { layoutData.flatMap { try? JSONDecoder().decode(RoomLayout.self, from: $0) } }
        set { layoutData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var toSort: [Item] { items.filter { !$0.isSorted } }
    var todoSteps: [TidyStep] { steps.filter { $0.status == .todo }.sorted { $0.sortKey < $1.sortKey } }
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
    var room: Room?

    init(name: String, kind: ZoneKind) {
        self.name = name
        self.kindRaw = kind.rawValue
    }

    var kind: ZoneKind {
        get { ZoneKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
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
    var room: Room?

    init(name: String) {
        self.name = name
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
    var room: Room?

    init(file: String) {
        self.file = file
    }

    var status: CaptureStatus {
        get { CaptureStatus(rawValue: statusRaw) ?? .waiting }
        set { statusRaw = newValue.rawValue }
    }
}
