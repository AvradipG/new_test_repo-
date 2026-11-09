import SwiftData
import SwiftUI
import TidyCore

struct FindView: View {
    @EnvironmentObject private var organizer: Organizer
    @Query(sort: \Item.updatedAt, order: .reverse) private var items: [Item]
    @State private var query = ""
    @State private var question = ""
    @State private var answer: String?
    @State private var answerItems: [Item] = []
    @State private var category: String?

    private var results: [Item] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return items.filter { it in
            if let category, it.category != category { return false }
            guard !words.isEmpty else { return true }
            let hay = ([it.name, it.category, it.notes, it.room?.name ?? "", it.room?.place?.name ?? "",
                        it.room?.zonePath(it.zoneID) ?? ""] + it.tags + (it.room?.tags ?? [])).joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Where did I put my passport?", text: $question)
                        .submitLabel(.search)
                        .onSubmit(ask)
                    Button(action: ask) {
                        if organizer.busy { ProgressView() } else { Image(systemName: "sparkles") }
                    }
                    .disabled(organizer.busy || question.trimmingCharacters(in: .whitespaces).count < 2)
                }
                if let answer {
                    Text(answer).font(.body.weight(.medium))
                    ForEach(answerItems) { ItemRow(item: $0) }
                }
            } header: {
                Label("Ask Claude", systemImage: "bubble.left.and.text.bubble.right")
            }

            Section {
                let cats = Array(Set(items.map(\.category))).sorted()
                if cats.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            catChip(nil, "All")
                            ForEach(cats, id: \.self) { catChip($0, $0) }
                        }
                    }
                }
                if items.isEmpty {
                    Text("Nothing mapped yet. Scan a room and everything you own shows up here.").foregroundStyle(.secondary)
                }
                ForEach(results.prefix(300)) { ItemRow(item: $0) }
            } header: {
                Text(items.isEmpty ? "Everything" : "\(results.count) of \(items.count) things")
            }
        }
        .searchable(text: $query, prompt: "Search by name, tag, room…")
        .navigationTitle("Find")
        .navigationDestination(for: Room.self) { RoomView(room: $0) }
    }

    private func catChip(_ value: String?, _ label: String) -> some View {
        Button { category = value } label: {
            Text(label).font(.footnote.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(category == value ? Palette.teal : Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(category == value ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        Task {
            do {
                let (a, found) = try await organizer.ask(q, items: items)
                answer = a
                answerItems = found
            } catch {
                answer = error.localizedDescription
                answerItems = []
            }
        }
    }
}

struct ItemRow: View {
    let item: Item

    var body: some View {
        Group {
            if let room = item.room {
                NavigationLink(value: room) { content }
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            ItemThumb(file: item.thumbFile, category: item.category, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text((item.quantity > 1 ? "\(item.quantity)× " : "") + item.name).font(.body.weight(.semibold))
                Text([item.room?.place?.name, item.room?.name, item.room?.zonePath(item.zoneID) ?? "loose"]
                    .compactMap { $0 }.joined(separator: " › "))
                    .font(.caption).foregroundStyle(.secondary)
                if let size = item.sizeText { Text(size).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                if !item.isSorted && item.action != .keep {
                    Text(item.action.label + (item.room?.zone(item.suggestedZoneID).map { " → \($0.name)" } ?? ""))
                        .font(.caption2.weight(.bold)).foregroundStyle(.orange)
                }
            }
        }
    }
}
