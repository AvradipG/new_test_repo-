import SwiftData
import SwiftUI
import TidyCore
import UIKit

/// A room with its place on the map (a wrapper so ForEach gets an id).
struct MappedRoom: Identifiable {
    let room: Room
    let placement: RoomPlacement
    var id: UUID { room.uid }
}

/// The part of the place frame shown on screen (metres).
struct MapFrame: Equatable {
    var minX: Double
    var minZ: Double
    var maxX: Double
    var maxZ: Double

    @MainActor
    static func fit(_ place: Place) -> MapFrame {
        let pts = place.mappedRooms.flatMap { $0.1.corners(width: $0.0.widthM, depth: $0.0.depthM) }
        var f = MapFrame(minX: (pts.map(\.0).min() ?? -3) - 1, minZ: (pts.map(\.1).min() ?? -3) - 1,
                         maxX: (pts.map(\.0).max() ?? 3) + 1, maxZ: (pts.map(\.1).max() ?? 3) + 1)
        let w = f.maxX - f.minX, d = f.maxZ - f.minZ
        if w < 6 { f.minX -= (6 - w) / 2; f.maxX += (6 - w) / 2 }
        if d < 6 { f.minZ -= (6 - d) / 2; f.maxZ += (6 - d) / 2 }
        return f
    }
}

/// Screen ↔ map conversion for one canvas size.
struct MapGeometry {
    let frame: MapFrame
    let scale: Double
    let ox: Double
    let oz: Double

    init(frame: MapFrame, size: CGSize) {
        self.frame = frame
        let w = Double(size.width), h = Double(size.height)
        scale = max(1, min(w / (frame.maxX - frame.minX), h / (frame.maxZ - frame.minZ)))
        ox = (w - (frame.maxX - frame.minX) * scale) / 2
        oz = (h - (frame.maxZ - frame.minZ) * scale) / 2
    }

    func screen(_ x: Double, _ z: Double) -> CGPoint {
        CGPoint(x: ox + (x - frame.minX) * scale, y: oz + (z - frame.minZ) * scale)
    }

    func map(_ p: CGPoint) -> (Double, Double) {
        ((Double(p.x) - ox) / scale + frame.minX, (Double(p.y) - oz) / scale + frame.minZ)
    }
}

/// A set of photos to page through full screen.
struct PhotoSet: Identifiable {
    let id = UUID()
    var files: [String]
    var start: Int
}

/// Edit the map of a place: drag rooms, drag their sides to set boundaries, draw new rooms with a finger, name
/// rooms right on the map, split a scan that covered several rooms, see a room's photos, undo, and keep versions.
struct PlaceMapEditor: View {
    @Bindable var place: Place
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var organizer: Organizer

    enum Mode: Hashable { case move, draw }

    struct DragStart {
        var id: UUID
        var placement: RoomPlacement
        var width: Double
        var depth: Double
        var edge: MapEdit.Edge?
    }

    struct UndoEntry {
        var snapshot: MapSnapshot
        var created: UUID?
    }

    @State private var selected: UUID?
    @State private var mode: Mode = .move
    @State private var frozen: MapFrame?
    @State private var drag: DragStart?
    @State private var drawFrom: CGPoint?
    @State private var drawTo: CGPoint?
    @State private var drawFor: UUID?
    @State private var undoStack: [UndoEntry] = []
    @State private var naming: Room?
    @State private var showVersions = false
    @State private var nameText = ""
    @State private var photos: PhotoSet?
    @State private var sectionCount = 0
    @State private var multiRooms: [UUID] = []
    @State private var confirmSplit: Room?
    @State private var message: String?
    @FocusState private var nameFocused: Bool

    private var selectedRoom: Room? { selected.flatMap { id in place.rooms.first { $0.uid == id } } }

