import ARKit
import CoreLocation
import RoomPlan
import SwiftUI
import TidyCore

/// One finished room of a whole-place scan.
struct ScannedRoom: Identifiable {
    let id = UUID()
    var name: String
    var room: CapturedRoom
    /// "Name later" was tapped.
    var needsName = false
}

/// Geotag taken when the whole-place scan starts.
struct ScanGeotag {
    var location: CLLocation
    /// Compass bearing of the scan's −Z axis (nil if the compass wasn't available).
    var northBearing: Double?
    var address: String?
}

/// Whole-place LiDAR scan: one ARKit session kept running from room to room, so every room lands in one shared
/// frame; Apple's RoomBuilder finishes each room and StructureBuilder merges them into one model of the place.
@MainActor
final class HouseScanModel: ObservableObject {
    enum Phase: Equatable { case intro, relocalizing, scanning, processing, naming, finishing, failed(String) }

    let arSession = ARSession()
    lazy var captureView: RoomCaptureView = {
        let v = RoomCaptureView(frame: .zero, arSession: arSession)
        v.delegate = coordinator
        return v
    }()
    let coordinator = HouseScanCoordinator()
    @Published var phase = Phase.intro
    @Published var rooms: [ScannedRoom] = []
    @Published var pendingRoom: CapturedRoom?
    @Published var suggestedName = ""
    @Published var geotag: ScanGeotag?
    /// The scan found the place's saved map, so new rooms land in the right spot.
    @Published var joinedMap = false
    private let location = LocationService.shared
    /// Saved map of the place when adding rooms to an earlier scan.
    var savedMap: ARWorldMap?
    var wantsGeotag = true
    /// Adding to an earlier scan (rooms added or rescanned) rather than starting a new map.
    var extending = false

    init() {
        coordinator.onData = { [weak self] data in
            Task { @MainActor in await self?.build(data) }
        }
    }

    static var isSupported: Bool { RoomCaptureSession.isSupported }

    func begin() {
        location.startTracking()
        guard let map = savedMap else {
            joinedMap = !extending // a fresh scan defines the map; an extension without a saved map can't join it
            startRoom()
            return
        }
        // Adding to an earlier scan: find the old map first, so new rooms share its frame.
        phase = .relocalizing
        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = map
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        Task { @MainActor in
            var sawRelocalizing = false
            for _ in 0..<90 {
                guard phase == .relocalizing else { return }
                try? await Task.sleep(for: .milliseconds(500))
                guard let state = arSession.currentFrame?.camera.trackingState else { continue }
                if case .limited(.relocalizing) = state { sawRelocalizing = true }
                if case .normal = state, sawRelocalizing || arSession.currentFrame?.anchors.isEmpty == false {
                    joinedMap = true
                    startRoom()
                    return
                }
            }
        }
    }

    /// Couldn't find the old map: scan anyway; the rooms are placed by hand on the map afterwards.
    func skipRelocalization() {
        joinedMap = false
        startRoom()
    }

    func startRoom() {
        phase = .scanning
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        if geotag == nil && wantsGeotag {
            Task { @MainActor in
                // Wait for the camera to be tracking and for a first GPS fix.
                for _ in 0..<30 where geotag == nil {
                    try? await Task.sleep(for: .seconds(1))
                    captureGeotag()
                }
            }
        }
    }

    /// GPS where the scan starts, and the compass bearing of the scan's −Z axis.
    private func captureGeotag() {
        guard geotag == nil, let loc = location.location, loc.horizontalAccuracy >= 0,
              let frame = arSession.currentFrame, case .normal = frame.camera.trackingState else { return }
        var bearing: Double?
        if let h = location.heading {
            let compass = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
            let fwd = -frame.camera.transform.columns.2
            bearing = GeoMath.bearingOfMinusZ(headingDegrees: compass, forwardX: Double(fwd.x), forwardZ: Double(fwd.z))
        }
        geotag = ScanGeotag(location: loc, northBearing: bearing, address: nil)
        Task { @MainActor in
            if let a = await LocationService.address(for: loc) { geotag?.address = a }
        }
    }

    func finishRoom() {
        phase = .processing
        captureView.captureSession.stop(pauseARSession: false)
    }

