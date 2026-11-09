import PaperCore
import SwiftUI

/// One line of the conversation.
struct ChatTurn: Identifiable {
    enum Role { case you, ai, note }
    let id = UUID()
    var role: Role
    var text: String
    var provider: AIProvider?
    var proposal: Proposal?
}

/// What the AI proposed, checked against the paper before anything is written.
struct Proposal {
    struct Line: Identifiable {
        let id = UUID()
        var icon: String
        var title: String
        var before: String
        var after: String
    }
    var result: AssistantResult
    var paperID: String
    var lines: [Line]
    var problems: [String]
    var state: State = .pending

    enum State: Equatable { case pending, applying, applied(String), discarded, failed(String) }
}

@MainActor
final class AssistantModel: ObservableObject {
    @Published var papers: [StudioPaper] = []
    @Published var paperID: String
    @Published var turns: [ChatTurn] = []
    @Published var input = ""
    @Published var busy = false
    @Published var provider: AIProvider = AIService.chosen
    let store: Store

    init(store: Store, paperID: String?) {
        self.store = store
        self.paperID = paperID ?? UserDefaults.standard.string(forKey: "assistant.paper") ?? Templates.greenChristoffelID
    }

    var paperName: String { papers.first { $0.id == paperID }?.name ?? store.paper(paperID)?.title ?? paperID }

    func loadPapers() async {
        guard StudioSession.shared.signedIn else { return }
        if let list = try? await StudioStore().papers() {
            papers = list
            if !list.contains(where: { $0.id == paperID }), let first = list.first { paperID = first.id }
        }
    }

    private func transcript() -> String {
        turns.suffix(10).compactMap { t -> String? in
            switch t.role {
            case .you: return "AVRA: \(t.text)"
            case .ai: return "\(t.provider?.label.uppercased() ?? "AI"): \(t.text)"
            case .note: return nil
            }
        }.joined(separator: "\n")
    }