    var body: some View {
        VStack(spacing: 10) {
            topBar
            canvas
                .frame(minHeight: 280, maxHeight: .infinity)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    splitBanner
                    if let room = selectedRoom { inspector(room) } else { idleHint }
                    unmappedList
                }
            }
            .frame(maxHeight: selected == nil ? 220 : 340)
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(item: $naming) { RoomNameSheet(room: $0) }
        .sheet(isPresented: $showVersions) { MapVersionsSheet(place: place) }
        .fullScreenCover(item: $photos) { PhotoViewer(set: $0) }
        .alert("Map", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
        .confirmationDialog("Split this scan into rooms?", isPresented: Binding(get: { confirmSplit != nil }, set: { if !$0 { confirmSplit = nil } }),
                            titleVisibility: .visible, presenting: confirmSplit) { room in
            Button("Split into rooms") { split(room) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The scan saw several rooms. Each becomes its own room you can name; storage spots and things go to the room they stand in. A map version is saved first.")
        }
        .onChange(of: selected) { _, _ in
            nameText = selectedRoom.map { $0.needsName ? "" : $0.name } ?? ""
        }
        .task(id: selected) {
            sectionCount = selectedRoom.map { $0.sectionsSplit ? 0 : Organizer.sections(of: $0).count } ?? 0
        }
        .task(id: place.rooms.count) {
            multiRooms = place.rooms.filter { !$0.sectionsSplit && $0.capturedRoomFile != nil && $0.hasScanWalls }
                .filter { Organizer.sections(of: $0).count > 1 }.map(\.uid)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: $mode) {
                Label("Move", systemImage: "hand.point.up.left").tag(Mode.move)
                Label("Draw room", systemImage: "square.dashed").tag(Mode.draw)
            }
            .pickerStyle(.segmented)
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(undoStack.isEmpty)
                .accessibilityLabel("Undo")
            Button { showVersions = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .accessibilityLabel("Map versions")
        }
        .buttonStyle(.bordered)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let g = MapGeometry(frame: frozen ?? MapFrame.fit(place), size: geo.size)
            ZStack {
                grid(g, size: geo.size)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil; nameFocused = false }
                    .gesture(drawGesture(g), including: mode == .draw ? GestureMask.all : GestureMask.subviews)
                ForEach(place.mappedRooms.map { MappedRoom(room: $0.0, placement: $0.1) }) { m in
                    roomView(m, g)
                }
                .allowsHitTesting(mode == .move)
                if mode == .move, let room = selectedRoom, let pl = room.placement, !room.hasScanWalls {
                    handles(room, pl, g)
                }
                if let a = drawFrom, let b = drawTo {
                    Path { p in p.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))) }
                        .stroke(Palette.teal, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    let s = MapEdit.rect(from: g.map(a), to: g.map(b))
                    Text(String(format: "%.1f × %.1f m", s.width, s.depth))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(6).background(.white, in: Capsule())
                        .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                }
                compass(geo.size)
                if place.mappedRooms.isEmpty && drawFrom == nil {
                    Text(mode == .draw ? "Drag a finger to draw a room." : "No rooms on the map yet. Pick “Draw room” to draw one, or scan the place.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func grid(_ g: MapGeometry, size: CGSize) -> some View {
        Path { p in
            let f = g.frame
            var x = f.minX.rounded(.down)
            while x <= f.maxX {
                p.move(to: g.screen(x, f.minZ))
                p.addLine(to: g.screen(x, f.maxZ))
                x += 1
            }
            var z = f.minZ.rounded(.down)
            while z <= f.maxZ {
                p.move(to: g.screen(f.minX, z))
                p.addLine(to: g.screen(f.maxX, z))
                z += 1
            }
        }
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        .allowsHitTesting(false)
    }

    private func roomView(_ m: MappedRoom, _ g: MapGeometry) -> some View {
        let room = m.room, pl = m.placement
        let isSel = room.uid == selected
        let corners = pl.corners(width: room.widthM, depth: room.depthM).map { g.screen($0.0, $0.1) }
        let fill = Path { p in
            p.addLines(corners)
            p.closeSubpath()
        }
        let walls = Path { p in
            for w in room.layout?.walls ?? [] {
                let c = w.corners
                let a = pl.toPlace(x: c[0].0, z: c[0].1), b = pl.toPlace(x: c[1].0, z: c[1].1)
                p.move(to: g.screen(a.x, a.z))
                p.addLine(to: g.screen(b.x, b.z))
            }
        }
        let tint: Color = room.needsName ? Color.orange.opacity(0.18) : Color(red: 0.93, green: 0.90, blue: 0.84).opacity(0.85)
        return ZStack {
            fill.fill(isSel ? Palette.teal.opacity(0.22) : tint)
            if room.hasScanWalls {
                fill.stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                walls.stroke(isSel ? Palette.teal : Color.primary, lineWidth: isSel ? 4 : 3)
            } else {
                fill.stroke(isSel ? Palette.teal : Color.primary, lineWidth: isSel ? 4 : 3)
            }
            roomLabel(room).position(g.screen(pl.x, pl.z))
        }
        .contentShape(fill)
        .onTapGesture { select(room) }
        .gesture(moveGesture(room, pl, g))
    }

    private func roomLabel(_ room: Room) -> some View {
        VStack(spacing: 2) {
            Text(room.needsName ? "Name me" : room.name)
                .font(.caption.weight(.bold))
                .foregroundStyle(room.needsName ? .orange : .primary)
            if room.needsName, let n = room.nameIdeas.first, room.sectionLabel != nil {
                Text(n + "?").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.white.opacity(0.7), in: Capsule())
    }

    private func handles(_ room: Room, _ pl: RoomPlacement, _ g: MapGeometry) -> some View {
        ForEach(MapEdit.Edge.allCases, id: \.self) { edge in
            let h = MapEdit.handle(edge, width: room.widthM, depth: room.depthM)
            let q = pl.toPlace(x: h.x, z: h.z)
            Circle()
                .fill(.white)
                .overlay(Circle().stroke(Palette.teal, lineWidth: 3))
                .frame(width: 24, height: 24)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .position(g.screen(q.x, q.z))
                .gesture(resizeGesture(room, pl, edge, g))
        }
    }

    private func compass(_ size: CGSize) -> some View {
        Group {
            if let b = place.northBearing {
                VStack(spacing: 0) {
                    Image(systemName: "location.north.line.fill").rotationEffect(.degrees(-b))
                    Text("N").font(.caption2.weight(.bold))
                }
                .foregroundStyle(.red)
                .position(x: size.width - 26, y: 30)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: Gestures

    private func moveGesture(_ room: Room, _ pl: RoomPlacement, _ g: MapGeometry) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if drag == nil {
                    begin(g)
                    drag = DragStart(id: room.uid, placement: pl, width: room.widthM, depth: room.depthM, edge: nil)
                    selected = room.uid
                }
                guard let d = drag, d.id == room.uid else { return }
                room.mapRotationDeg = d.placement.rotationDeg
                room.mapX = d.placement.x + Double(v.translation.width) / g.scale
                room.mapZ = d.placement.z + Double(v.translation.height) / g.scale
            }
            .onEnded { _ in end("Moved \(room.name) on the map", room: room) }
    }

    private func resizeGesture(_ room: Room, _ pl: RoomPlacement, _ edge: MapEdit.Edge, _ g: MapGeometry) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if drag == nil {
                    begin(g)
                    drag = DragStart(id: room.uid, placement: pl, width: room.widthM, depth: room.depthM, edge: edge)
                }
                guard let d = drag, d.id == room.uid, d.edge == edge else { return }
                let r = MapEdit.resize(d.placement, width: d.width, depth: d.depth, edge: edge,
                                       dragX: Double(v.translation.width) / g.scale, dragZ: Double(v.translation.height) / g.scale)
                room.mapX = r.placement.x
                room.mapZ = r.placement.z
                room.mapRotationDeg = r.placement.rotationDeg
                room.widthM = r.width
                room.depthM = r.depth
                room.boundaryEdited = true
            }
            .onEnded { _ in end(String(format: "Set the size of %@ to %.1f × %.1f m", room.name, room.widthM, room.depthM), room: room) }
    }

    private func drawGesture(_ g: MapGeometry) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if frozen == nil { frozen = g.frame }
                drawFrom = v.startLocation
                drawTo = v.location
            }
            .onEnded { v in
                let a = g.map(v.startLocation), b = g.map(v.location)
                drawFrom = nil
                drawTo = nil
                finishDraw(a, b)
                frozen = nil
            }
    }

    // MARK: Editing

    /// Before every change: remember the map for undo (and keep a version of the map as it was before the first edit).
    private func pushUndo(created: UUID? = nil) {
        if place.mapVersions.isEmpty && !place.rooms.isEmpty {
            organizer.saveMapVersion(place, name: "Before my first edit", context: context)
        }
        undoStack.append(UndoEntry(snapshot: place.mapSnapshot(), created: created))
        if undoStack.count > 40 { undoStack.removeFirst() }
    }

    private func begin(_ g: MapGeometry) {
        pushUndo()
        frozen = g.frame
    }

    private func end(_ log: String, room: Room) {
        drag = nil
        frozen = nil
        ActivityLog.add(.map, log, room: room, in: context)
        save()
        Haptics.tap()
    }

    private func save() {
        try? context.save()
        organizer.scheduleDriveSync()
    }

    private func select(_ room: Room) {
        selected = selected == room.uid ? nil : room.uid
        nameFocused = false
    }

    private func finishDraw(_ a: (Double, Double), _ b: (Double, Double)) {
        let r = MapEdit.rect(from: a, to: b)
        let room: Room
        if let id = drawFor, let existing = place.rooms.first(where: { $0.uid == id }) {
            pushUndo()
            room = existing
        } else {
            pushUndo()
            room = Room(name: "Room \(place.rooms.count + 1)")
            room.needsName = true
            room.place = place
            context.insert(room)
            undoStack[undoStack.count - 1].created = room.uid
        }
        room.mapX = r.placement.x
        room.mapZ = r.placement.z
        room.mapRotationDeg = 0
        if !room.hasScanWalls {
            room.widthM = r.width
            room.depthM = r.depth
            room.boundaryEdited = true
        }
        drawFor = nil
        mode = .move
        selected = room.uid
        nameText = room.needsName ? "" : room.name
        ActivityLog.add(.map, String(format: "Drew %@ on the map of %@ (%.1f × %.1f m)", room.name, place.name, room.widthM, room.depthM),
                        room: room, in: context)
        save()
        Haptics.success()
        if room.needsName { nameFocused = true }
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        if let id = last.created, let r = place.rooms.first(where: { $0.uid == id }) {
            if r.isEmptyShell {
                if selected == id { selected = nil }
                context.delete(r)
            } else {
                r.mapX = nil
                r.mapZ = nil
            }
        }
        organizer.apply(last.snapshot, to: place)
        ActivityLog.add(.map, "Undid a map edit of \(place.name)", in: context)
        save()
    }

    private func commitName(_ room: Room) {
        let n = nameText.trimmingCharacters(in: .whitespaces)
        nameFocused = false
        guard !n.isEmpty, n != room.name || room.needsName else { return }
        pushUndo()
        let old = room.name
        room.name = n
        room.needsName = false
        ActivityLog.add(.rename, old == n ? "Named \(n)" : "Named \(old) “\(n)”", room: room, in: context)
        save()
        Haptics.success()
    }

    private func turn(_ room: Room, _ deg: Double) {
        guard let p = room.placement else { return }
        pushUndo()
        room.mapX = p.x
        room.mapZ = p.z
        room.mapRotationDeg = GeoMath.normalize(p.rotationDeg + deg)
        ActivityLog.add(.map, "Turned \(room.name) on the map", room: room, in: context)
        save()
    }

    private func putOnMap(_ room: Room) {
        pushUndo()
        let others = place.mappedRooms.map { $0.1.corners(width: $0.0.widthM, depth: $0.0.depthM) }
        let spot = RoomPlacement.nextFree(after: others, width: room.widthM)
        room.mapX = spot.x
        room.mapZ = spot.z
        room.mapRotationDeg = 0
        selected = room.uid
        ActivityLog.add(.map, "Put \(room.name) on the map", room: room, in: context)
        save()
    }

    private func split(_ room: Room) {
        let made = organizer.splitBySections(room, context: context)
        undoStack.removeAll()
        if made.isEmpty {
            message = "This scan has only one room in it."
        } else {
            sectionCount = 0
            multiRooms.removeAll { $0 == room.uid }
            selected = made.first?.uid
            message = "Found \(made.count + 1) rooms. Tap each one (orange) to name it. A version of the map from before the split is saved."
        }
    }

    // MARK: Panels

    @ViewBuilder private var splitBanner: some View {
        let rooms = place.sortedRooms.filter { multiRooms.contains($0.uid) }
        if !rooms.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Some scans look like more than one room", systemImage: "square.split.2x1").font(.headline)
                Text("The scanner recognised separate rooms or passages inside one scan. Split them, then name each one.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(rooms) { r in
                    Button { confirmSplit = r } label: { Label("Split \(r.name)", systemImage: "scissors") }
                        .buttonStyle(.bordered)
                }
            }
            .card(Palette.tint)
        }
    }

    private var idleHint: some View {
        Text(mode == .draw
             ? "Drag a finger across the map to draw a room. It starts unnamed; type its name right after."
             : "Tap a room to name it, see its photos and set its sides. Drag a room to move it. Hand-drawn rooms have round handles on each side for their boundaries.")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspector(_ room: Room) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(room.needsName ? "Name this room" : "Room name", text: $nameText)
                    .font(.display(.title3))
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit { commitName(room) }
                Button("Save") { commitName(room) }
                    .buttonStyle(.borderedProminent)
                    .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(room.nameIdeas, id: \.self) { s in
                        Button(s) {
                            nameText = s
                            commitName(room)
                        }
                        .buttonStyle(.bordered).font(.footnote)
                    }
                }
            }
            HStack {
                Text(String(format: "%.1f × %.1f m", room.widthM, room.depthM) + (room.hasScanWalls ? " · walls from the scan" : ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Tags & AI names") { naming = room }.font(.footnote)
            }
            HStack {
                Button { turn(room, -15) } label: { Image(systemName: "rotate.left") }
                Button { turn(room, 15) } label: { Image(systemName: "rotate.right") }
                Button { turn(room, 90) } label: { Label("90°", systemImage: "arrow.clockwise") }
                Spacer()
                NavigationLink(value: room) { Label("Open", systemImage: "arrow.up.right.square") }
            }
            .buttonStyle(.bordered)
            if sectionCount > 1 {
                Button { confirmSplit = room } label: {
                    Label("Find the \(sectionCount) rooms in this scan", systemImage: "square.split.2x1")
                }
                .buttonStyle(.borderedProminent)
            }
            photoStrip(room)
            roomActions(room)
        }
        .card()
    }

    @ViewBuilder private func photoStrip(_ room: Room) -> some View {
        let caps = room.captures.sorted { $0.createdAt > $1.createdAt }
        if caps.isEmpty {
            Text("No photos of this room yet. Open it to add some.").font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(caps.enumerated()), id: \.offset) { n, c in
                        CaptureThumb(file: c.file, size: 76)
                            .onTapGesture { photos = PhotoSet(files: caps.map(\.file), start: n) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func roomActions(_ room: Room) -> some View {
        HStack {
            if room.mapX != nil && room.fromHouseScan && room.layout?.originX != nil && !room.sectionsSplit {
                Button("Back to scan position") {
                    pushUndo()
                    room.mapX = nil
                    room.mapZ = nil
                    room.mapRotationDeg = 0
                    save()
                }
            } else if !room.fromHouseScan {
                Button("Take off the map") {
                    pushUndo()
                    room.mapX = nil
                    room.mapZ = nil
                    selected = nil
                    save()
                }
            }
            Spacer()
            if room.isEmptyShell {
                Button("Delete", role: .destructive) {
                    pushUndo()
                    selected = nil
                    ActivityLog.add(.map, "Deleted the empty room \(room.name)", in: context)
                    context.delete(room)
                    save()
                }
            }
        }
        .font(.footnote)
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var unmappedList: some View {
        let unmapped = place.sortedRooms.filter { $0.placement == nil }
        if !unmapped.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Not on the map yet").font(.display(.headline))
                ForEach(unmapped) { r in
                    HStack {
                        Text(r.displayName).lineLimit(1)
                        Spacer()
                        Button("Draw it") {
                            drawFor = r.uid
                            mode = .draw
                        }
                        Button("Place it") { putOnMap(r) }
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }
            }
            .card()
        }
    }
}

/// Saved versions of a place's map: save one now, see what changed since, go back to one.
struct MapVersionsSheet: View {
    @Bindable var place: Place
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var organizer: Organizer
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name (e.g. After moving the desk)", text: $name)
                    Button("Save the map as it is now") {
                        organizer.saveMapVersion(place, name: name, context: context)
                        name = ""
                    }
                } footer: {
                    Text("Versions keep every room's name, place, turn, size and walls. Going back saves the current map first, so nothing is lost.")
                }
                Section("Saved versions") {
                    let current = place.mapSnapshot()
                    ForEach(place.mapVersions.sorted { $0.date > $1.date }) { v in
                        versionRow(v, current: current)
                    }
                    .onDelete { idx in
                        let sorted = place.mapVersions.sorted { $0.date > $1.date }
                        for i in idx { context.delete(sorted[i]) }
                        try? context.save()
                    }
                }
            }
            .navigationTitle("Map versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func versionRow(_ v: MapVersion, current: MapSnapshot) -> some View {
        let changes = v.snapshot.map { current.changes(from: $0) } ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(v.name).font(.body.weight(.semibold))
                Spacer()
                Button("Go back to this") {
                    organizer.restoreMapVersion(v, context: context)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .disabled(changes.isEmpty)
            }
            Text(v.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            Text(changes.isEmpty ? "Same as now" : "Since then: " + changes.prefix(4).joined(separator: "; ") + (changes.count > 4 ? "…" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A photo thumbnail loaded off the main thread.
struct CaptureThumb: View {
    let file: String
    var size: CGFloat = 84
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Palette.tint)
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: file) { image = await CaptureThumb.load(file, side: size * 2.5) }
    }

    static func load(_ file: String, side: CGFloat) async -> UIImage? {
        let path = Storage.captureURL(file).path
        return await Task.detached(priority: .utility) { () -> UIImage? in
            guard let img = UIImage(contentsOfFile: path), img.size.width > 0, img.size.height > 0 else { return nil }
            let k = min(1, side / max(img.size.width, img.size.height))
            return img.preparingThumbnail(of: CGSize(width: img.size.width * k, height: img.size.height * k)) ?? img
        }.value
    }
}

/// Real photos of the place, full screen, swipe between them.
struct PhotoViewer: View {
    let set: PhotoSet
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(set.files.enumerated()), id: \.offset) { n, f in
                    FullPhoto(file: f).tag(n)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.largeTitle).symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.5))
            }
            .padding()
        }
        .onAppear { index = set.start }
    }
}

