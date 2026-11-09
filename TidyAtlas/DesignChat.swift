import SwiftData
import SwiftUI
import TidyCore

extension Organizer {
    /// One message to the AI designer about a room. A proposal in the answer becomes a new design of the room.
    func designChat(_ text: String, room: Room, base: DesignVariant?, includePhoto: Bool, provider: AIProvider? = nil,
                    improving: Bool = false, context: ModelContext) async throws {
        var chat = room.designChat
        chat.append(DesignMessage(fromUser: true, text: text))
        room.designChat = chat
        try? context.save()
        busy = true
        defer { busy = false }

        let baseDesign = base ?? room.currentDesign(context: context)
        let pieces = baseDesign.pieces
        let designs = room.sortedDesigns
        var designRefs: [String: DesignVariant] = [:]
        let designList: [[String: Any]] = designs.enumerated().map { n, d in
            let ref = "d\(n + 1)"
            designRefs[ref] = d
            return ["ref": ref, "name": d.name, "style": d.style, "is_the_real_room": d.isCurrent, "working_on": d.uid == baseDesign.uid,
                    "layout": DesignAI.roomContext(name: room.name, width: room.widthM, depth: room.depthM, height: room.heightM,
                                                   bearing: room.bearing, openings: [], pieces: d.pieces)["pieces"] ?? [Any]()]
        }
        let history = chat.dropLast().suffix(12).map { ["from": $0.fromUser ? "owner" : "designer", "text": $0.text] }
        var payload: [String: Any] = [
            "room": DesignAI.roomContext(name: room.name, width: room.widthM, depth: room.depthM, height: room.heightM,
                                         bearing: room.bearing, openings: room.layout?.openings ?? [], pieces: pieces),
            "designs": designList,
            "conversation_so_far": history,
            "owner_says": text,
        ]
        if improving {
            payload["task"] = "Improve the design being worked on (\(baseDesign.name)): keep what works, fix what the owner says, and return a full proposal."
        }
        if let place = room.place { payload["home"] = ["name": place.name, "address": jsonValue(place.address)] }
        if !room.items.isEmpty {
            let counts = Dictionary(grouping: room.items, by: \.category).mapValues(\.count)
            payload["things_in_room_by_category"] = counts
        }
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"
        var content: [AIContent] = []
        if includePhoto, let c = room.captures.filter({ $0.status == .analyzed }).max(by: { $0.createdAt < $1.createdAt }),
           let photo = try? Data(contentsOf: Storage.captureURL(c.file)) {
            content.append(.jpeg(photo))
        }
        content.append(.text(json))

        let answer = try await AIService.call(DesignAI.Answer.self, system: DesignAI.system, content: content,
                                              schema: DesignAI.schema, effort: .medium, only: provider)
        var reply = answer.reply
        if !answer.ranking.isEmpty {
            reply += "\n\n" + answer.ranking.enumerated().map { n, r in
                "\(n + 1). \(designRefs[r.designRef]?.name ?? r.designRef) (\(String(format: "%.1f", r.score))/10): \(r.why)"
            }.joined(separator: "\n")
            for r in answer.ranking { designRefs[r.designRef]?.scoreOverall = r.score }
        }
        var message = DesignMessage(fromUser: false, text: reply, provider: AIService.lastProvider?.label)
        if let p = answer.proposal {
            let d = DesignVariant(name: Clamp.text(p.title.isEmpty ? "Designer idea" : p.title, 40))
            d.style = Clamp.text(p.style, 60)
            d.rationale = Clamp.text(p.rationale, 600)
            d.tips = p.tips.prefix(6).map { Clamp.text($0, 200) }
            d.scoreOverall = p.scores.overall
            d.scoreFlow = p.scores.flow
            d.scoreCalm = p.scores.calm
            d.pieces = DesignAI.apply(p, to: pieces, width: room.widthM, depth: room.depthM)
            d.provider = AIService.lastProvider?.label
            if improving {
                d.parentID = baseDesign.uid
                d.version = baseDesign.version + 1
                if p.title.isEmpty { d.name = "\(baseDesign.name) v\(d.version)" }
            }
            d.room = room
            context.insert(d)
            message.designID = d.uid
        }
        if let buys = answer.shopping, !buys.isEmpty {
            saveShopping(buys, room: room, context: context)
            message.text += "\n\n🛒 Added \(buys.count) idea\(buys.count == 1 ? "" : "s") to your shopping list."
        }
        chat = room.designChat
        chat.append(message)
        room.designChat = chat
        try? context.save()
        scheduleDriveSync()
    }
}

