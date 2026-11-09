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
    enum Phase: Equatable { case intro, scanning, processing, naming, finishing, failed(String) }

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
    private let location = LocationService.shared

    init() {
        coordinator.onData = { [weak self] data in
            Task { @MainActor in await self?.build(data) }
        }
    }

    static var isSupported: Bool { RoomCaptureSession.isSupported }

    func begin() {
        location.startTracking()
        startRoom()
    }

    func startRoom() {
        phase = .scanning
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        if geotag == nil {
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

    func discardRoom() {
        pendingRoom = nil
        startRoom()
    }

    /// Merges the rooms into one model of the place. Returns the USDZ file name (in Documents/RoomScans), if any.
    func finish(fileStem: String) async -> String? {
        phase = .finishing
        arSession.pause()
        location.stopTracking()
        guard !rooms.isEmpty else { return nil }
        let name = fileStem + "-place.usdz"
        let url = Storage.roomScanURL(name)
        try? FileManager.default.removeItem(at: url)
        do {
            let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms.map(\.room))
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
        .onAppear { placeName = place?.name ?? "Home" }
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
        let file = await scan.finish(fileStem: target.uid.uuidString)
        organizer.applyHouseScan(scan.rooms, geotag: scan.geotag, modelFile: file, to: target, context: context)
        dismiss()
    }
}
