import SwiftData
import SwiftUI
import TidyCore

/// The kitchen planner: work triangle, the five kitchen zones, food to use soon, and an AI kitchen organiser.
struct KitchenView: View {
    @Bindable var room: Room
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var organizer: Organizer
    @State private var provider = "auto"
    @State private var summary: String?
    @State private var errorText: String?
    @State private var editingZone: Zone?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                triangleCard
                useSoonCard
                zonesCard
                aiCard
            }
            .padding()
        }
        .background(Palette.paper)
        .navigationTitle("Kitchen · \(room.name)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingZone) { ZoneEditor(zone: $0, room: room) }
    }

    private var fixtures: [String: (Double, Double)] {
        var out: [String: (Double, Double)] = [:]
        for p in room.currentDesign(context: context).pieces where ["fridge", "sink", "stove"].contains(p.kind) && out[p.kind] == nil {
            out[p.kind] = (p.x, p.z)
        }
        return out
    }

    private var triangleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Work triangle", systemImage: "triangle").font(.display(.headline))
            let f = fixtures
            if let fr = f["fridge"], let si = f["sink"], let st = f["stove"] {
                let t = Kitchen.triangle(fridge: fr, sink: si, stove: st)
                Text(t.verdict).font(.title3.weight(.semibold)).foregroundStyle(t.isGood ? .green : .orange)
                Text(String(format: "Fridge → sink %.1f m · sink → stove %.1f m · stove → fridge %.1f m · total %.1f m",
                            t.fridgeToSink, t.sinkToStove, t.stoveToFridge, t.total))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("Guideline: each side 1.2–2.7 m, total 4–7.9 m, nothing blocking the paths.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Scan the kitchen with LiDAR (or add the fridge, sink and stove in the design studio) to check how far you walk between them.")
                    .font(.callout).foregroundStyle(.secondary)
                let missing = ["fridge", "sink", "stove"].filter { f[$0] == nil }
                Text("Missing: " + missing.joined(separator: ", ")).font(.caption)
            }
        }
        .card()
    }

    private var useSoonCard: some View {
        let food = room.items.compactMap { i in i.expiresAt.map { (i, $0) } }
        let soon = Kitchen.useSoon(food)
        return VStack(alignment: .leading, spacing: 8) {
            Label("Use soon", systemImage: "clock.badge.exclamationmark").font(.display(.headline))
            if soon.isEmpty {
                Text(food.isEmpty ? "Add use-by dates to food (tap a thing → Use by) and what runs out soon shows here."
                                  : "Nothing runs out in the next 3 days.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(soon.enumerated()), id: \.offset) { _, pair in
                let item = pair.0, date = pair.1
                HStack {
                    ItemThumb(file: item.thumbFile, category: item.category, size: 36)
                    VStack(alignment: .leading) {
                        Text(item.name).font(.body.weight(.semibold))
                        Text(room.zonePath(item.zoneID) ?? "loose").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(date < Date() ? "expired" : date.formatted(.relative(presentation: .named)))
                        .font(.caption.weight(.bold)).foregroundStyle(date < Date() ? .red : .orange)
                }
            }
        }
        .card()
    }

    private var zonesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Kitchen zones", systemImage: "square.grid.3x2").font(.display(.headline))
            Text("Every cabinet and drawer belongs to one zone, following the flow fridge → prep → stove → sink.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Kitchen.ZoneType.allCases, id: \.self) { type in
                let spots = room.zones.filter { $0.kitchenZone == type.rawValue }
                VStack(alignment: .leading, spacing: 4) {
                    Label(type.label, systemImage: type.symbol).font(.body.weight(.semibold))
                    Text(type.hint).font(.caption2).foregroundStyle(.secondary)
                    ForEach(spots) { z in
                        Button { editingZone = z } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(room.zonePath(z.uid) ?? z.name).font(.callout)
                                if !z.notes.isEmpty { Text(z.notes).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 8)
                    }
                    if spots.isEmpty { Text("No spot yet").font(.caption).foregroundStyle(.tertiary).padding(.leading, 8) }
                }
                .padding(8)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
            }
            let unassigned = room.zones.filter { $0.kitchenZone == nil }
            if !unassigned.isEmpty {
                Text("Not in a zone yet: " + unassigned.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.orange)
            }
        }
        .card()
    }

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Organise my kitchen", systemImage: "sparkles").font(.display(.headline))
            Text("The organiser puts every cabinet and drawer in a zone, says what goes where, and adds useful organisers to your shopping list.")
                .font(.caption).foregroundStyle(.secondary)
            AIProviderPicker(selection: $provider)
            Button {
                Task {
                    do { summary = try await organizer.organizeKitchen(room, provider: AIProviderPicker.provider(provider), context: context) }
                    catch { errorText = error.localizedDescription }
                }
            } label: {
                HStack {
                    if organizer.busy { ProgressView() } else { Image(systemName: "wand.and.stars") }
                    Text(organizer.busy ? "Organising…" : "Organise my kitchen")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(organizer.busy || room.zones.isEmpty)
            if room.zones.isEmpty { Text("Add the cabinets and drawers first (Storage spots), or scan the kitchen.").font(.caption) }
            if let summary { Text(summary).font(.callout).padding(10).background(Palette.tint, in: RoundedRectangle(cornerRadius: 12)) }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
        }
        .card()
    }
}

