import PaperCore
import PhotosUI
import SwiftUI
import UIKit

extension AIService {
    /// A plain-text chat answer, with pictures; the other service backs up the chosen one like the paper assistant.
    static func chat(context: String, message: String, images: [Data], provider: AIProvider) async throws -> (String, AIProvider) {
        var order = [provider]
        let other: AIProvider = provider == .claude ? .chatgpt : .claude
        if useBackup && KeyStore.hasKey(other) { order.append(other) }
        var last: Error = AIFailure.noKey(provider)
        for (n, p) in order.enumerated() {
            do { return (try await chatOnce(p, context: context, message: message, images: images), p) } catch {
                last = error
                let passing = (error as? AIFailure)?.worthTryingOther ?? (error is URLError)
                if n == order.count - 1 || !passing { break }
            }
        }
        throw last
    }

    private static func chatOnce(_ p: AIProvider, context: String, message: String, images: [Data]) async throws -> String {
        guard let key = KeyStore.key(p), !key.isEmpty else { throw AIFailure.noKey(p) }
        switch p {
        case .claude:
            var req = URLRequest(url: ClaudeWire.endpoint)
            req.httpMethod = "POST"
            for (k, v) in ClaudeWire.headers(apiKey: key) { req.setValue(v, forHTTPHeaderField: k) }
            req.httpBody = try JSONSerialization.data(withJSONObject: ChatWire.claudeBody(context: context, message: message, images: images))
            req.timeoutInterval = 900
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var body = Data()
                for try await b in bytes { body.append(b) }
                throw ClaudeWire.failure(status: status, body: body)
            }
            var stream = ClaudeStream()
            for try await line in bytes.lines { stream.feed(line: line) }
            return try ClaudeWire.finish(stream)
        case .chatgpt:
            let model = await openAIModel(key: key)
            func send(_ effort: String?) async throws -> (Int, Data) {
                var req = URLRequest(url: OpenAIWire.endpoint)
                req.httpMethod = "POST"
                for (k, v) in OpenAIWire.headers(apiKey: key) { req.setValue(v, forHTTPHeaderField: k) }
                req.httpBody = try JSONSerialization.data(withJSONObject: ChatWire.openAIBody(model: model, context: context, message: message,
                                                                                            images: images, effort: effort))
                req.timeoutInterval = 900
                let (data, resp) = try await URLSession.shared.data(for: req)
                return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
            }
            var (status, data) = try await send("high")
            if status == 400, String(decoding: data, as: UTF8.self).lowercased().contains("reasoning") { (status, data) = try await send(nil) }
            return try OpenAIWire.text(status: status, data: data)
        }
    }
}

struct ChatItem: Identifiable {
    let id = UUID()
    var fromUser: Bool
    var text: String
    var images: [Data] = []
    var provider: AIProvider?
    var isNote = false
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var input = ""
    @Published var pending: [Data] = []
    @Published var busy = false
    @Published var provider: AIProvider = AIService.chosen
    @Published var includeDiagnostics = true
    @Published var requestState: String?

    func diagnostics(_ store: Store) -> String {
        var s = AppInfo.problemReport(store, description: "")
        s = s.replacingOccurrences(of: "\n\nWhat happened:\n(not filled in)", with: "")
        if let paper = store.papers.first { s += "\nFirst paper tracker:\n" + String(MarkdownExport.render(paper).prefix(3000)) }
        return s
    }

    func send(_ store: Store) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !pending.isEmpty), !busy else { return }
        let history = items.filter { !$0.isNote }.suffix(16).map { ChatWire.Turn(fromUser: $0.fromUser, text: $0.text + ($0.images.isEmpty ? "" : " [\($0.images.count) picture(s) attached earlier]")) }
        let pics = pending
        items.append(ChatItem(fromUser: true, text: text, images: pics))
        input = ""
        pending = []
        busy = true
        defer { busy = false }
        let context = ChatWire.transcript(Array(history), context: includeDiagnostics ? diagnostics(store) : "")
        do {
            let (answer, who) = try await AIService.chat(context: context, message: text.isEmpty ? "(see the pictures)" : text, images: pics, provider: provider)
            items.append(ChatItem(fromUser: false, text: answer, provider: who))
        } catch {
            items.append(ChatItem(fromUser: false, text: error.localizedDescription, isNote: true))
        }
    }

    /// Saves the conversation, pictures and diagnostics as an app request in Drive › Paper Quest › app-requests.
    func sendToClaudeCode(_ store: Store, summary: String) async {
        requestState = "Saving the request…"
        let turns = items.filter { !$0.isNote }.map { ChatWire.Turn(fromUser: $0.fromUser, text: $0.text) }
        let pictures = items.flatMap(\.images)
        let md = ChatWire.appRequest(summary: summary, conversation: turns, diagnostics: diagnostics(store), pictures: pictures.count)
        do {
            let place = try await store.saveAppRequest(markdown: md, pictures: pictures)
            requestState = "Saved to \(place). Claude Code reads it from Drive when it next works on the app."
        } catch {
            UIPasteboard.general.string = md
            requestState = "Couldn't save to Drive (\(error.localizedDescription)). The request is copied: paste it into Claude Code."
        }
    }
}

