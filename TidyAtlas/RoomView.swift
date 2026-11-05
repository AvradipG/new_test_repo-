import PhotosUI
import QuickLook
import SwiftData
import SwiftUI
import TidyCore

struct RoomView: View {
    @Bindable var room: Room
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var organizer: Organizer

    enum Tab: String, CaseIterable { case map = "Map", things = "Things", plan = "Plan", photos = "Photos" }
    enum Filter: String, CaseIterable { case toSort = "To sort", outOfPlace = "Out of place", sorted = "Put away", all = "All" }

    @State private var tab = Tab.map
    @State private var filter = Filter.toSort
    @State private var selected: UUID?
    @State private var editingItem: Item?
    @State private var editingZone: Zone?
    @State private var editingRoom = false
    @State private var showCamera = false
    @State private var showRoomScan = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var energy = Energy.medium
    @State private var minutes = 15
    @State private var focus = false
    @State private var toast: String?
    @State private var errorText: String?
    @State private var quickLook: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                captureCard
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text(label(for: $0)).tag($0) }
                }
                .pickerStyle(.segmented)
                switch tab {
                case .map: mapTab
                case .things: thingsTab
                case .plan: planTab
                case .photos: photosTab
                }
            }
            .padding()
        }
        .background(Palette.paper)
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("Room details", systemImage: "slider.horizontal.3") { editingRoom = true }
                if room.usdzFile != nil {
                    Button("View LiDAR scan in AR", systemImage: "arkit") { quickLook = room.usdzFile.map(Storage.roomScanURL) }
                }
                Button("Delete room", systemImage: "trash", role: .destructive) {
                    Storage.removeFiles(of: room)
                    context.delete(room)
                    try? context.save()
                    dismiss()
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { media in run([media]) }.ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showRoomScan) {
            RoomScanSheet { captured in organizer.applyRoomScan(captured, to: room, context: context); toast = "Room size and furniture added to the map" }
        }
        .fullScreenCover(isPresented: $focus) { FocusView(room: room) }
        .sheet(item: $editingItem) { ItemEditor(item: $0, room: room) }
        .sheet(item: $editingZone) { ZoneEditor(zone: $0, room: room) }
        .sheet(isPresented: $editingRoom) { RoomEditor(room: room) }
        .quickLookPreview($quickLook)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let media = await ImageTools.load(items)
                pickerItems = []
                run(media)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3.5))
                        withAnimation { self.toast = nil }
                    }
            }
        }
        .alert("Something didn't work", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func label(for t: Tab) -> String {
        switch t {
        case .things: return "Things \(room.items.count)"
        case .plan: return room.todoSteps.isEmpty ? "Plan" : "Plan \(room.todoSteps.count)"
        default: return t.rawValue
        }
    }

    // MARK: Header and capture

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let place = room.place { Text(place.name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
            Text(room.name).font(.display(.largeTitle))
            if !room.summary.isEmpty { Text(room.summary).foregroundStyle(.secondary) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    chip("\(room.items.count) things")
                    chip("\(room.toSort.count) to sort")
                    if let c = room.clutterScore { chip("clutter \(c)/10") }
                    chip(String(format: "≈ %.1f × %.1f m%@", room.widthM, room.depthM, room.sizeFromScan ? " (LiDAR)" : ""))
                }
            }
        }
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.footnote.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = organizer.progress {
                Label(p.label, systemImage: "sparkles").font(.headline)
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                Text("Each photo takes Claude about 20–40 seconds. Keep the app open; the screen stays on.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Scan this space").font(.display(.title3))
                Text("Snap photos from a few corners, or film a slow 10-second walkthrough. Rough is fine.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button { showCamera = true } label: { Label("Camera", systemImage: "camera.fill") }
                        .buttonStyle(.borderedProminent)
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                        Label("Photos or video", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                if RoomScanSupport.isAvailable {
                    Button { showRoomScan = true } label: {
                        Label(room.sizeFromScan ? "Re-scan room with LiDAR" : "Scan room shape with LiDAR", systemImage: "viewfinder")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .card(Palette.tint)
    }

    private func run(_ media: [PickedMedia]) {
        guard !media.isEmpty else { return }
        guard KeyStore.hasKey else { errorText = ClaudeWire.Failure.noKey.errorDescription; return }
        Task {
            let r = await organizer.scan(media, into: room, context: context)
            if r.failed > 0 && r.failed == r.photos {
                errorText = r.lastError ?? "Claude couldn't read those photos."
            } else {
                var msg = "Found \(r.added) new thing\(r.added == 1 ? "" : "s")"
                if r.updated > 0 { msg += ", updated \(r.updated)" }
                if r.failed > 0 { msg += ". \(r.failed) photo(s) didn't work" }
                withAnimation { toast = msg }
                tab = .map
            }
        }
    }

    // MARK: Map

    private var mapTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Room3DView(snapshot: RoomSnapshot(room: room, selected: selected)) { id in selected = id }
                .frame(height: 420)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 14) {
                legend(.accentColor, "to sort")
                legend(.orange, "out of place")
                legend(.green, "put away")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Drag to turn · pinch to zoom · tap a dot. Arcs show where each thing goes.")
                .font(.footnote).foregroundStyle(.secondary)

            if let id = selected, let item = room.items.first(where: { $0.uid == id }) {
                ItemPanel(item: item, room: room, onEdit: { editingItem = item }, onClose: { selected = nil })
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Storage spots").font(.display(.headline))
                if room.zones.isEmpty {
                    Text("None yet. Scan a photo or the room, or add your shelves, drawers and bins.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(room.zones.sorted { $0.createdAt < $1.createdAt }) { z in
                    let incoming = room.toSort.filter { $0.suggestedZoneID == z.uid }.count
                    Button { editingZone = z } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(z.name).font(.body.weight(.semibold))
                                Text(z.kind.label + (z.isIdea ? " · idea, not set up yet" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if incoming > 0 {
                                Text("\(incoming) incoming").font(.caption.weight(.bold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Palette.teal, in: Capsule()).foregroundStyle(.white)
                            }
                        }
                        .padding(12)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    let z = Zone(name: "New spot", kind: .shelf)
                    z.posZ = 0.1
                    z.room = room
                    context.insert(z)
                    editingZone = z
                } label: { Label("Add storage spot", systemImage: "plus") }
                    .buttonStyle(.bordered)
            }
            .card()
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 9, height: 9); Text(t) }
    }

    // MARK: Things

    private var thingsTab: some View {
        let items = room.items.filter { it in
            switch filter {
            case .toSort: return !it.isSorted
            case .outOfPlace: return !it.isSorted && it.outOfPlace
            case .sorted: return it.isSorted
            case .all: return true
            }
        }.sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if items.isEmpty {
                Text(room.items.isEmpty ? "No things yet. Scan a photo above." : "Nothing here. Nice.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
            }
            ForEach(items) { item in
                HStack(spacing: 12) {
                    Button { editingItem = item } label: {
                        HStack(spacing: 12) {
                            ItemThumb(file: item.thumbFile, category: item.category, size: 56)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text((item.quantity > 1 ? "\(item.quantity)× " : "") + item.name).font(.body.weight(.semibold))
                                    if item.outOfPlace && !item.isSorted { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
                                }
                                Text(item.action.label + (room.zone(item.suggestedZoneID).map { " → \($0.name)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                                if !item.tags.isEmpty {
                                    Text(item.tags.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    if item.isSorted {
                        Label("home", systemImage: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                    } else {
                        Button {
                            item.putAway()
                            try? context.save()
                            Haptics.success()
                        } label: { Label("Done", systemImage: "checkmark") }
                            .buttonStyle(.bordered)
                    }
                }
                .card()
            }
        }
    }

    // MARK: Plan

    private var planTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("How are you feeling?").font(.display(.headline))
                Picker("Energy", selection: $energy) {
                    ForEach(Energy.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Time", selection: $minutes) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
                Button {
                    Task {
                        do {
                            let pep = try await organizer.makePlan(for: room, energy: energy, minutes: minutes, context: context)
                            withAnimation { toast = pep }
                        } catch { errorText = error.localizedDescription }
                    }
                } label: {
                    HStack {
                        if organizer.busy { ProgressView() } else { Image(systemName: room.todoSteps.isEmpty ? "wand.and.stars" : "arrow.clockwise") }
                        Text(organizer.busy ? "Claude is planning…" : room.todoSteps.isEmpty ? "Make my plan" : "Re-plan")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(organizer.busy || room.toSort.isEmpty)
                if room.toSort.isEmpty { Text("Scan the room first so there's something to plan.").font(.footnote).foregroundStyle(.secondary) }
            }
            .card()

            if !room.todoSteps.isEmpty {
                Button { focus = true } label: {
                    Label("Start focus mode: one step at a time", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)

                let trips = Array(Set(room.todoSteps.map(\.trip))).sorted()
                ForEach(trips, id: \.self) { trip in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TRIP \(trip)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        ForEach(room.todoSteps.filter { $0.trip == trip }) { step in
                            HStack(alignment: .top, spacing: 12) {
                                Button { organizer.complete(step, in: room, context: context) } label: {
                                    Image(systemName: "circle").font(.title2)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Palette.teal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.title).font(.body.weight(.semibold))
                                    if !step.detail.isEmpty { Text(step.detail).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text("\(step.minutes)m").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .card()
                        }
                    }
                }
            }
            let done = room.steps.filter { $0.status == .done }.count
            if done > 0 { Text("✓ \(done) steps done in this room so far.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    // MARK: Photos

    private var photosTab: some View {
        let captures = room.captures.sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 10) {
            if captures.isEmpty { Text("No photos yet.").foregroundStyle(.secondary).padding(30) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(captures) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        Group {
                            if let img = UIImage(contentsOfFile: Storage.captureURL(c.file).path) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else { Rectangle().fill(.quaternary) }
                        }
                        .frame(height: 120).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        switch c.status {
                        case .analyzed: Text("\(c.itemCount) things").font(.caption).foregroundStyle(.secondary)
                        case .analyzing: Text("Claude is looking…").font(.caption).foregroundStyle(.secondary)
                        case .waiting: Text("Waiting").font(.caption).foregroundStyle(.secondary)
                        case .failed:
                            Text(c.error ?? "Failed").font(.caption).foregroundStyle(.red).lineLimit(3)
                            Button("Try again") {
                                Task {
                                    do { try await organizer.analyze(c, in: room, context: context); toast = "Photo analysed" }
                                    catch { errorText = error.localizedDescription }
                                }
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                    .contextMenu {
                        Button("Delete photo", systemImage: "trash", role: .destructive) {
                            Storage.remove(capture: c.file)
                            context.delete(c)
                            try? context.save()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Panels and editors

struct ItemPanel: View {
    let item: Item
    let room: Room
    var onEdit: () -> Void
    var onClose: () -> Void
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ItemThumb(file: item.thumbFile, category: item.category, size: 72)
                VStack(alignment: .leading) {
                    Text((item.quantity > 1 ? "\(item.quantity)× " : "") + item.name).font(.display(.headline))
                    Text(item.category).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
            }
            Grid(alignment: .leading, verticalSpacing: 4) {
                GridRow { Text("Now").foregroundStyle(.secondary); Text(room.zone(item.zoneID)?.name ?? "Loose / on a surface") }
                GridRow { Text("Goes to").foregroundStyle(.secondary); Text(room.zone(item.suggestedZoneID)?.name ?? (item.action == .keep ? "Stays where it is" : "Another room / not decided")) }
                GridRow { Text("Plan").foregroundStyle(.secondary); Text(item.action.label) }
            }
            .font(.callout)
            if !item.reason.isEmpty {
                Text("“\(item.reason)”").font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.tint, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                if !item.isSorted {
                    Button {
                        item.putAway()
                        try? context.save()
                        Haptics.success()
                    } label: { Label("I put it away", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                }
                Button(action: onEdit) { Label("Edit", systemImage: "pencil") }.buttonStyle(.bordered)
            }
        }
        .card()
    }
}

struct ItemEditor: View {
    @Bindable var item: Item
    let room: Room
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var tagsText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        ItemThumb(file: item.thumbFile, category: item.category, size: 64)
                        TextField("Name", text: $item.name).font(.headline)
                    }
                    Stepper("Quantity: \(item.quantity)", value: $item.quantity, in: 1...999)
                    Picker("Category", selection: $item.category) {
                        ForEach(Categories.all, id: \.self) { Label($0, systemImage: Categories.symbol($0)).tag($0) }
                    }
                    TextField("Tags, comma separated", text: $tagsText)
                    TextField("Notes", text: $item.notes, axis: .vertical)
                }
                Section("Where") {
                    Picker("Now in", selection: $item.zoneID) {
                        Text("Loose / on a surface").tag(UUID?.none)
                        ForEach(room.zones) { Text($0.name).tag(Optional($0.uid)) }
                    }
                    Picker("Should live in", selection: $item.suggestedZoneID) {
                        Text("Another room / not decided").tag(UUID?.none)
                        ForEach(room.zones) { Text($0.name).tag(Optional($0.uid)) }
                    }
                    Picker("Plan", selection: Binding(get: { item.action }, set: { item.action = $0 })) {
                        ForEach(ItemAction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Out of place", isOn: $item.outOfPlace)
                    Toggle("Put away (done)", isOn: $item.isSorted)
                }
                if !item.reason.isEmpty { Section("Claude's note") { Text(item.reason) } }
                Section {
                    Button("Remove this thing", role: .destructive) {
                        Storage.remove(thumb: item.thumbFile)
                        context.delete(item)
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Edit thing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        item.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                        item.updatedAt = Date()
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .onAppear { tagsText = item.tags.joined(separator: ", ") }
        }
    }
}

struct ZoneEditor: View {
    @Bindable var zone: Zone
    let room: Room
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Top desk drawer", text: $zone.name)
                    Picker("Kind", selection: Binding(get: { zone.kind }, set: { zone.kind = $0 })) {
                        ForEach(ZoneKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if zone.isIdea {
                        Button("I've set this up", systemImage: "checkmark.circle") { zone.isIdea = false }
                    }
                }
                Section {
                    LabeledContent("Left ↔ right") { Slider(value: $zone.posX, in: 0...1) }
                    LabeledContent("Far wall ↔ near") { Slider(value: $zone.posZ, in: 0...1) }
                    LabeledContent("Height off floor") { Slider(value: $zone.posY, in: 0...1) }
                } header: { Text("Rough place in the room") } footer: { Text("Rough is perfect. It just helps you picture where things go.") }
                Section {
                    Button("Delete spot", role: .destructive) {
                        for it in room.items {
                            if it.zoneID == zone.uid { it.zoneID = nil }
                            if it.suggestedZoneID == zone.uid { it.suggestedZoneID = nil }
                        }
                        context.delete(zone)
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Storage spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { try? context.save(); dismiss() } }
            }
        }
    }
}

struct RoomEditor: View {
    @Bindable var room: Room
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $room.name)
                Section {
                    LabeledContent(String(format: "Width %.1f m", room.widthM)) { Slider(value: $room.widthM, in: 1...15, step: 0.1) }
                    LabeledContent(String(format: "Depth %.1f m", room.depthM)) { Slider(value: $room.depthM, in: 1...15, step: 0.1) }
                    LabeledContent(String(format: "Ceiling %.1f m", room.heightM)) { Slider(value: $room.heightM, in: 2...5, step: 0.1) }
                } header: { Text("Rough size") } footer: {
                    Text(room.sizeFromScan ? "Measured with the LiDAR room scan." : "Guessed from your photos. Adjust if the map looks off.")
                }
            }
            .navigationTitle("Room details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { try? context.save(); dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