    private func build(_ data: CapturedRoomData) async {
        do {
            let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
            pendingRoom = room
            suggestedName = Self.suggestedName(for: room, existing: rooms.map(\.name))
            phase = .naming
        } catch {
            phase = .failed("That room couldn't be put together: \(error.localizedDescription). Scan it again.")
        }
    }

    static func suggestedName(for room: CapturedRoom, existing: [String]) -> String {
        let raw = room.sections.first.map { String(describing: $0.label) } ?? ""
        let names = ["bedroom": "Bedroom", "bathroom": "Bathroom", "kitchen": "Kitchen", "livingRoom": "Living room",
                     "diningRoom": "Dining room"]
        let base = names[raw] ?? "Room"
        var name = base
        var n = 2
        while existing.contains(name) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    func keepRoom(named name: String) {
        guard let room = pendingRoom else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        rooms.append(ScannedRoom(name: clean.isEmpty ? suggestedName : clean, room: room))
        pendingRoom = nil
    }

    /// Keep the room without a name for now; it shows up as "Name me" later.
    func keepRoomUnnamed(number: Int) {
        guard let room = pendingRoom else { return }
        rooms.append(ScannedRoom(name: "Unnamed room \(number)", room: room, needsName: true))
        pendingRoom = nil
    }

    func discardRoom() {
        pendingRoom = nil
        startRoom()
    }

    /// Saves the AR map of everything seen so far (for adding rooms later). Returns the file name.
    func saveWorldMap(fileStem: String) async -> String? {
        let map: ARWorldMap? = await withCheckedContinuation { cont in
            arSession.getCurrentWorldMap { map, _ in cont.resume(returning: map) }
        }
        guard let map, let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true) else { return nil }
        let name = "\(fileStem)-place-\(Int(Date().timeIntervalSince1970)).arworldmap"
        return (try? data.write(to: Storage.worldMapURL(name), options: .atomic)) != nil ? name : nil
    }

    /// Merges the rooms (plus earlier rooms that share the map) into one model of the place. Returns the USDZ file
    /// name (in Documents/RoomScans), if any. Earlier models are kept.
    func finish(fileStem: String, earlierRooms: [CapturedRoom] = []) async -> String? {
        phase = .finishing
        location.stopTracking()
        guard !rooms.isEmpty else { arSession.pause(); return nil }
        let name = "\(fileStem)-place-\(Int(Date().timeIntervalSince1970)).usdz"
        let url = Storage.roomScanURL(name)
        defer { arSession.pause() }
        do {
            let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: earlierRooms + rooms.map(\.room))
            try structure.export(to: url)
            return name
        } catch {
            // One room, or merging failed: the first room still gives a model of the place.
            if (try? rooms[0].room.export(to: url, metadataURL: nil, modelProvider: nil, exportOptions: .mesh)) != nil { return name }
            return nil
        }
    }

    func cancel() {
        if phase == .scanning { captureView.captureSession.stop(pauseARSession: true) }
        arSession.pause()
        location.stopTracking()
    }
}

/// RoomCaptureViewDelegate inherits NSCoding, so the class needs a fixed Objective-C name.
@objc(TAHouseScanCoordinator)
final class HouseScanCoordinator: NSObject, RoomCaptureViewDelegate {
    var onData: (CapturedRoomData) -> Void = { _ in }

    override init() { super.init() }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    /// Each room's raw data comes here; the app builds it itself instead of showing RoomPlan's result screen,
    /// so the walk can go straight on to the next room.
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        let data = roomDataForProcessing
        DispatchQueue.main.async { self.onData(data) }
        return false
    }
}

struct HouseCaptureRepresentable: UIViewRepresentable {
    let model: HouseScanModel
    func makeUIView(context: Context) -> RoomCaptureView { model.captureView }
    func updateUIView(_ view: RoomCaptureView, context: Context) {}
}

/// The whole-place scan screen.
struct HouseScanSheet: View {
    let place: Place?
    /// Add rooms to the place's earlier scan (instead of starting a new one).
    var addToMap = false
    /// Scan this one room again.
    var rescan: Room? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var organizer: Organizer
    @StateObject private var scan = HouseScanModel()
    @ObservedObject private var location = LocationService.shared
    @State private var roomName = ""
    @State private var placeName = ""