struct ChatView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var model = ChatModel()
    @State private var picks: [PhotosPickerItem] = []
    @State private var showRequest = false
    @State private var summary = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.items.isEmpty { intro }
                        ForEach(model.items) { item in bubble(item).id(item.id) }
                        if model.busy {
                            HStack(spacing: 8) { ProgressView(); Text("\(model.provider.label) is thinking…").foregroundStyle(.secondary) }
                        }
                        if let s = model.requestState { Label(s, systemImage: "paperplane").font(.footnote).foregroundStyle(.secondary) }
                    }
                    .padding(16)
                }
                .onChange(of: model.items.count) { _, _ in
                    if let last = model.items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            composer
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Ask")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("AI", selection: $model.provider) {
                    ForEach(AIProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { summary = model.items.last(where: { $0.fromUser })?.text ?? ""; showRequest = true } label: {
                        Label("Send to Claude Code (app request)", systemImage: "hammer")
                    }
                    .disabled(model.items.isEmpty)
                    Toggle("Include app diagnostics", isOn: $model.includeDiagnostics)
                    Button(role: .destructive) { model.items = []; model.requestState = nil } label: { Label("New conversation", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("App request for Claude Code", isPresented: $showRequest) {
            TextField("What should change?", text: $summary)
            Button("Send") { Task { await model.sendToClaudeCode(store, summary: summary) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The conversation, its pictures and the app's diagnostics are saved to Google Drive › Paper Quest › app-requests.")
        }
        .onChange(of: picks) { _, items in Task { await load(items) } }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Talk to \(model.provider.label) about your papers, the science or the app. Attach screenshots when something goes wrong; the app's diagnostics go along automatically.")
                .font(.subheadline).foregroundStyle(.secondary)
            if !KeyStore.hasKey(model.provider) {
                Label("Add your \(model.provider.label) key in Settings first.", systemImage: "key").font(.footnote).foregroundStyle(.orange)
            }
            ForEach(["Why can't I sign in to Manuscript Studio?", "What should I work on today?", "Explain the storage–loss commutator result in two sentences."], id: \.self) { s in
                Button { model.input = s; typing = true } label: {
                    Text(s).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func bubble(_ item: ChatItem) -> some View {
        if item.isNote {
            Label(item.text, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
        } else if item.fromUser {
            VStack(alignment: .trailing, spacing: 6) {
                if !item.images.isEmpty { thumbs(item.images) }
                if !item.text.isEmpty {
                    Text(item.text).padding(12)
                        .background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label(item.provider?.label ?? "AI", systemImage: "sparkles").font(.caption.weight(.bold)).foregroundStyle(Palette.accent)
                Text(.init(item.text)).textSelection(.enabled)
            }
            .card()
        }
    }

    private func thumbs(_ images: [Data]) -> some View {
        HStack {
            ForEach(Array(images.enumerated()), id: \.offset) { _, d in
                if let ui = UIImage(data: d) {
                    Image(uiImage: ui).resizable().scaledToFill().frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !model.pending.isEmpty {
                HStack {
                    thumbs(model.pending)
                    Button { model.pending = []; picks = [] } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary)
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $picks, maxSelectionCount: 6, matching: .images) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 24))
                }
                TextField("Ask anything… (keyboard mic to speak)", text: $model.input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .padding(10)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Button { Task { await model.send(store) } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(model.busy || (model.input.trimmingCharacters(in: .whitespaces).isEmpty && model.pending.isEmpty))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Photos → JPEG, longest side 1600 px (enough to read a screenshot, small enough to send).
    private func load(_ items: [PhotosPickerItem]) async {
        var out: [Data] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { continue }
            let scale = min(1, 1600 / max(img.size.width, img.size.height))
            let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            let resized = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            if let jpeg = resized.jpegData(compressionQuality: 0.8) { out.append(jpeg) }
        }
        model.pending = out
    }
}