/// Choose who answers for one task: the Settings order, Claude, or ChatGPT.
struct AIProviderPicker: View {
    @Binding var selection: String

    static func provider(_ s: String) -> AIProvider? { AIProvider(rawValue: s) }

    var body: some View {
        Picker("AI", selection: $selection) {
            Text("Auto").tag("auto")
            Text("Claude").tag(AIProvider.claude.rawValue)
            Text("ChatGPT").tag(AIProvider.chatgpt.rawValue)
        }
        .pickerStyle(.segmented)
    }
}

/// Things worth buying, from the designer and the kitchen organiser.
struct ShoppingView: View {
    @Query(sort: \ShoppingItem.createdAt, order: .reverse) private var items: [ShoppingItem]
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add something to buy", text: $newName)
                    Button("Add") {
                        let s = ShoppingItem(name: newName.trimmingCharacters(in: .whitespaces))
                        context.insert(s)
                        try? context.save()
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                let total = items.filter { !$0.bought }.compactMap(\.priceUSD).reduce(0, +)
                if total > 0 { Text(String(format: "About $%.0f for everything still to buy (rough estimates).", total)) }
            }
            ForEach([false, true], id: \.self) { bought in
                let list = items.filter { $0.bought == bought }
                if !list.isEmpty {
                    Section(bought ? "Bought" : "Ideas to buy") {
                        ForEach(list) { s in row(s) }
                            .onDelete { idx in
                                for i in idx { context.delete(list[i]) }
                                try? context.save()
                            }
                    }
                }
            }
            if items.isEmpty {
                Text("Ask the designer for decor, wall pictures or helpful gadgets, or let the kitchen organiser suggest organisers. What's worth buying lands here.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Shopping list")
    }

    private func row(_ s: ShoppingItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                s.bought.toggle()
                try? context.save()
            } label: { Image(systemName: s.bought ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(s.bought ? .green : Palette.teal) }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.body.weight(.semibold)).strikethrough(s.bought)
                if !s.why.isEmpty { Text(s.why).font(.caption).foregroundStyle(.secondary) }
                Text([s.roomName.isEmpty ? nil : s.roomName, s.category.isEmpty ? nil : s.category,
                      s.priceUSD.map { String(format: "≈ $%.0f", $0) }, s.provider.isEmpty ? nil : "from \(s.provider)"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if let url = s.searchURL {
                Button { openURL(url) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
            }
        }
    }
}