    var body: some View {
        ZStack {
            if scan.phase != .intro {
                HouseCaptureRepresentable(model: scan).ignoresSafeArea()
            } else {
                Palette.paper.ignoresSafeArea()
            }
            VStack(spacing: 12) {
                topBar
                Spacer()
                bottomPanel
            }
            .padding()
        }
        .onAppear {
            placeName = place?.name ?? "Home"
            if addToMap || rescan != nil, let f = place?.worldMapFile {
                scan.savedMap = ARRoomController.loadWorldMap(Storage.worldMapURL(f))
            }
            scan.wantsGeotag = place?.geo == nil
            scan.extending = addToMap || rescan != nil
        }
        .onDisappear { scan.cancel() }
    }

    private var topBar: some View {
        HStack {
            Button {
                scan.cancel()
                dismiss()
            } label: { Image(systemName: "xmark.circle.fill").font(.title) }
            .foregroundStyle(scan.phase == .intro ? Color.secondary : Color.white)
            Spacer()
            if scan.phase != .intro {
                Label(geoText, systemImage: scan.geotag == nil ? "location.circle" : "location.fill")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                Text("\(scan.rooms.count) room\(scan.rooms.count == 1 ? "" : "s")")
                    .font(.footnote.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var geoText: String {
        if let g = scan.geotag {
            return g.address ?? String(format: "%.5f, %.5f (±%.0f m)", g.location.coordinate.latitude,
                                       g.location.coordinate.longitude, g.location.horizontalAccuracy)
        }
        return location.isAllowed || location.authorization == .notDetermined ? "Finding GPS…" : "Location off: no geotag"
    }

    @ViewBuilder private var bottomPanel: some View {
        switch scan.phase {
        case .relocalizing:
            VStack(alignment: .leading, spacing: 10) {
                Label("Finding your earlier scan…", systemImage: "location.viewfinder").font(.headline)
                Text("Point the phone at a room you scanned before and move slowly, so the new scan joins the old map in the right spot.")
                    .font(.callout)
                Button("Can't find it: scan anyway, I'll place it on the map") { scan.skipRelocalization() }
                    .buttonStyle(.bordered)
            }
            .card()

        case .intro where rescan != nil || addToMap:
            VStack(alignment: .leading, spacing: 14) {
                Text(rescan.map { "Rescan \($0.name)" } ?? "Add rooms to \(placeName)").font(.display(.largeTitle))
                Text(rescan != nil
                     ? "Scan this room again to fix a scan that missed walls or furniture. The old scan stays in the history, and everything in the room stays."
                     : "Scan rooms you missed. The app first finds your earlier scan so the new rooms join the same map. If it can't, you place them on the map yourself.")
                    .foregroundStyle(.secondary)
                if place?.worldMapFile == nil {
                    Label("This place has no saved map yet (scanned with an older version). You'll place the new rooms on the map by hand.",
                          systemImage: "info.circle").font(.footnote)
                }
                Button {
                    scan.begin()
                } label: {
                    Label("Start scanning", systemImage: "viewfinder").frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!HouseScanModel.isSupported)
            }
            .card()

        case .intro:
            VStack(alignment: .leading, spacing: 14) {
                Text("Scan the whole place").font(.display(.largeTitle))
                Text("One walk through every room with the camera and LiDAR. Everything lands in one map of the place, and the phone's GPS and compass geotag it so the app knows where each room is.")
                    .foregroundStyle(.secondary)
                Label("Start in the first room. Walk slowly along the walls, pointing at walls, doors and furniture.", systemImage: "1.circle.fill")
                Label("Tap \"Done with this room\", name it, then walk through the door and scan the next one. Don't pause in between.", systemImage: "2.circle.fill")
                Label("Tap \"Finish\" after the last room. The rooms become rooms of \(placeName.isEmpty ? "this place" : placeName), with their furniture as storage spots.", systemImage: "3.circle.fill")
                if place == nil {
                    TextField("Name of the place (Home, Office…)", text: $placeName).textFieldStyle(.roundedBorder)
                }
                Button {
                    scan.begin()
                } label: {
                    Label("Start scanning", systemImage: "viewfinder").frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!HouseScanModel.isSupported)
                if !HouseScanModel.isSupported {
                    Text("This needs an iPhone with LiDAR (Pro models from the 12 Pro on).").font(.footnote).foregroundStyle(.red)
                }
            }
            .card()

        case .scanning:
            HStack {
                if !scan.rooms.isEmpty {
                    Button("Finish") { Task { await finish() } }.buttonStyle(.bordered).tint(.white)
                }
                Spacer()
                Button {
                    scan.finishRoom()
                } label: {
                    Label("Done with this room", systemImage: "checkmark.circle.fill").font(.headline)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)

        case .processing:
            Label("Putting this room together…", systemImage: "cube.transparent")
                .font(.headline).padding().background(.ultraThinMaterial, in: Capsule())

        case .naming where rescan != nil:
            VStack(alignment: .leading, spacing: 10) {
                Text("Use this scan for \(rescan?.name ?? "the room")?").font(.display(.title3))
                HStack {
                    Button("Scan again", role: .destructive) { scan.discardRoom() }
                    Spacer()
                    Button("Use this scan") {
                        scan.keepRoom(named: rescan?.name ?? "Room")
                        Task { await finish() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .card()

        case .naming:
            VStack(alignment: .leading, spacing: 10) {
                Text("What's this room called?").font(.display(.title3))
                TextField(scan.suggestedName, text: $roomName).textFieldStyle(.roundedBorder)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(["Bedroom", "Kitchen", "Living room", "Bathroom", "Office", "Kids' room", "Hallway", "Garage"], id: \.self) { n in
                            Button(n) { roomName = n }.buttonStyle(.bordered).font(.footnote)
                        }
                    }
                }
                HStack {
                    Button("Scan again", role: .destructive) { roomName = ""; scan.discardRoom() }
                    Spacer()
                    Button("Name later") {
                        scan.keepRoomUnnamed(number: (place?.rooms.filter(\.needsName).count ?? 0) + scan.rooms.filter(\.needsName).count + 1)
                        roomName = ""
                        scan.startRoom()
                    }
                    .buttonStyle(.bordered)
                    Button("Finish") {
                        scan.keepRoom(named: roomName)
                        roomName = ""
                        Task { await finish() }
                    }
                    .buttonStyle(.bordered)
                    Button("Next room") {
                        scan.keepRoom(named: roomName)
                        roomName = ""
                        scan.startRoom()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .card()
            .onAppear { roomName = scan.suggestedName }

        case .finishing:
            Label("Joining \(scan.rooms.count) rooms into one map of the place…", systemImage: "map")
                .font(.headline).padding().background(.ultraThinMaterial, in: Capsule())

        case let .failed(message):
            VStack(spacing: 10) {
                Text(message).multilineTextAlignment(.center)
                Button("Scan this room again") { scan.discardRoom() }.buttonStyle(.borderedProminent)
            }
            .card()
        }
    }

    private func finish() async {
        let target = place ?? {
            let p = Place(name: placeName.trimmingCharacters(in: .whitespaces).isEmpty ? "Home" : placeName, kind: .home)
            context.insert(p)
            return p
        }()
        let stem = target.uid.uuidString
        let mapFile = await scan.saveWorldMap(fileStem: stem)
        // Rooms already on the shared map go into the new place model too.
        let earlier: [CapturedRoom] = scan.joinedMap && (addToMap || rescan != nil)
            ? target.rooms.filter { $0.fromHouseScan && $0.mapX == nil && $0.uid != rescan?.uid }.compactMap { Organizer.loadCaptured($0.capturedRoomFile) }
            : []
        let file = await scan.finish(fileStem: stem, earlierRooms: earlier)
        let kind = rescan != nil ? "Rescanned room" : (addToMap ? "Added rooms" : "Whole place")
        organizer.applyHouseScan(scan.rooms, geotag: scan.geotag, modelFile: file ?? target.houseScanFile,
                                 worldMapFile: scan.joinedMap ? mapFile : (target.worldMapFile ?? mapFile),
                                 joinedMap: scan.joinedMap, kind: kind, rescan: rescan, to: target, context: context)
        dismiss()
    }
}
