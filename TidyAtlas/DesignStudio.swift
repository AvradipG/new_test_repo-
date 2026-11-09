import QuickLook
import SwiftData
import SwiftUI
import TidyCore

/// Plan, decorate and rearrange a room: every scanned piece of furniture is separate and can be dragged, turned and
/// resized; furniture and wall decor come from a catalog; the AI designer (Claude or ChatGPT) proposes layouts and
/// themes, ranks designs, and Feng Shui / Vastu / walkway overlays show how the space flows.
struct DesignStudioView: View {
    @Bindable var room: Room
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var organizer: Organizer

    enum Mode: String, CaseIterable { case plan = "Plan", threeD = "3D", picture = "Picture" }
    enum Overlay: String, CaseIterable { case none = "None", walkways = "Walkways", vastu = "Vastu", fengShui = "Feng Shui" }

    @State private var designID: UUID?
    @State private var pieces: [DesignPiece] = []
    @State private var selected: UUID?
    @State private var mode = Mode.plan
    @State private var overlay = Overlay.walkways
    @State private var showCatalog = false
    @State private var showChat = false
    @State private var quickLook: URL?
    @State private var message: String?
    @State private var rendering = false
    @State private var renameText = ""
    @State private var renaming: DesignVariant?

    private var design: DesignVariant? { room.designs.first { $0.uid == designID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                designChips
                if let d = design, !d.isCurrent, !d.rationale.isEmpty { rationaleCard(d) }
                Picker("Mode", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                switch mode {
                case .plan: planMode
                case .threeD: threeDMode
                case .picture: pictureMode
                }
            }
            .padding()
        }
        .background(Palette.paper)
        .navigationTitle("Design \(room.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showChat = true } label: { Label("Designer", systemImage: "bubble.left.and.text.bubble.right.fill") }
            }
        }
        .sheet(isPresented: $showCatalog) { CatalogSheet { add($0) } }
        .sheet(isPresented: $showChat) {
            DesignChatView(room: room, base: design) { id in
                designID = id
                load()
                showChat = false
            }
        }
        .quickLookPreview($quickLook)
        .onAppear {
            let current = room.currentDesign(context: context)
            try? context.save()
            if designID == nil { designID = current.uid }
            load()
        }
        .onChange(of: designID) { _, _ in load() }
        .alert("Design", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
        .alert("Rename design", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { renaming?.name = renameText; try? context.save() }
        }
    }

    // MARK: Designs

