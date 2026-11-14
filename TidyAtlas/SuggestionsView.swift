import SwiftData
import SwiftUI
import TidyCore

/// Shows at a glance whether Claude and ChatGPT are set up (and opens Settings).
struct AIStatusChip: View {
    @State private var claude = KeyStore.hasKey(.claude)
    @State private var chatgpt = KeyStore.hasKey(.chatgpt)

    var body: some View {
        NavigationLink { SettingsView() } label: {
            HStack(spacing: 6) {
                if claude || chatgpt {
                    Image(systemName: "sparkles")
                    if claude { Text("Claude ✓") }
                    if chatgpt { Text("ChatGPT ✓") }
                } else {
                    Image(systemName: "key.fill")
                    Text("No AI key yet")
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(claude || chatgpt ? Palette.tint : Color.orange.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
        .onAppear {
            claude = KeyStore.hasKey(.claude)
            chatgpt = KeyStore.hasKey(.chatgpt)
        }
    }
}

/// Suggestions from Claude, ChatGPT and the Drive bridge, with "Review my home".
struct SuggestionsCard: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var organizer: Organizer
    @Query(sort: \AISuggestion.date, order: .reverse) private var all: [AISuggestion]
    @State private var errorText: String?
    @State private var reviewing = false

    private var open: [AISuggestion] { all.filter { $0.status == "new" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Suggestions", systemImage: "lightbulb").font(.display(.headline))
                Spacer()
                NavigationLink { MemoryView() } label: { Label("Memory", systemImage: "brain").font(.footnote) }
            }
            if open.isEmpty {
                Text("Claude or ChatGPT looks at what changed in your home and what it remembers, then suggests small next steps.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(open.prefix(5)) { s in row(s) }
            if open.count > 5 {
                NavigationLink { MemoryView() } label: { Text("\(open.count - 5) more…").font(.footnote) }
            }
            Button {
                reviewing = true
                Task {
                    defer { reviewing = false }
                    do {
                        let n = try await organizer.reviewHome(context: context)
                        errorText = n == 0 ? "Nothing new to suggest right now." : nil
                    } catch { errorText = error.localizedDescription }
                }
            } label: {
                if reviewing { ProgressView() } else { Label("Review my home", systemImage: "sparkles") }
            }
            .buttonStyle(.bordered)
            .disabled(reviewing || !KeyStore.hasKey)
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.secondary) }
        }
        .card()
    }

    private func row(_ s: AISuggestion) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title).font(.body.weight(.semibold))
                if !s.detail.isEmpty { Text(s.detail).font(.callout).foregroundStyle(.secondary) }
                Text([s.roomName, s.source].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button { mark(s, "done") } label: { Image(systemName: "checkmark.circle") }
                .accessibilityLabel("Done")
            Button { mark(s, "dismissed") } label: { Image(systemName: "xmark.circle") }
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not for me")
        }
        .font(.title3)
        .buttonStyle(.plain)
    }

    private func mark(_ s: AISuggestion, _ status: String) {
        s.status = status
        ActivityLog.add(.suggestion, (status == "done" ? "Did: " : "Skipped the suggestion: ") + s.title, in: context)
        try? context.save()
        organizer.scheduleDriveSync()
        Haptics.tap()
    }
}

/// What Claude and ChatGPT remember, the change log, and all suggestions.
struct MemoryView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var organizer: Organizer
    @Query(sort: \AIMemory.date, order: .reverse) private var memories: [AIMemory]
    @Query(sort: \AISuggestion.date, order: .reverse) private var suggestions: [AISuggestion]
    @State private var events: [ActivityEvent] = []
    @State private var newFact = ""
    @AppStorage("ai.autoReview") private var autoReview = true

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Something to remember (keys go on the hook)", text: $newFact)
                    Button("Add") {
                        organizer.remember(newFact, source: "you", context: context)
                        newFact = ""
                        try? context.save()
                        organizer.scheduleDriveSync()
                    }
                    .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(memories.filter(\.active)) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.text)
                        Text("\(m.source) · \(m.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in
                    let list = memories.filter(\.active)
                    for i in idx { list[i].active = false }
                    try? context.save()
                    organizer.scheduleDriveSync()
                }
            } header: {
                Text("Remembered")
            } footer: {
                Text("Claude and ChatGPT read these and the recent changes below before every plan, design, question and voice request. They're also saved to Google Drive (memory.json, activity-log.json) so an AI with Drive access stays up to date.")
            }
            Section {
                Toggle("Weekly AI review", isOn: $autoReview)
            } footer: {
                Text("Once a week, when things changed, the AI looks over your home by itself and adds suggestions.")
            }
            Section("Suggestions") {
                if suggestions.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(suggestions) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).strikethrough(s.status != "new")
                        if !s.detail.isEmpty { Text(s.detail).font(.caption).foregroundStyle(.secondary) }
                        Text([s.roomName, s.source, s.status == "new" ? "" : s.status].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .swipeActions {
                        Button(s.status == "new" ? "Done" : "Reopen") {
                            s.status = s.status == "new" ? "done" : "new"
                            try? context.save()
                        }
                        .tint(.green)
                    }
                }
            }
            Section("What changed") {
                if events.isEmpty { Text("Nothing logged yet.").foregroundStyle(.secondary) }
                ForEach(events) { e in ActivityRow(event: e) }
            }
        }
        .navigationTitle("Memory")
        .task {
            var d = FetchDescriptor<ActivityEvent>(sortBy: [SortDescriptor(\.date, order: .reverse)])
            d.fetchLimit = 200
            events = (try? context.fetch(d)) ?? []
        }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ActivityKind(rawValue: event.kind)?.symbol ?? "circle").foregroundStyle(Palette.teal).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.text).font(.callout)
                Text([event.roomName, event.source == "you" ? "" : event.source, event.date.formatted(date: .abbreviated, time: .shortened)]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Edit the map of a place, on its own tab.
struct MapTab: View {
    @Query(sort: \Place.createdAt) private var places: [Place]
    @AppStorage("map.placeID") private var placeID = ""

    var body: some View {
        Group {
            if let place = places.first(where: { $0.uid.uuidString == placeID }) ?? places.first {
                VStack(spacing: 10) {
                    if places.count > 1 {
                        Picker("Place", selection: Binding(get: { place.uid.uuidString }, set: { placeID = $0 })) {
                            ForEach(places) { Text($0.name).tag($0.uid.uuidString) }
                        }
                        .pickerStyle(.segmented)
                    }
                    PlaceMapEditor(place: place).id(place.uid)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .navigationTitle(place.name)
            } else {
                ContentUnavailableView("No places yet", systemImage: "map",
                                       description: Text("Add a place on the Spaces tab or scan your home with LiDAR, then edit its map here."))
                    .navigationTitle("Map")
            }
        }
        .background(Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Room.self) { RoomView(room: $0) }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { AssistantButton() } }
    }
}