struct DesignChatView: View {
    let room: Room
    let base: DesignVariant?
    /// Set when the owner tapped "Improve this design".
    var improving: DesignVariant? = nil
    var onOpenDesign: (UUID) -> Void
    @State private var provider = "auto"
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var organizer: Organizer
    @State private var text = ""
    @State private var includePhoto = true
    @State private var errorText: String?

    private let starters = [
        "Make this room calm and easy to keep tidy (ADHD-friendly)",
        "Arrange it with good Feng Shui and chi flow",
        "Arrange it following Vastu Shastra",
        "Where should an L-shaped sofa go?",
        "Give me wall decor ideas",
        "Scandinavian theme on a small budget",
        "Japandi, warm and minimal",
        "Cosy boho with plants",
        "Which of my designs is best, and why?",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if room.designChat.isEmpty {
                                Text("Ask for a theme, a better layout, furniture or wall ideas, Feng Shui or Vastu. Layouts the designer suggests become new designs you can open, drag around, see in 3D and AR, and compare.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(room.designChat) { m in bubble(m).id(m.id) }
                            if organizer.busy {
                                HStack { ProgressView(); Text("Designing…").foregroundStyle(.secondary) }.id("busy")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: room.designChat.count) { _, _ in
                        withAnimation { proxy.scrollTo(room.designChat.last?.id, anchor: .bottom) }
                    }
                }
                Divider()
                VStack(spacing: 8) {
                    if let i = improving {
                        Label("Improving “\(i.name)”\(i.provider.map { " (made by \($0))" } ?? ""): say what to change", systemImage: "arrow.up.forward.circle")
                            .font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    AIProviderPicker(selection: $provider)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(starters, id: \.self) { s in
                                Button(s) { send(s) }.buttonStyle(.bordered).font(.caption).disabled(organizer.busy)
                            }
                        }
                    }
                    HStack {
                        TextField("Ask the designer…", text: $text, axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.roundedBorder)
                        Button { send(text) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                            .disabled(organizer.busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Toggle("Let the designer see my latest photo of the room", isOn: $includePhoto).font(.caption)
                }
                .padding()
            }
            .navigationTitle("Designer · \(AIService.preference.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Clear conversation", role: .destructive) { room.designChat = []; try? context.save() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .alert("Designer", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func bubble(_ m: DesignMessage) -> some View {
        VStack(alignment: m.fromUser ? .trailing : .leading, spacing: 6) {
            Text(m.text)
                .padding(12)
                .background(m.fromUser ? Palette.teal : Palette.card, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(m.fromUser ? Color.white : Color.primary)
            if let id = m.designID, let d = room.designs.first(where: { $0.uid == id }) {
                Button { onOpenDesign(id) } label: {
                    Label("Open \"\(d.name)\" (\(d.pieces.count) pieces\(d.scoreOverall.map { String(format: ", %.1f/10", $0) } ?? ""))",
                          systemImage: "square.on.square.dashed")
                }
                .buttonStyle(.borderedProminent)
                .font(.footnote)
            }
            if let p = m.provider { Text(p).font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: m.fromUser ? .trailing : .leading)
    }

    private func send(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard KeyStore.hasKey else { errorText = ClaudeWire.Failure.noKey.errorDescription; return }
        text = ""
        Task {
            do {
                try await organizer.designChat(t, room: room, base: improving ?? base, includePhoto: includePhoto,
                                               provider: AIProviderPicker.provider(provider), improving: improving != nil, context: context)
            }
            catch { errorText = error.localizedDescription }
        }
    }
}