    private var designChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(room.sortedDesigns) { d in
                    Button { designID = d.uid } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(.footnote.weight(.bold))
                            Text(d.isCurrent ? "the real room" : (d.scoreOverall.map { String(format: "score %.1f", $0) } ?? d.style))
                                .font(.caption2)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(d.uid == designID ? Palette.teal : Palette.card, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(d.uid == designID ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { renameText = d.name; renaming = d }
                        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(d) }
                        if !d.isCurrent {
                            Button("I've arranged the room like this", systemImage: "checkmark.seal") { makeReal(d) }
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(d) }
                        }
                    }
                }
                Button { newDesign() } label: {
                    Label("New idea", systemImage: "plus").font(.footnote.weight(.bold))
                        .padding(.horizontal, 12).padding(.vertical, 14)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func rationaleCard(_ d: DesignVariant) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(d.style.isEmpty ? d.name : "\(d.name) · \(d.style)").font(.display(.headline))
            Text(d.rationale).font(.callout)
            if let f = d.scoreFlow, let c = d.scoreCalm, let o = d.scoreOverall {
                Text(String(format: "Flow %.0f · Calm %.0f · Overall %.1f / 10", f, c, o)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(d.tips, id: \.self) { Text("• " + $0).font(.caption) }
        }
        .card(Palette.tint)
    }

    // MARK: Plan

    private var planMode: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Overlay", selection: $overlay) { ForEach(Overlay.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            if (overlay == .vastu) && room.bearing == nil { northPicker }
            if overlay == .fengShui {
                Picker("Entrance", selection: Binding(get: { room.entrance }, set: { room.entrance = $0; try? context.save() })) {
                    Text("Door at bottom").tag(SpaceWisdom.Entrance.near)
                    Text("Top").tag(SpaceWisdom.Entrance.far)
                    Text("Left").tag(SpaceWisdom.Entrance.left)
                    Text("Right").tag(SpaceWisdom.Entrance.right)
                }
                .pickerStyle(.segmented)
            }
            PlanEditor(room: room, pieces: $pieces, selected: $selected, overlay: overlay) { commit() }
                .frame(height: 430)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            statusLine
            if let id = selected, let i = pieces.firstIndex(where: { $0.id == id }) {
                PieceInspector(piece: $pieces[i], roomWidth: room.widthM, roomDepth: room.depthM, bearing: room.bearing,
                               onCommit: commit, onDelete: { pieces.remove(at: i); selected = nil; commit() },
                               onDuplicate: {
                                   var copy = pieces[i]
                                   copy.id = UUID()
                                   copy.x += 0.3
                                   copy.z += 0.3
                                   copy.source = "added"
                                   copy.zoneID = nil
                                   pieces.append(DesignGeometry.clamp(copy, width: room.widthM, depth: room.depthM))
                                   selected = copy.id
                                   commit()
                               })
            }
            HStack {
                Button { showCatalog = true } label: { Label("Add furniture or decor", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderedProminent)
                Button { showChat = true } label: { Label("Ask the designer", systemImage: "sparkles") }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            Text("Drag any piece to move it, tap it to turn, resize or delete. Each scanned piece of furniture is separate.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var statusLine: some View {
        let clashes = DesignGeometry.clashes(pieces).count
        let tight = DesignGeometry.tightGaps(pieces).count
        let open = DesignGeometry.openFloor(pieces, width: room.widthM, depth: room.depthM)
        return HStack(spacing: 12) {
            Label("\(Int(open * 100))% open floor", systemImage: "square.dashed")
            if clashes > 0 { Label("\(clashes) overlapping", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            if tight > 0 { Label("\(tight) tight walkway\(tight == 1 ? "" : "s")", systemImage: "figure.walk").foregroundStyle(.orange) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var northPicker: some View {
        HStack {
            Text("The top wall faces").font(.footnote)
            Picker("North", selection: Binding(get: { room.northBearingOverride ?? -1 },
                                               set: { room.northBearingOverride = $0 < 0 ? nil : $0; try? context.save() })) {
                Text("not set").tag(-1.0)
                ForEach(Array(stride(from: 0.0, to: 360.0, by: 45.0)), id: \.self) { Text(GeoMath.compassName($0)).tag($0) }
            }
        }
    }

    // MARK: 3D and picture

    private var threeDMode: some View {
        VStack(alignment: .leading, spacing: 12) {
            Design3DView(room: room, pieces: pieces)
                .frame(height: 430)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            Button {
                if let url = Design3D.exportUSDZ(room: room, pieces: pieces, name: design?.name ?? "design") { quickLook = url }
                else { message = "Couldn't make the AR model." }
            } label: { Label("See it in AR", systemImage: "arkit").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("Drag to turn, pinch to zoom. In AR, place the design on your floor and walk round it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var pictureMode: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let f = design?.renderFile, let img = UIImage(contentsOfFile: Storage.designURL(f).path) {
                Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 18))
                ShareLink(item: Image(uiImage: img), preview: SharePreview(design?.name ?? "Design", image: Image(uiImage: img))) {
                    Label("Share picture", systemImage: "square.and.arrow.up")
                }
            } else {
                Text("A realistic picture of your room with this design, made by ChatGPT from your latest photo of the room.")
                    .foregroundStyle(.secondary).padding(.vertical)
            }
            Button {
                Task { await render() }
            } label: {
                HStack {
                    if rendering { ProgressView() } else { Image(systemName: "photo.badge.magic") }
                    Text(rendering ? "Painting your room (about a minute)…" : (design?.renderFile == nil ? "Show me how it will look" : "Paint it again"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(rendering)
            if !KeyStore.hasKey(.chatgpt) {
                Text("Pictures need a ChatGPT key (Settings). Claude can't make images.").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func render() async {
        guard let d = design else { return }
        guard let capture = room.captures.filter({ $0.status == .analyzed }).max(by: { $0.createdAt < $1.createdAt }),
              let photo = try? Data(contentsOf: Storage.captureURL(capture.file)) else {
            message = "Take a photo of the room first (Scan this space), so the picture shows your real room."
            return
        }
        rendering = true
        defer { rendering = false }
        do {
            let png = try await AIService.visualize(photo: photo, prompt: Design3D.picturePrompt(room: room, design: d, pieces: pieces))
            let name = d.uid.uuidString + ".png"
            try png.write(to: Storage.designURL(name), options: .atomic)
            d.renderFile = name
            try? context.save()
            organizer.scheduleDriveSync()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Editing

    private func load() { pieces = design?.pieces ?? [] }

    private func commit() {
        guard let d = design else { return }
        d.pieces = pieces
        try? context.save()
        organizer.scheduleDriveSync()
    }

    private func add(_ item: CatalogItem) {
        var p = DesignPiece(kind: item.kind, name: item.name, x: 0, z: 0, y: item.onWall ? FurnitureCatalog.wallHeight(item.kind) : 0,
                            width: item.width, depth: item.depth, height: item.height, onWall: item.onWall)
        if item.onWall { p.z = -room.depthM / 2 }
        p = DesignGeometry.clamp(p, width: room.widthM, depth: room.depthM)
        pieces.append(p)
        selected = p.id
        if design?.isCurrent == true && message == nil {
            message = "Added to \"As it is\". Tip: try new furniture in a new idea (the + chip) so the real room stays as it is."
        }
        commit()
    }

    private func newDesign() {
        let d = DesignVariant(name: "Idea \(room.designs.count)")
        d.pieces = pieces.isEmpty ? room.scannedPieces() : pieces
        d.room = room
        context.insert(d)
        try? context.save()
        designID = d.uid
    }

    private func duplicate(_ d: DesignVariant) {
        let c = DesignVariant(name: d.name + " copy")
        c.pieces = d.pieces
        c.style = d.style
        c.room = room
        context.insert(c)
        try? context.save()
        designID = c.uid
    }

    private func delete(_ d: DesignVariant) {
        if let f = d.renderFile { try? FileManager.default.removeItem(at: Storage.designURL(f)) }
        if designID == d.uid { designID = room.designs.first(where: \.isCurrent)?.uid }
        context.delete(d)
        try? context.save()
    }

    /// The owner rearranged the room like this design: it becomes "As it is" and the storage spots move with it.
    private func makeReal(_ d: DesignVariant) {
        for p in d.pieces {
            guard let zid = p.zoneID, let z = room.zones.first(where: { $0.uid == zid }) else { continue }
            z.posX = Clamp.unit(p.x / room.widthM + 0.5)
            z.posZ = Clamp.unit(p.z / room.depthM + 0.5)
            z.yaw = -p.rotationDeg * .pi / 180
        }
        for old in room.designs where old.isCurrent {
            old.isCurrent = false
            old.name = "Before (\(Date().formatted(date: .abbreviated, time: .omitted)))"
        }
        d.isCurrent = true
        try? context.save()
        designID = d.uid
        message = "Done. Storage spots moved with the furniture, so the map and plans follow your new layout."
        organizer.scheduleDriveSync()
    }
}

// MARK: - Plan editor

struct PlanEditor: View {
    let room: Room
    @Binding var pieces: [DesignPiece]
    @Binding var selected: UUID?
    var overlay: DesignStudioView.Overlay
    var onCommit: () -> Void
    @State private var dragStart: [UUID: (Double, Double)] = [:]

    var body: some View {
        GeometryReader { geo in
            let W = room.widthM, D = room.depthM
            let scale = min((geo.size.width - 40) / W, (geo.size.height - 40) / D)
            let origin = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let toScreen = { (x: Double, z: Double) -> CGPoint in CGPoint(x: origin.x + x * scale, y: origin.y + z * scale) }
            let clashes = DesignGeometry.clashes(pieces)
            ZStack {
                // Floor
                Rectangle().fill(Color(red: 0.93, green: 0.90, blue: 0.84).opacity(0.7))
                    .frame(width: W * scale, height: D * scale)
                    .position(origin)
                overlayView(W: W, D: D, scale: scale, origin: origin)
                // Walls, doors, windows
                Path { p in
                    if let walls = room.layout?.walls, !walls.isEmpty {
                        for w in walls { let c = w.corners; p.move(to: toScreen(c[0].0, c[0].1)); p.addLine(to: toScreen(c[1].0, c[1].1)) }
                    } else {
                        p.addRect(CGRect(x: origin.x - W * scale / 2, y: origin.y - D * scale / 2, width: W * scale, height: D * scale))
                    }
                }
                .stroke(Color.primary, lineWidth: 4)
                ForEach(Array((room.layout?.openings ?? []).enumerated()), id: \.offset) { _, o in
                    let c = o.corners
                    Path { p in p.move(to: toScreen(c[0].0, c[0].1)); p.addLine(to: toScreen(c[1].0, c[1].1)) }
                        .stroke(o.label == "window" ? Color.cyan : Color.orange, lineWidth: 7)
                }
                if overlay == .walkways {
                    ForEach(Array(DesignGeometry.tightGaps(pieces).enumerated()), id: \.offset) { _, pair in
                        if let a = pieces.first(where: { $0.id == pair.0 }), let b = pieces.first(where: { $0.id == pair.1 }) {
                            Path { p in p.move(to: toScreen(a.x, a.z)); p.addLine(to: toScreen(b.x, b.z)) }
                                .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        }
                    }
                }
                // Pieces: rugs first, wall pieces last.
                ForEach(pieces.sorted { order($0) < order($1) }) { p in
                    pieceView(p, scale: scale, clash: clashes.contains(p.id))
                        .position(toScreen(p.x, p.z))
                        .gesture(drag(p, scale: scale))
                        .onTapGesture { selected = selected == p.id ? nil : p.id }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selected = nil }
        }
    }

    private func order(_ p: DesignPiece) -> Int { p.kind.hasPrefix("rug") ? 0 : (p.onWall ? 2 : 1) }

    private func drag(_ p: DesignPiece, scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                guard let i = pieces.firstIndex(where: { $0.id == p.id }) else { return }
                if FurnitureCatalog.isFixed(p.kind) { return }
                let start = dragStart[p.id] ?? (pieces[i].x, pieces[i].z)
                dragStart[p.id] = start
                selected = p.id
                pieces[i].x = start.0 + g.translation.width / scale
                pieces[i].z = start.1 + g.translation.height / scale
                if pieces[i].onWall { pieces[i] = DesignGeometry.snapToWall(pieces[i], width: room.widthM, depth: room.depthM) }
            }
            .onEnded { _ in
                dragStart[p.id] = nil
                if let i = pieces.firstIndex(where: { $0.id == p.id }) {
                    pieces[i] = DesignGeometry.clamp(pieces[i], width: room.widthM, depth: room.depthM)
                }
                Haptics.tap()
                onCommit()
            }
    }

    private func pieceView(_ p: DesignPiece, scale: Double, clash: Bool) -> some View {
        let isSel = p.id == selected
        let fill: Color = p.kind.hasPrefix("rug") ? Color.brown.opacity(0.18)
            : p.onWall ? Color.purple.opacity(0.55)
            : p.source == "ai" ? Palette.teal.opacity(0.45) : Color.gray.opacity(0.45)
        let symbol = FurnitureCatalog.item(p.kind)?.symbol ?? (FurnitureCatalog.isFixed(p.kind) ? "lock.fill" : "cube")
        return ZStack {
            RoundedRectangle(cornerRadius: p.kind == "table_round" ? max(p.width, p.depth) * scale / 2 : 4)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(clash ? Color.red : (isSel ? Palette.teal : Color.primary.opacity(0.5)),
                                                                        lineWidth: isSel || clash ? 3 : 1))
                .frame(width: max(p.width * scale, 10), height: max(p.depth * scale, p.onWall ? 6 : 10))
                .rotationEffect(.degrees(p.rotationDeg))
            if p.width * scale > 34 || isSel {
                VStack(spacing: 0) {
                    Image(systemName: symbol).font(.caption2)
                    Text(p.name).font(.system(size: 9, weight: .semibold)).lineLimit(1).fixedSize()
                }
                .padding(2)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                .offset(y: p.onWall ? (p.rotationDeg == 0 ? 14 : -14) : 0)
            }
        }
    }

    @ViewBuilder private func overlayView(W: Double, D: Double, scale: Double, origin: CGPoint) -> some View {
        switch overlay {
        case .vastu:
            if let b = room.bearing {
                ForEach(Array(["N", "NE", "E", "SE", "S", "SW", "W", "NW"].enumerated()), id: \.offset) { n, dir in
                    // Screen angle of compass direction `dir` (clockwise from the top wall).
                    let a = (Double(n) * 45 - b) * .pi / 180
                    let r = min(W, D) * scale * 0.42
                    VStack(spacing: 0) {
                        Text(dir).font(.caption.weight(.heavy)).foregroundStyle(dir == "N" ? .red : .indigo)
                        Text(vastuShort(dir)).font(.system(size: 8)).foregroundStyle(.indigo).multilineTextAlignment(.center)
                    }
                    .frame(width: 70)
                    .position(x: origin.x + sin(a) * r, y: origin.y - cos(a) * r)
                }
                Text("Brahmasthan\nkeep open").font(.system(size: 9, weight: .semibold)).foregroundStyle(.indigo)
                    .multilineTextAlignment(.center).position(origin)
            }
        case .fengShui:
            ForEach(0..<9, id: \.self) { k in
                let col = Double(k % 3), row = Double(k / 3)
                let x = (col - 1) * W / 3, z = (row - 1) * D / 3
                Rectangle().strokeBorder(Color.red.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: W * scale / 3, height: D * scale / 3)
                    .position(x: origin.x + x * scale, y: origin.y + z * scale)
                Text(SpaceWisdom.bagua(x: x, z: z, width: W, depth: D, entrance: room.entrance))
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.red.opacity(0.7))
                    .frame(width: W * scale / 3 - 6)
                    .multilineTextAlignment(.center)
                    .position(x: origin.x + x * scale, y: origin.y + z * scale - D * scale / 9 + 10)
            }
        default:
            EmptyView()
        }
    }

    private func vastuShort(_ d: String) -> String {
        switch d {
        case "N": return "wealth, open"
        case "NE": return "clear, light"
        case "E": return "health, light"
        case "SE": return "fire, kitchen"
        case "S": return "heavy, rest"
        case "SW": return "master bed"
        case "W": return "study, dining"
        default: return "guests, flow"
        }
    }
}

struct PieceInspector: View {
    @Binding var piece: DesignPiece
    let roomWidth: Double
    let roomDepth: Double
    let bearing: Double?
    var onCommit: () -> Void
    var onDelete: () -> Void
    var onDuplicate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: FurnitureCatalog.item(piece.kind)?.symbol ?? "cube")
                TextField("Name", text: $piece.name, onCommit: onCommit).font(.headline)
                if FurnitureCatalog.isFixed(piece.kind) { Label("built in", systemImage: "lock.fill").font(.caption) }
            }
            if let note = piece.note, !note.isEmpty { Text("“\(note)”").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if let b = bearing {
                    let dir = SpaceWisdom.direction(x: piece.x, z: piece.z, bearing: b)
                    Label("\(dir) of the room", systemImage: "safari").font(.caption)
                    if let v = SpaceWisdom.vastu[dir] { Text(v).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            HStack {
                Button { turn(-15) } label: { Image(systemName: "rotate.left") }
                Button { turn(15) } label: { Image(systemName: "rotate.right") }
                Button { turn(90) } label: { Label("90°", systemImage: "arrow.clockwise") }
                Spacer()
                Button(action: onDuplicate) { Image(systemName: "plus.square.on.square") }
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
            }
            .buttonStyle(.bordered)
            .disabled(FurnitureCatalog.isFixed(piece.kind))
            sizeSlider("Width", value: $piece.width, range: 0.1...4)
            sizeSlider(piece.onWall ? "Thickness" : "Depth", value: $piece.depth, range: 0.02...3)
            sizeSlider("Height", value: $piece.height, range: 0.01...2.6)
            if piece.onWall { sizeSlider("Hang at", value: $piece.y, range: 0.2...2.4) }
        }
        .card()
    }

    private func turn(_ deg: Double) {
        piece.rotationDeg = GeoMath.normalize(piece.rotationDeg + deg)
        piece = DesignGeometry.clamp(piece, width: roomWidth, depth: roomDepth)
        onCommit()
    }

    private func sizeSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 70, alignment: .leading)
            Slider(value: value, in: range, onEditingChanged: { editing in
                if !editing {
                    piece = DesignGeometry.clamp(piece, width: roomWidth, depth: roomDepth)
                    onCommit()
                }
            })
            Text(String(format: "%.2f m", value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 56)
        }
    }
}

struct CatalogSheet: View {
    var onPick: (CatalogItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(Set(FurnitureCatalog.items.map(\.group))).sorted(), id: \.self) { group in
                    Section(group) {
                        ForEach(FurnitureCatalog.items.filter { $0.group == group }, id: \.kind) { item in
                            Button {
                                onPick(item)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: item.symbol).frame(width: 30).foregroundStyle(Palette.teal)
                                    VStack(alignment: .leading) {
                                        Text(item.name).foregroundStyle(.primary)
                                        Text(String(format: "%.2f × %.2f m%@", item.width, item.depth, item.onWall ? " · on the wall" : ""))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to the room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
