import SwiftData
import SwiftUI
import TidyCore

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var organizer: Organizer
    @Query(sort: \Place.createdAt) private var places: [Place]
    @Query private var steps: [TidyStep]
    @State private var placeDraft: PlaceDraft?
    @State private var roomDraft: RoomDraft?
    @State private var focusRoom: Room?
    @State private var openRoom: Room?
    @State private var houseScanPlace: Place?
    @State private var houseScanNew = false
    @State private var herePlaceID: UUID?

    struct PlaceDraft: Identifiable {
        let id = UUID()
        var place: Place?
        var name = ""
        var kind = PlaceKind.home
    }

    struct RoomDraft: Identifiable {
        let id = UUID()
        var place: Place
        var name = ""
    }

    private var completions: [Date] { steps.compactMap { $0.status == .done ? $0.completedAt : nil } }

    private var nextStep: (TidyStep, Room)? {
        let todo = steps.filter { $0.status == .todo && $0.room != nil }
            .sorted { ($0.createdAt, -$0.sortKey) > ($1.createdAt, -$1.sortKey) }
        guard let newest = todo.first, let room = newest.room, let first = room.todoSteps.first else { return nil }
        return (first, room)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !KeyStore.hasKey {
                    NavigationLink { SettingsView() } label: {
                        Label("Add your Claude or ChatGPT API key so the app can recognise your things", systemImage: "key.fill")
                            .font(.callout.weight(.semibold))
                            .card(Color.orange.opacity(0.18))
                    }
                    .buttonStyle(.plain)
                }
                if let update = organizer.updateAvailable { UpdateBanner(remote: update).card() }
                if case let (step, room)? = nextStep {
                    Button { focusRoom = room } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Your next tiny step · \(room.name)").font(.footnote).opacity(0.85)
                                Text(step.title).font(.display(.title3)).multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Text("\(step.minutes) min").font(.callout.monospacedDigit())
                            Image(systemName: "arrow.right.circle.fill").font(.title)
                        }
                        .foregroundStyle(.white)
                        .card(Palette.teal)
                    }
                    .buttonStyle(.plain)
                }
                if places.isEmpty { onboarding }
                ForEach(orderedPlaces) { place in placeSection(place) }
                if !places.isEmpty {
                    Button { placeDraft = PlaceDraft(kind: .other) } label: {
                        Label("Add another place", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .background(Palette.paper)
        .navigationTitle("Spaces")
        .navigationDestination(for: Room.self) { RoomView(room: $0) }
        .navigationDestination(item: $openRoom) { RoomView(room: $0) }
        .navigationDestination(for: Place.self) { PlaceView(place: $0) }
        .fullScreenCover(item: $houseScanPlace) { HouseScanSheet(place: $0) }
        .fullScreenCover(isPresented: $houseScanNew) { HouseScanSheet(place: nil) }
        .task(id: places.count) {
            herePlaceID = await organizer.placeHere(places)?.uid
        }
        .fullScreenCover(item: $focusRoom) { FocusView(room: $0) }
        .sheet(item: $placeDraft) { draft in PlaceEditor(draft: draft) { save($0) } }
        .alert("New room or segment", isPresented: Binding(get: { roomDraft != nil }, set: { if !$0 { roomDraft = nil } })) {
            TextField("e.g. Bedroom, Desk corner", text: Binding(get: { roomDraft?.name ?? "" }, set: { roomDraft?.name = $0 }))
            Button("Cancel", role: .cancel) { roomDraft = nil }
            Button("Create") { addRoom() }
        } message: {
            Text("Whole rooms work, and so do smaller segments like \"Entry closet\".")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One small thing at a time.").font(.display(.largeTitle))
            HStack(spacing: 10) {
                Label("\(Streak.doneToday(completions: completions)) done today", systemImage: "sparkles")
                Label("\(Streak.days(completions: completions)) day streak", systemImage: "flame.fill")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            HStack {
                DriveChip()
                if let here = places.first(where: { $0.uid == herePlaceID }) {
                    Label("You're at \(here.name)", systemImage: "location.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Palette.tint, in: Capsule())
                }
            }
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let's map your first space").font(.display(.title2))
            Text("Add a place, then rooms (or segments like \"desk corner\"). Snap a few photos or film a slow walkthrough. Claude tags everything and suggests where it lives.")
                .foregroundStyle(.secondary)
            if HouseScanModel.isSupported {
                Button { houseScanNew = true } label: {
                    Label("Scan my whole home (LiDAR + GPS)", systemImage: "viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("One walk through every room. The app maps it, finds the furniture and geotags it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button { addPlace("Home", .home) } label: { Label("Add Home", systemImage: "house.fill") }
                    .buttonStyle(.bordered)
                Button { addPlace("Office", .office) } label: { Label("Add Office", systemImage: "briefcase.fill") }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .card()
    }

    private func placeSection(_ place: Place) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                NavigationLink(value: place) {
                    HStack(spacing: 6) {
                        Label(place.name, systemImage: place.kind.symbol).font(.display(.title2))
                        if place.geo != nil { Image(systemName: "location.fill").font(.caption).foregroundStyle(Palette.teal) }
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    if HouseScanModel.isSupported {
                        Button(place.houseScannedAt == nil ? "Scan the whole place (LiDAR + GPS)" : "Scan the whole place again",
                               systemImage: "viewfinder") { houseScanPlace = place }
                    }
                    NavigationLink(value: place) { Label("Map, 3D and plan", systemImage: "map") }
                    Button("Rename", systemImage: "pencil") { placeDraft = PlaceDraft(place: place, name: place.name, kind: place.kind) }
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(place) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
            ForEach(place.sortedRooms) { room in
                NavigationLink(value: room) { RoomCard(room: room) }
                    .buttonStyle(.plain)
            }
            Button { roomDraft = RoomDraft(place: place) } label: {
                Label("Add room or segment", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
        }
    }

    /// The place you're at comes first.
    private var orderedPlaces: [Place] {
        guard let id = herePlaceID, let i = places.firstIndex(where: { $0.uid == id }) else { return places }
        var p = places
        p.insert(p.remove(at: i), at: 0)
        return p
    }

    private func addPlace(_ name: String, _ kind: PlaceKind) {
        context.insert(Place(name: name, kind: kind))
        try? context.save()
    }

    private func save(_ draft: PlaceDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let p = draft.place {
            p.name = name
            p.kind = draft.kind
        } else {
            context.insert(Place(name: name, kind: draft.kind))
        }
        try? context.save()
    }

    private func addRoom() {
        guard let draft = roomDraft else { return }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        roomDraft = nil
        guard !name.isEmpty else { return }
        let room = Room(name: name)
        room.place = draft.place
        context.insert(room)
        try? context.save()
        openRoom = room
    }

    private func delete(_ place: Place) {
        place.rooms.forEach { Storage.removeFiles(of: $0) }
        context.delete(place)
        try? context.save()
    }
}

struct RoomCard: View {
    let room: Room

    var body: some View {
        let total = room.items.count
        let sorted = total - room.toSort.count
        let outOfPlace = room.toSort.filter(\.outOfPlace).count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(room.name).font(.display(.title3))
                Spacer()
                if outOfPlace > 0 {
                    Text("\(outOfPlace) out of place")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                }
            }
            Text(room.summary.isEmpty ? (total > 0 ? "\(total) things mapped" : "Not scanned yet. Add a photo to start.") : room.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ProgressView(value: total == 0 ? 0 : Double(sorted), total: Double(max(total, 1)))
                .tint(.green)
            HStack {
                Text("\(sorted)/\(total) in their place").monospacedDigit()
                Spacer()
                if !room.todoSteps.isEmpty { Text("\(room.todoSteps.count) steps left").monospacedDigit() }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .card()
    }
}

struct PlaceEditor: View {
    @State var draft: HomeView.PlaceDraft
    var onSave: (HomeView.PlaceDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (home, office, studio…)", text: $draft.name)
                Picker("Kind", selection: $draft.kind) {
                    ForEach(PlaceKind.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
            }
            .navigationTitle(draft.place == nil ? "New place" : "Rename place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
