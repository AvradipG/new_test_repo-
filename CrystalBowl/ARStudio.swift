import SwiftUI
import ARKit
import SceneKit
import ScanMath

/// Several scans standing on the real table at once, each with its sizes, ruler and protractor.
/// 100 % is true size (caliper-corrected when a caliper check exists); any item can be shown bigger or smaller.
@MainActor
final class ARStudio: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let scan: Scan
        let rig: SampleRig
        let selection: SCNNode
        var scale = 1.0
        var angle = 0.0
        var placed = false
    }

    @Published var items: [Item] = []
    @Published var selectedID: String?
    @Published var loading = false
    @Published var status = "Move the phone slowly over the table so it can find the surface."
    @Published var linkScales = true

    let root = SCNNode()
    weak var view: ARSCNView?

    var selectedIndex: Int? { items.firstIndex { $0.id == selectedID } }
    var hasUnplaced: Bool { items.contains { !$0.placed } }

    func load(_ scans: [Scan]) async {
        loading = true
        defer { loading = false }
        for scan in scans where !items.contains(where: { $0.id == scan.id }) && scan.hasModel {
            guard let loaded = await SampleRig.load(scan) else { continue }
            let rig = SampleRig(scene: loaded.0, data: loaded.1, name: scan.name)
            let ring = SampleRig.ring(center: SIMD3(0, Float(loaded.1.extent * 0.003), 0), axis: SIMD3(0, 1, 0),
                                      radius: rig.footprintRadius * 1.06, pipe: Float(loaded.1.extent * 0.006),
                                      color: UIColor(red: 0.3, green: 1, blue: 0.5, alpha: 1))
            ring.isHidden = true
            rig.stage.addChildNode(ring)
            let name = SampleRig.label(scan.name, color: .white, height: Float(loaded.1.extent * 0.09))
            name.simdPosition = SIMD3(0, Float(loaded.1.height + loaded.1.extent * 0.3), 0)
            rig.stage.addChildNode(name)
            rig.stage.isHidden = true
            root.addChildNode(rig.stage)
            items.append(Item(id: scan.id, scan: scan, rig: rig, selection: ring))
            apply(items.count - 1)
        }
        if selectedID == nil { selectedID = items.first?.id }
        status = hasUnplaced ? "Tap the table where the samples should stand." : status
        refreshSelection()
    }

    func remove(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].rig.stage.removeFromParentNode()
        items.remove(at: i)
        if selectedID == id { selectedID = items.first?.id }
        refreshSelection()
    }

    /// Puts every sample not yet on the table side by side, centred on `point`, in a row across the view.
    func placeUnplaced(at point: SIMD3<Float>, right: SIMD3<Float>) {
        let todo = items.indices.filter { !items[$0].placed }
        let widths = todo.map { width(of: items[$0]) }
        let gap: Float = 0.03
        var x = -(widths.reduce(0, +) + gap * Float(max(0, todo.count - 1))) / 2
        for (k, i) in todo.enumerated() {
            x += widths[k] / 2
            items[i].rig.stage.simdPosition = point + right * x
            items[i].rig.stage.isHidden = false
            items[i].placed = true
            x += widths[k] / 2 + gap
        }
        status = "Drag to move · pinch to resize · twist to turn. Tap a sample to select it."
    }

    func move(_ i: Int, to point: SIMD3<Float>) {
        items[i].rig.stage.simdPosition = point
    }

    func resetPlacement() {
        for i in items.indices {
            items[i].placed = false
            items[i].rig.stage.isHidden = true
        }
        status = "Tap the table where the samples should stand."
    }

    func setScale(_ s: Double, for i: Int) {
        let v = min(10, max(0.05, s))
        if linkScales {
            for j in items.indices { items[j].scale = v; apply(j) }
        } else {
            items[i].scale = v
            apply(i)
        }
    }

    func setAngle(_ a: Double, for i: Int) {
        items[i].angle = Rotation.normalized(a)
        apply(i)
    }

    func showOverlays(dimensions: Bool, ruler: Bool, protractor: Bool) {
        for item in items { item.rig.show(dimensions: dimensions, ruler: ruler, protractor: protractor) }
    }

    func apply(_ i: Int) {
        let it = items[i]
        it.rig.stage.simdScale = SIMD3(repeating: Float(it.scale * it.rig.data.scaleFactor))
        it.rig.angle = it.angle
    }

    func refreshSelection() {
        for it in items { it.selection.isHidden = it.id != selectedID }
    }

    func itemIndex(containing node: SCNNode) -> Int? {
        var n: SCNNode? = node
        while let cur = n {
            if let i = items.firstIndex(where: { $0.rig.stage === cur }) { return i }
            n = cur.parent
        }
        return nil
    }

    private func width(of item: Item) -> Float {
        item.rig.footprintRadius * 2 * Float(item.scale * item.rig.data.scaleFactor)
    }
}

