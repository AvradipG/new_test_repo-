import SwiftData
import SwiftUI
import TidyCore

/// Correct the place map by hand: drag rooms, turn them, put rooms on the map that were scanned on their own or
/// only photographed, and name or tag them.
struct MappedRoom: Identifiable {
    let room: Room
    let placement: RoomPlacement
    var id: UUID { room.uid }
}

struct PlaceMapEditor: View {
    @Bindable var place: Place
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var organizer: Organizer
    @State private var selected: UUID?
    @State private var dragStart: [UUID: (Double, Double)] = [:]
    @State private var naming: Room?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            canvas
                .frame(height: 420)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            if let id = selected, let room = place.rooms.first(where: { $0.uid == id }) { inspector(room) }
            let unmapped = place.sortedRooms.filter { $0.placement == nil }
            if !unmapped.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not on the map yet").font(.display(.headline))
                    ForEach(unmapped) { r in
                        HStack {
                            Text(r.displayName)
                            Spacer()
                            Button("Put on the map") { putOnMap(r) }.buttonStyle(.bordered)
                        }
                    }
                }
                .card()
            }
            Text("Drag a room to move it. Tap it to turn it, rename it or put it back where the scan placed it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .sheet(item: $naming) { RoomNameSheet(room: $0) }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let mapped = place.mappedRooms
            let pts = mapped.flatMap { $0.1.corners(width: $0.0.widthM, depth: $0.0.depthM) }
            let minX = (pts.map(\.0).min() ?? -3) - 1, maxX = (pts.map(\.0).max() ?? 3) + 1
            let minZ = (pts.map(\.1).min() ?? -3) - 1, maxZ = (pts.map(\.1).max() ?? 3) + 1
            let scale = min(geo.size.width / (maxX - minX), geo.size.height / (maxZ - minZ))
            let ox = (geo.size.width - (maxX - minX) * scale) / 2, oz = (geo.size.height - (maxZ - minZ) * scale) / 2
            let toScreen = { (x: Double, z: Double) -> CGPoint in CGPoint(x: ox + (x - minX) * scale, y: oz + (z - minZ) * scale) }
            ZStack {
                ForEach(mapped.map { MappedRoom(room: $0.0, placement: $0.1) }) { m in
                    let room = m.room, pl = m.placement
                    let isSel = room.uid == selected
                    let outline = Path { p in
                        if let walls = room.layout?.walls, !walls.isEmpty {
                            for w in walls {
                                let c = w.corners
                                let a = pl.toPlace(x: c[0].0, z: c[0].1), b = pl.toPlace(x: c[1].0, z: c[1].1)
                                p.move(to: toScreen(a.x, a.z))
                                p.addLine(to: toScreen(b.x, b.z))
                            }
                        } else {
                            let c = pl.corners(width: room.widthM, depth: room.depthM)
                            p.addLines(c.map { toScreen($0.0, $0.1) })
                            p.closeSubpath()
                        }
                    }
                    let fill = Path { p in
                        p.addLines(pl.corners(width: room.widthM, depth: room.depthM).map { toScreen($0.0, $0.1) })
                        p.closeSubpath()
                    }
                    ZStack {
                        fill.fill(isSel ? Palette.teal.opacity(0.25) : Color(red: 0.93, green: 0.90, blue: 0.84).opacity(0.8))
                        outline.stroke(isSel ? Palette.teal : Color.primary, lineWidth: isSel ? 4 : 3)
                        VStack(spacing: 0) {
                            Text(room.displayName).font(.caption.weight(.bold)).foregroundStyle(room.needsName ? .orange : .primary)
                            if room.mapX != nil { Image(systemName: "hand.draw").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .position(toScreen(pl.x, pl.z))
                    }
                    .contentShape(fill)
                    .onTapGesture { selected = selected == room.uid ? nil : room.uid }
                    .gesture(DragGesture(minimumDistance: 3)
                        .onChanged { g in
                            let start = dragStart[room.uid] ?? (pl.x, pl.z)
                            dragStart[room.uid] = start
                            selected = room.uid
                            room.mapRotationDeg = pl.rotationDeg
                            room.mapX = start.0 + g.translation.width / scale
                            room.mapZ = start.1 + g.translation.height / scale
                        }
                        .onEnded { _ in
                            dragStart[room.uid] = nil
                            try? context.save()
                            Haptics.tap()
                            organizer.scheduleDriveSync()
                        })
                }
                if let b = place.northBearing {
                    let a = -b * .pi / 180
                    VStack(spacing: 0) {
                        Image(systemName: "location.north.line.fill").rotationEffect(.degrees(-b))
                        Text("N").font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.red)
                    .position(x: geo.size.width - 30 + sin(a) * 4, y: 34)
                }
            }
        }
    }

    private func inspector(_ room: Room) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(room.displayName).font(.display(.headline))
                Spacer()
                Button("Name & tags") { naming = room }.buttonStyle(.bordered)
            }
            if !room.tags.isEmpty { Text(room.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button { turn(room, -15) } label: { Image(systemName: "rotate.left") }
                Button { turn(room, 15) } label: { Image(systemName: "rotate.right") }
                Button { turn(room, 90) } label: { Label("90°", systemImage: "arrow.clockwise") }
                Spacer()
                if room.mapX != nil && room.fromHouseScan && room.layout?.originX != nil {
                    Button("Back to scan position") {
                        room.mapX = nil
                        room.mapZ = nil
                        room.mapRotationDeg = 0
                        try? context.save()
                    }
                } else if !room.fromHouseScan {
                    Button("Take off the map", role: .destructive) {
                        room.mapX = nil
                        room.mapZ = nil
                        selected = nil
                        try? context.save()
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .card()
    }

    private func turn(_ room: Room, _ deg: Double) {
        guard let p = room.placement else { return }
        room.mapX = p.x
        room.mapZ = p.z
        room.mapRotationDeg = GeoMath.normalize(p.rotationDeg + deg)
        try? context.save()
        organizer.scheduleDriveSync()
    }

    private func putOnMap(_ room: Room) {
        let others = place.mappedRooms.map { $0.1.corners(width: $0.0.widthM, depth: $0.0.depthM) }
        let spot = RoomPlacement.nextFree(after: others, width: room.widthM)
        room.mapX = spot.x
        room.mapZ = spot.z
        room.mapRotationDeg = 0
        selected = room.uid
        try? context.save()
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
                            ForEach(baseSuggestions + suggestions, id: \.self) { s in
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
                                if let first = r.names.first, room.needsName && name.hasPrefix("Unnamed") { name = first }
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
                        if !n.isEmpty { room.name = n; room.needsName = false }
                        room.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                        try? context.save()
                        organizer.scheduleDriveSync()
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = room.name
                tagsText = room.tags.joined(separator: ", ")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var baseSuggestions: [String] {
        var out: [String] = []
        let names = ["bedroom": "Bedroom", "bathroom": "Bathroom", "kitchen": "Kitchen", "livingRoom": "Living room", "diningRoom": "Dining room"]
        if let s = room.sectionLabel, let n = names[s] { out.append(n) }
        return out + ["Office", "Kids' room", "Hallway", "Laundry", "Garage", "Guest room"].filter { !out.contains($0) }
    }
}