struct FullPhoto: View {
    let file: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: file) { image = await CaptureThumb.load(file, side: 2400) }
    }
}

/// Name a room (now or later), with suggestions from RoomPlan and the AI, and tags.
struct RoomNameSheet: View {
    @Bindable var room: Room
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var organizer: Organizer
    @State private var name = ""
    @State private var tagsText = ""
    @State private var suggestions: [String] = []
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Room name", text: $name)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(suggestions + room.nameIdeas.filter { !suggestions.contains($0) }, id: \.self) { s in
                                Button(s) { name = s }.buttonStyle(.bordered).font(.footnote)
                            }
                        }
                    }
                    Button {
                        Task {
                            do {
                                let r = try await organizer.suggestRoomNames(room)
                                suggestions = r.names
                                if tagsText.isEmpty { tagsText = r.tags.joined(separator: ", ") }
                                if let first = r.names.first, room.needsName && name.isEmpty { name = first }
                            } catch { errorText = error.localizedDescription }
                        }
                    } label: {
                        if organizer.busy { ProgressView() } else { Label("Suggest from what's in the room", systemImage: "sparkles") }
                    }
                    .disabled(organizer.busy || !KeyStore.hasKey)
                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
                }
                Section {
                    TextField("work, guests, kids, storage…", text: $tagsText)
                } header: { Text("Tags") } footer: { Text("Tags help you find rooms and let the designer and planner know what the room is for.") }
            }
            .navigationTitle(room.needsName ? "Name this room" : "Rename room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty && (n != room.name || room.needsName) {
                            let old = room.name
                            room.name = n
                            room.needsName = false
                            ActivityLog.add(.rename, old == n ? "Named \(n)" : "Named \(old) “\(n)”", room: room, in: context)
                        }
                        room.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                        try? context.save()
                        organizer.scheduleDriveSync()
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = room.needsName ? "" : room.name
                tagsText = room.tags.joined(separator: ", ")
            }
        }
        .presentationDetents([.medium, .large])
    }
}