struct ARStudioView: UIViewRepresentable {
    let studio: ARStudio

    func makeCoordinator() -> Coordinator { Coordinator(studio: studio) }

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.scene = SCNScene()
        v.automaticallyUpdatesLighting = true
        v.autoenablesDefaultLighting = true
        v.scene.rootNode.addChildNode(studio.root)
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal]
        cfg.environmentTexturing = .automatic
        v.session.run(cfg)

        let coach = ARCoachingOverlayView()
        coach.session = v.session
        coach.goal = .horizontalPlane
        coach.activatesAutomatically = true
        coach.frame = v.bounds
        coach.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.addSubview(coach)

        let c = context.coordinator
        c.view = v
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let twist = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.twist(_:)))
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        for g in [tap, pinch, twist, pan] as [UIGestureRecognizer] {
            g.delegate = c
            v.addGestureRecognizer(g)
        }
        studio.view = v
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let studio: ARStudio
        weak var view: ARSCNView?
        private var pinchStart = 1.0

        init(studio: ARStudio) { self.studio = studio }

        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        private func tableHit(_ p: CGPoint) -> SIMD3<Float>? {
            guard let v = view, let q = v.raycastQuery(from: p, allowing: .estimatedPlane, alignment: .horizontal),
                  let r = v.session.raycast(q).first else { return nil }
            let t = r.worldTransform.columns.3
            return SIMD3(t.x, t.y, t.z)
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            let p = g.location(in: v)
            if let hit = v.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]).first,
               let i = studio.itemIndex(containing: hit.node) {
                studio.selectedID = studio.items[i].id
                studio.refreshSelection()
                return
            }
            guard let point = tableHit(p) else {
                studio.status = "No table found there yet: move the phone slowly over it, then tap again."
                return
            }
            if studio.hasUnplaced {
                var right = SIMD3<Float>(1, 0, 0)
                if let cam = v.session.currentFrame?.camera.transform {
                    let r = SIMD3(cam.columns.0.x, 0, cam.columns.0.z)
                    if simd_length(r) > 0.01 { right = simd_normalize(r) }
                }
                studio.placeUnplaced(at: point, right: right)
            } else if let i = studio.selectedIndex {
                studio.move(i, to: point)
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let i = studio.selectedIndex else { return }
            if g.state == .began { pinchStart = studio.items[i].scale }
            if g.state == .changed { studio.setScale(pinchStart * Double(g.scale), for: i) }
        }

        @objc func twist(_ g: UIRotationGestureRecognizer) {
            guard let i = studio.selectedIndex, g.state == .changed else { return }
            // A clockwise twist on screen turns the sample clockwise seen from above (negative angle).
            studio.setAngle(studio.items[i].angle - Double(g.rotation) * 180 / .pi, for: i)
            g.rotation = 0
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let v = view, let i = studio.selectedIndex, studio.items[i].placed,
                  g.state == .changed, let point = tableHit(g.location(in: v)) else { return }
            studio.move(i, to: point)
        }
    }
}