    func send() async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        UserDefaults.standard.set(paperID, forKey: "assistant.paper")
        let history = transcript()
        turns.append(ChatTurn(role: .you, text: question))
        input = ""
        busy = true
        defer { busy = false }
        do {
            let studio = StudioStore()
            async let m = studio.manuscript(paperID)
            async let c = studio.comments(paperID)
            let (manuscript, comments) = try await (m, c)
            let progress = store.paper(paperID).map { MarkdownExport.render($0) }
            let cached = AssistantPrompt.manuscriptBlock(title: manuscript.title.isEmpty ? paperName : manuscript.title,
                                                         revision: manuscript.revision, html: manuscript.text)
            var context = AssistantPrompt.contextBlock(comments: comments.map(\.forAssistant), progress: progress)
            if !history.isEmpty { context += "\nCONVERSATION SO FAR:\n\(history)\n" }
            context += "\nAVRA NOW SAYS:\n\(question)"
            let (result, who) = try await AIService.ask(system: AssistantPrompt.system, cached: cached, context: context, provider: provider)
            var turn = ChatTurn(role: .ai, text: result.reply.isEmpty ? "(No message.)" : result.reply, provider: who)
            if result.hasChanges { turn.proposal = check(result, html: manuscript.text, comments: comments) }
            turns.append(turn)
            if who != provider { turns.append(ChatTurn(role: .note, text: "\(provider.label) wasn't available, so \(who.label) answered.")) }
        } catch {
            turns.append(ChatTurn(role: .note, text: error.localizedDescription))
        }
    }

    /// Dry run: what would change, and what can't be applied as asked.
    private func check(_ r: AssistantResult, html: String, comments: [StudioComment]) -> Proposal {
        var lines: [Proposal.Line] = []
        var problems: [String] = []
        var working = html
        for e in r.edits {
            do {
                working = try ManuscriptHTML.apply(working, edits: [e])
                let before = ManuscriptHTML.plainText(e.find), after = ManuscriptHTML.plainText(e.replace)
                let markupOnly = before == after
                lines.append(.init(icon: "pencil", title: e.why.isEmpty ? "Edit" : e.why,
                                   before: markupOnly ? e.find : before, after: markupOnly ? e.replace : after))
            } catch {
                problems.append("Edit not possible: \(error.localizedDescription)")
            }
        }
        for c in r.comments {
            do {
                working = try ManuscriptHTML.anchorComment(working, quote: c.quote, commentID: "check")
                lines.append(.init(icon: "text.bubble", title: "Comment", before: c.quote, after: c.note))
            } catch {
                lines.append(.init(icon: "text.bubble", title: "Comment (paper note: the quote can't be anchored)", before: c.quote, after: c.note))
            }
        }
        for h in r.highlights {
            do {
                working = try ManuscriptHTML.highlight(working, quote: h.quote)
                lines.append(.init(icon: "highlighter", title: "Highlight", before: h.quote, after: ""))
            } catch {
                problems.append("Highlight not possible: \(error.localizedDescription)")
            }
        }
        let byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for rep in r.replies {
            if let c = byID[rep.commentId] {
                lines.append(.init(icon: "arrowshape.turn.up.left", title: "Reply to \(c.author)", before: c.note, after: rep.text))
            } else { problems.append("Reply skipped: no comment with id \(rep.commentId).") }
        }
        for s in r.commentStatus {
            if let c = byID[s.commentId] {
                lines.append(.init(icon: s.status == "resolved" ? "checkmark.bubble" : "bubble.left",
                                   title: s.status == "resolved" ? "Resolve comment" : "Reopen comment", before: c.note, after: ""))
            } else { problems.append("Status change skipped: no comment with id \(s.commentId).") }
        }
        for t in r.tracker {
            if store.paper(paperID) == nil { problems.append("Tracker change skipped: this paper has no Paper Quest tracker yet."); break }
            let what = [t.op.replacingOccurrences(of: "_", with: " "), t.status, t.title].filter { !$0.isEmpty }.joined(separator: " · ")
            lines.append(.init(icon: "checklist", title: "Tracker: \(what)", before: t.target, after: t.text))
        }
        return Proposal(result: r, paperID: paperID, lines: lines, problems: problems)
    }

    func discard(_ id: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].proposal?.state = .discarded
    }

    /// Applies an approved proposal to the latest copy of the paper, in one revision.
    func apply(_ id: UUID) async {
        guard let i = turns.firstIndex(where: { $0.id == id }), var p = turns[i].proposal, p.state == .pending else { return }
        turns[i].proposal?.state = .applying
        let r = p.result
        let who = turns[i].provider ?? provider
        let name = StudioSession.shared.displayName ?? StudioSession.shared.email ?? "Avra"
        var done: [String] = []
        var skipped: [String] = []
        do {
            let studio = StudioStore()
            let latest = try await studio.manuscript(p.paperID)
            var html = latest.text
            for e in r.edits {
                do { html = try ManuscriptHTML.apply(html, edits: [e]) } catch { skipped.append(error.localizedDescription) }
            }
            var anchored: [(id: String, c: AssistantResult.Comment, ok: Bool)] = []
            for c in r.comments {
                let cid = UUID().uuidString.lowercased()
                if let out = try? ManuscriptHTML.anchorComment(html, quote: c.quote, commentID: cid) {
                    html = out
                    anchored.append((cid, c, true))
                } else {
                    anchored.append((cid, c, false))
                }
            }
            for h in r.highlights {
                do { html = try ManuscriptHTML.highlight(html, quote: h.quote) } catch { skipped.append(error.localizedDescription) }
            }
            if html != latest.text {
                let rev = try await studio.save(p.paperID, base: latest, text: html, label: "\(who.label) edit", assistant: who.rawValue)
                done.append("saved revision \(rev)")
            }
            for a in anchored {
                try await studio.addComment(p.paperID, id: a.id, note: a.c.note, quote: a.ok ? a.c.quote : "", anchored: a.ok,
                                            author: "\(who.label) for \(name)")
            }
            if !anchored.isEmpty { done.append("\(anchored.count) comment\(anchored.count == 1 ? "" : "s")") }
            if !r.replies.isEmpty || !r.commentStatus.isEmpty {
                var current = Dictionary(try await studio.comments(p.paperID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for rep in r.replies {
                    guard let c = current[rep.commentId] else { continue }
                    try await studio.changeComment(p.paperID, c, reply: rep.text, author: "\(who.label) for \(name)")
                    current = Dictionary(try await studio.comments(p.paperID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                }
                for s in r.commentStatus {
                    guard let c = current[s.commentId], c.status != s.status else { continue }
                    try await studio.changeComment(p.paperID, c, status: s.status, author: name)
                }
                done.append("comment replies/status updated")
            }
            if !r.tracker.isEmpty, store.paper(p.paperID) != nil {
                let report = store.applyInbox(p.paperID, InboxFile(from: who.label, ops: r.tracker.map(\.inboxOp)))
                done.append("tracker: " + report.joined(separator: "; "))
            }
            let summary = (done.isEmpty ? ["nothing changed"] : done).joined(separator: ", ")
            p.state = .applied(summary + (skipped.isEmpty ? "" : ". Skipped: " + skipped.joined(separator: " ")))
        } catch {
            p.state = .failed(error.localizedDescription)
        }
        if let j = turns.firstIndex(where: { $0.id == id }) { turns[j].proposal = p }
    }
}

struct AssistantView: View {
    @StateObject private var model: AssistantModel
    @ObservedObject private var session = StudioSession.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool

    init(store: Store, paperID: String?) {
        _model = StateObject(wrappedValue: AssistantModel(store: store, paperID: paperID))
    }

    private let starters = [
        "What should I work on next?",
        "Tighten the abstract without changing any claim.",
        "Check every equation for notation consistency and comment on problems.",
        "Go through the open comments and propose replies.",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if !session.signedIn {
                                Label("Sign in to Manuscript Studio in the Manuscript tab first.", systemImage: "person.crop.circle.badge.exclamationmark")
                                    .card()
                            } else if model.turns.isEmpty {
                                intro
                            }
                            ForEach(model.turns) { turn in
                                TurnView(turn: turn) { await model.apply(turn.id) } discard: { model.discard(turn.id) }
                                    .id(turn.id)
                            }
                            if model.busy {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("\(model.provider.label) is reading the paper…").foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 4)
                                .id("busy")
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: model.turns.count) { _, _ in
                        if let last = model.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                composer
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Ask \(model.provider.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Picker("AI", selection: $model.provider) {
                        ForEach(AIProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
            .task { await model.loadPapers() }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about the paper or ask for changes. Nothing is changed until you approve it.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(starters, id: \.self) { s in
                Button { model.input = s; typing = true } label: {
                    Text(s).font(.callout).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !model.papers.isEmpty {
                Menu {
                    Picker("Paper", selection: $model.paperID) {
                        ForEach(model.papers) { Text($0.name).tag($0.id) }
                    }
                } label: {
                    Label(model.paperName, systemImage: "doc.text").font(.caption.weight(.semibold)).lineLimit(1)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask or say what to change… (mic on the keyboard to speak)", text: $model.input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .padding(10)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(model.busy || model.input.trimmingCharacters(in: .whitespaces).isEmpty || !session.signedIn)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct TurnView: View {
    let turn: ChatTurn
    let apply: () async -> Void
    let discard: () -> Void

    var body: some View {
        switch turn.role {
        case .you:
            Text(turn.text)
                .padding(12)
                .background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .note:
            Label(turn.text, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
        case .ai:
            VStack(alignment: .leading, spacing: 10) {
                Label(turn.provider?.label ?? "AI", systemImage: "sparkles").font(.caption.weight(.bold)).foregroundStyle(Palette.accent)
                Text(.init(turn.text)).textSelection(.enabled)
                if let p = turn.proposal { ProposalCard(proposal: p, apply: apply, discard: discard) }
            }
            .card()
        }
    }
}

struct ProposalCard: View {
    let proposal: Proposal
    let apply: () async -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Proposed changes").font(.subheadline.weight(.bold))
            ForEach(proposal.lines) { line in
                VStack(alignment: .leading, spacing: 3) {
                    Label(line.title, systemImage: line.icon).font(.footnote.weight(.semibold))
                    if !line.before.isEmpty {
                        Text(line.before).font(.caption).foregroundStyle(.secondary).strikethrough(!line.after.isEmpty && line.icon == "pencil")
                            .lineLimit(6)
                    }
                    if !line.after.isEmpty { Text(line.after).font(.caption).lineLimit(8) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            ForEach(proposal.problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            switch proposal.state {
            case .pending:
                HStack {
                    Button { Task { await apply() } } label: { Label("Apply", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent).tint(Palette.done)
                        .disabled(proposal.lines.isEmpty)
                    Button("Discard", role: .destructive, action: discard).buttonStyle(.bordered)
                }
            case .applying:
                ProgressView("Applying…")
            case .applied(let s):
                Label("Applied: \(s)", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Palette.done)
            case .discarded:
                Label("Discarded", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary)
            case .failed(let s):
                Label("Not applied: \(s)", systemImage: "exclamationmark.octagon.fill").font(.footnote).foregroundStyle(.red)
            }
        }
    }
}
