import ARKit
import CoreImage
import SceneKit
import SwiftData
import SwiftUI
import TidyCore

/// Live AR session for one room: snapshots with LiDAR depth, labels pinned to real things, storage spots placed
/// where they really are, and arcs in the room showing where each thing goes. The room's ARKit world map is saved
/// so the labels come back in the same places next time.
@MainActor
final class ARRoomController: NSObject, ObservableObject, ARSessionDelegate {
    let view = ARSCNView(frame: .zero)
    private let content = SCNNode()
    @Published var status = "Move the phone slowly to look around"
    @Published var ready = false
    @Published var waitingForRelocalization = false
    let hasDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    private var lastRender: [String] = []

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    func start(worldMap: ARWorldMap?) {
        view.session.delegate = self
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = true
        if content.parent == nil { view.scene.rootNode.addChildNode(content) }
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.horizontal, .vertical]
        if hasDepth { c.frameSemantics.insert(.sceneDepth) }
        if let worldMap {
            c.initialWorldMap = worldMap
            waitingForRelocalization = true
            status = "Point at the part of the room you scanned before, so your labels come back"
        }
        view.session.run(c, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() { view.session.pause() }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        Task { @MainActor in self.track(state) }
    }

    private func track(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal:
            waitingForRelocalization = false
            ready = true
            status = "Ready. Point at a messy spot and tap the button"
        case .limited(.relocalizing):
            ready = false
            status = "Finding where you are… point at what you scanned before"
        case .limited(.initializing):
            ready = false
            status = "Getting ready… move the phone a little"
        case .limited(.excessiveMotion):
            status = "Slow down a little"
        case .limited(.insufficientFeatures):
            status = "Needs more light or more detail in view"
        case .notAvailable:
            ready = false
            status = "AR isn't available right now"
        default:
            break
        }
    }

    /// The current camera picture, upright, plus its LiDAR depth.
    func snapshot() -> (jpeg: Data, depth: DepthFrame?)? {
        guard let frame = view.session.currentFrame else { return nil }
        let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent), let jpeg = ImageTools.jpeg(UIImage(cgImage: cg)) else { return nil }
        let depth = frame.sceneDepth.flatMap { Self.copyDepth($0, camera: frame.camera) }
        return (jpeg, depth)
    }

    private static func copyDepth(_ d: ARDepthData, camera: ARCamera) -> DepthFrame? {
        let map = d.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var depth = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { depth[y * w + x] = row[x] }
        }
        var confidence: [UInt8]?
        if let cm = d.confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            if let cb = CVPixelBufferGetBaseAddress(cm), CVPixelBufferGetWidth(cm) == w, CVPixelBufferGetHeight(cm) == h {
                let cr = CVPixelBufferGetBytesPerRow(cm)
                var c = [UInt8](repeating: 0, count: w * h)
                for y in 0..<h {
                    let row = cb.advanced(by: y * cr).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w { c[y * w + x] = row[x] }
                }
                confidence = c
            }
            CVPixelBufferUnlockBaseAddress(cm, .readOnly)
        }
        let k = camera.intrinsics
        let sx = Float(w) / Float(camera.imageResolution.width), sy = Float(h) / Float(camera.imageResolution.height)
        return DepthFrame(width: w, height: h, depth: depth, confidence: confidence,
                          fx: k[0][0] * sx, fy: k[1][1] * sy, cx: k[2][0] * sx, cy: k[2][1] * sy,
                          cameraToWorld: camera.transform)
    }

    /// World point where the screen centre (crosshair) meets a real surface.
    func pointAtCrosshair() -> SIMD3<Float>? {
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let q = view.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .any),
              let hit = view.session.raycast(q).first else { return nil }
        let t = hit.worldTransform.columns.3
        return SIMD3(t.x, t.y, t.z)
    }

    func saveWorldMap(to url: URL) async -> Bool {
        let map: ARWorldMap? = await withCheckedContinuation { cont in
            view.session.getCurrentWorldMap { map, _ in cont.resume(returning: map) }
        }
        guard let map, let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func loadWorldMap(_ url: URL) -> ARWorldMap? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    /// Redraws labels, spots and arcs (only when something changed).
    func render(room: Room, selected: UUID?, showRoutes: Bool) {
        let key = room.items.map { "\($0.uid)\($0.isSorted)\($0.arX ?? 0)\($0.suggestedZoneID?.uuidString ?? "")\($0.sizeText ?? "")" }
            + room.zones.map { "\($0.uid)\($0.arX ?? 0)\($0.name)" } + ["\(selected?.uuidString ?? "")\(showRoutes)"]
        guard key != lastRender else { return }
        lastRender = key
        content.childNodes.forEach { $0.removeFromParentNode() }
        let teal = Palette.tealUI
        var zonePos: [UUID: SIMD3<Float>] = [:]
        for z in room.zones {
            guard let p = z.arPosition else { continue }
            zonePos[z.uid] = p
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.12, pipeRadius: 0.012))
            ring.geometry?.firstMaterial?.diffuse.contents = teal
            ring.simdPosition = p
            content.addChildNode(ring)
            content.addChildNode(SceneShapes.label("▣ " + z.name, at: SCNVector3(p.x, p.y + 0.12, p.z), color: teal, scale: 0.006))
        }
        for it in room.items {
            guard let p = it.arPosition else { continue }
            let isSelected = it.uid == selected
            let color: UIColor = it.isSorted ? .systemGreen : (it.outOfPlace ? .systemOrange : teal)
            let dot = SCNNode(geometry: SCNSphere(radius: isSelected ? 0.035 : 0.022))
            dot.geometry?.firstMaterial?.diffuse.contents = color
            dot.geometry?.firstMaterial?.emission.contents = color.withAlphaComponent(0.4)
            dot.simdPosition = p
            dot.name = "item:\(it.uid.uuidString)"
            content.addChildNode(dot)
            var text = it.name
            if let s = it.sizeText { text += " · " + s }
            if !it.isSorted, let z = room.zone(it.suggestedZoneID) { text += " → " + z.name }
            let label = SceneShapes.label(text, at: SCNVector3(p.x, p.y + 0.06, p.z), color: isSelected ? .white : .label,
                                          scale: isSelected ? 0.007 : 0.005)
            label.name = "item:\(it.uid.uuidString)"
            content.addChildNode(label)
            if showRoutes, !it.isSorted, let id = it.suggestedZoneID, let target = zonePos[id], selected == nil || isSelected {
                content.addChildNode(SceneShapes.arc(from: p, to: target, color: teal.withAlphaComponent(isSelected ? 1 : 0.7),
                                                     lift: 0.35, radius: 0.006))
            }
        }
    }

    func itemID(at point: CGPoint) -> UUID? {
        for hit in view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]) {
            var node: SCNNode? = hit.node
            while let n = node {
                if let name = n.name, name.hasPrefix("item:"), let id = UUID(uuidString: String(name.dropFirst(5))) { return id }
                node = n.parent
            }
        }
        return nil
    }
}