/// The AR screen: camera view with the samples, and controls for the selected one.
struct ARStudioScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var model: AppModel
    let scans: [Scan]
    @StateObject private var studio = ARStudio()
    @AppStorage("overlay.dimensions") private var showDims = true
    @AppStorage("overlay.ruler") private var showRuler = true
    @AppStorage("overlay.protractor") private var showDial = true
    @State private var panelOpen = true
    @State private var adding = false

    var body: some View {
        ZStack {
            ARStudioView(studio: studio).ignoresSafeArea()
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                    Spacer()
                    Text(studio.loading ? "Loading models…" : studio.status)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    Spacer()
                    Menu {
                        Button { adding = true } label: { Label("Add scans", systemImage: "plus") }
                        Button { studio.resetPlacement() } label: { Label("Place again", systemImage: "arrow.counterclockwise") }
                        Toggle("Same size for all", isOn: $studio.linkScales)
                    } label: {
                        Image(systemName: "ellipsis.circle.fill").font(.title2)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(studio.items) { it in
                            Button {
                                studio.selectedID = it.id
                                studio.refreshSelection()
                            } label: {
                                Text(it.scan.name).lineLimit(1).font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(it.id == studio.selectedID ? .green : .gray)
                        }
                    }
                }
                Spacer()
                if let i = studio.selectedIndex {
                    controls(i)
                }
            }
            .padding()
        }
        .task {
            await studio.load(scans)
            studio.showOverlays(dimensions: showDims, ruler: showRuler, protractor: showDial)
        }
        .onChange(of: showDims) { _, _ in applyToggles() }
        .onChange(of: showRuler) { _, _ in applyToggles() }
        .onChange(of: showDial) { _, _ in applyToggles() }
        .sheet(isPresented: $adding) {
            ScanPicker(selected: Set(studio.items.map(\.id))) { picked in
                Task {
                    await studio.load(model.scans.filter { picked.contains($0.id) })
                    applyToggles()
                }
            }
        }
    }

    private func applyToggles() { studio.showOverlays(dimensions: showDims, ruler: showRuler, protractor: showDial) }

    @ViewBuilder private func controls(_ i: Int) -> some View {
        let it = studio.items[i]
        VStack(spacing: 8) {
            HStack {
                Text(it.scan.name).font(.headline).lineLimit(1)
                Spacer()
                Button { withAnimation { panelOpen.toggle() } } label: {
                    Image(systemName: panelOpen ? "chevron.down.circle.fill" : "chevron.up.circle.fill").font(.title3)
                }
            }
            HStack {
                Text(String(format: "%.0f%%", it.scale * 100)).font(.title3.monospacedDigit().bold()).frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { log10(studio.items[i].scale) },
                                      set: { studio.setScale(pow(10, $0), for: i) }), in: -1...log10(5))
                Button("100%") { studio.setScale(1, for: i) }.buttonStyle(.bordered).controlSize(.small)
            }
            Text(it.scale == 1 ? "Real size" : String(format: "Shown at %.0f%% of real size; the sizes and ruler still read true millimetres", it.scale * 100))
                .font(.caption2).foregroundStyle(.secondary)
            if panelOpen {
                OverlayToggles(dimensions: $showDims, ruler: $showRuler, protractor: $showDial)
                HStack(spacing: 12) {
                    ProtractorDial(angle: Binding(get: { studio.items[i].angle }, set: { studio.setAngle($0, for: i) }))
                        .frame(width: 120, height: 120)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(it.rig.data.summary.prefix(3), id: \.self) { Text($0).font(.caption2) }
                    }
                }
                AngleControls(angle: Binding(get: { studio.items[i].angle }, set: { studio.setAngle($0, for: i) }))
                Button(role: .destructive) { studio.remove(it.id) } label: { Label("Remove from view", systemImage: "trash") }
                    .font(.caption)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Multi-select list of finished scans.
struct ScanPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var selected: Set<String>
    let done: (Set<String>) -> Void

    var body: some View {
        NavigationStack {
            List(model.scans.filter(\.hasModel)) { scan in
                Button {
                    if selected.contains(scan.id) { selected.remove(scan.id) } else { selected.insert(scan.id) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(scan.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(scan.id) ? Color.green : Color.secondary)
                        VStack(alignment: .leading) {
                            Text(scan.name)
                            Text(scan.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Choose scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { done(selected); dismiss() } }
            }
        }
    }
}

/// The AR tab: pick scans and stand them on the table together.
struct ARStudioHome: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("AR view", systemImage: "arkit").font(.title2.bold())
                        Text("Stand one or more scanned samples on the real table, side by side, at real size or bigger or smaller. Sizes, a ruler and a 360° protractor are drawn on each; turn a sample with two fingers or with the dial.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    let finished = model.scans.filter(\.hasModel)
                    if finished.isEmpty {
                        Text("No finished scans yet. Scan a sample in the Scan tab first.").foregroundStyle(.secondary)
                    }
                    ForEach(finished) { scan in
                        Button {
                            if model.arSelection.contains(scan.id) { model.arSelection.remove(scan.id) } else { model.arSelection.insert(scan.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: model.arSelection.contains(scan.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(model.arSelection.contains(scan.id) ? Color.green : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scan.name).font(.body.weight(.medium))
                                    Text(model.dimensionsText(scan)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Choose samples")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { open = true } label: {
                    Label(model.arSelection.isEmpty ? "Choose samples above" : "View \(model.arSelection.count) in AR",
                          systemImage: "arkit")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.arSelection.isEmpty)
                .padding()
                .background(.bar)
            }
            .navigationTitle("AR view")
            .fullScreenCover(isPresented: $open) {
                ARStudioScreen(scans: model.scans.filter { model.arSelection.contains($0.id) })
            }
        }
    }
}