struct ARViewContainer: UIViewRepresentable {
    let controller: ARRoomController
    var onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> ARSCNView {
        controller.view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return controller.view
    }

    func updateUIView(_ view: ARSCNView, context: Context) { context.coordinator.onTap = onTap }

    final class Coordinator: NSObject {
        var onTap: (CGPoint) -> Void
        init(onTap: @escaping (CGPoint) -> Void) { self.onTap = onTap }
        @objc func tap(_ g: UITapGestureRecognizer) { onTap(g.location(in: g.view)) }
    }
}

struct ARRoomScreen: View {
    @Bindable var room: Room
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var organizer: Organizer
    @StateObject private var ar = ARRoomController()
    @State private var selected: UUID?
    @State private var showRoutes = true
    @State private var lightOn = false
    @State private var message: String?
    @State private var placedSomething = false

    var body: some View {
        ZStack {
            ARViewContainer(controller: ar) { p in selected = ar.itemID(at: p) }
                .ignoresSafeArea()
            Image(systemName: "plus").font(.title2.weight(.light)).foregroundStyle(.white).shadow(radius: 2)
                .allowsHitTesting(false)

            VStack(spacing: 10) {
                HStack {
                    Button { close() } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                    Spacer()
                    Text(organizer.progress?.label ?? ar.status)
                        .font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    if CameraAssist.hasLight {
                        Button {
                            lightOn.toggle()
                            CameraAssist.setLight(lightOn)
                        } label: { Image(systemName: lightOn ? "flashlight.on.fill" : "flashlight.off.fill").font(.title2) }
                    }
                }
                .foregroundStyle(.white)
                if !ar.hasDepth {
                    Text("This iPhone has no LiDAR: things are tagged, sizes are Claude's estimates, and labels aren't pinned in AR.")
                        .font(.caption).padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                if ar.waitingForRelocalization {
                    Button("Start a fresh AR map instead") { freshMap() }
                        .font(.footnote.weight(.semibold)).buttonStyle(.bordered).tint(.white)
                }
                Spacer()
                if let id = selected, let item = room.items.first(where: { $0.uid == id }) {
                    selectedCard(item)
                }
                controls
            }
            .padding()
        }
        .onAppear {
            let map = room.worldMapFile.flatMap { ARRoomController.loadWorldMap(Storage.worldMapURL($0)) }
            ar.start(worldMap: map)
            ar.render(room: room, selected: selected, showRoutes: showRoutes)
        }
        .onDisappear { ar.pause(); CameraAssist.setLight(false) }
        .onChange(of: selected) { _, s in ar.render(room: room, selected: s, showRoutes: showRoutes) }
        .onChange(of: showRoutes) { _, v in ar.render(room: room, selected: selected, showRoutes: v) }
        .onChange(of: room.items.count) { _, _ in ar.render(room: room, selected: selected, showRoutes: showRoutes) }
        .alert("AR", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                Task { await tagAndMeasure() }
            } label: {
                HStack {
                    if organizer.progress != nil { ProgressView().tint(.white) } else { Image(systemName: "sparkles.rectangle.stack") }
                    Text(organizer.progress != nil ? "Claude is looking…" : "Tag & measure what I see")
                }
                .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(organizer.progress != nil || ar.waitingForRelocalization || !ar.ready)

            HStack {
                Menu {
                    Section("Put this spot at the crosshair") {
                        ForEach(room.zones.sorted { $0.createdAt < $1.createdAt }) { z in
                            Button(z.name + (z.arPosition != nil ? " (move)" : "")) { place(z) }
                        }
                    }
                    Button("New storage spot here", systemImage: "plus") {
                        let z = Zone(name: "Spot \(room.zones.count + 1)", kind: .shelf)
                        z.room = room
                        context.insert(z)
                        place(z)
                    }
                } label: {
                    Label("Place spot", systemImage: "scope").frame(maxWidth: .infinity)
                }
                .disabled(ar.waitingForRelocalization || !ar.ready)
                Toggle(isOn: $showRoutes) { Label("Routes", systemImage: "arrow.triangle.turn.up.right.diamond") }
                    .toggleStyle(.button)
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func selectedCard(_ item: Item) -> some View {
        HStack(spacing: 12) {
            ItemThumb(file: item.thumbFile, category: item.category, size: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline)
                if let s = item.sizeText { Text(s).font(.caption.monospacedDigit()) }
                Text(item.isSorted ? "Put away" : (room.zone(item.suggestedZoneID).map { "→ \($0.name)" } ?? item.action.label))
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.teal)
            }
            Spacer()
            if !item.isSorted {
                Button {
                    item.putAway()
                    try? context.save()
                    Haptics.success()
                    selected = nil
                    ar.render(room: room, selected: nil, showRoutes: showRoutes)
                    organizer.scheduleDriveSync()
                } label: { Image(systemName: "checkmark.circle.fill").font(.largeTitle) }
                    .foregroundStyle(.green)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func tagAndMeasure() async {
        guard KeyStore.hasKey else { message = ClaudeWire.Failure.noKey.errorDescription; return }
        guard let shot = ar.snapshot() else { message = "The camera isn't ready yet."; return }
        do {
            let plan = try await organizer.scanAR(jpeg: shot.jpeg, depth: shot.depth, into: room, context: context)
            placedSomething = placedSomething || shot.depth != nil
            ar.render(room: room, selected: selected, showRoutes: showRoutes)
            let measured = shot.depth != nil ? " and measured" : ""
            message = plan.insertCount + plan.updateCount == 0 ? "Nothing new spotted here."
                : "Tagged\(measured) \(plan.insertCount + plan.updateCount) thing\(plan.insertCount + plan.updateCount == 1 ? "" : "s")."
            await saveMap()
        } catch {
            message = error.localizedDescription
        }
    }

    private func place(_ zone: Zone) {
        guard let p = ar.pointAtCrosshair() else {
            message = "Point the crosshair at a surface (shelf, floor, wall) and try again."
            return
        }
        zone.arX = Double(p.x)
        zone.arY = Double(p.y)
        zone.arZ = Double(p.z)
        zone.isIdea = false
        try? context.save()
        Haptics.success()
        placedSomething = true
        ar.render(room: room, selected: selected, showRoutes: showRoutes)
        Task { await saveMap() }
    }

    private func saveMap() async {
        let name = room.worldMapFile ?? room.uid.uuidString + ".arworldmap"
        if await ar.saveWorldMap(to: Storage.worldMapURL(name)) {
            room.worldMapFile = name
            try? context.save()
        }
    }

    /// Forget the old AR positions of this room and map it again from here.
    private func freshMap() {
        for it in room.items { it.arX = nil; it.arY = nil; it.arZ = nil }
        for z in room.zones { z.arX = nil; z.arY = nil; z.arZ = nil }
        if let f = room.worldMapFile { try? FileManager.default.removeItem(at: Storage.worldMapURL(f)) }
        room.worldMapFile = nil
        try? context.save()
        ar.start(worldMap: nil)
        ar.render(room: room, selected: nil, showRoutes: showRoutes)
    }

    private func close() {
        Task {
            if placedSomething { await saveMap() }
            organizer.scheduleDriveSync()
            dismiss()
        }
    }
}
