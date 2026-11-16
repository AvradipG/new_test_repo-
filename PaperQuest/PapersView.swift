import PaperCore
import SwiftUI

/// Home: the papers themselves. Write (Manuscript Studio editor), read section by section, ask Claude or ChatGPT
/// for edits, add or start papers. Progress checklists are one tap away but not the point.
struct PapersView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var session = StudioSession.shared
    @State private var papers: [StudioPaper] = StudioStore.cachedPapers()
    @State private var loading = false
    @State private var loadError: String?
    @State private var reading: StudioPaper?
    @State private var asking: StudioPaper?
    @State private var showImport = false
    @State private var showNew = false
    @State private var newTitle = ""
    @State private var creating = false

    var body: some View {
        List {
            if let update = store.updateAvailable {
                Section { UpdateBanner(remote: update) }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            if !session.signedIn {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign in to your Manuscript Studio to write, read and edit your papers here.")
                            .font(.subheadline)
                        Button {
                            Task { await session.signIn(); await reload() }
                        } label: {
                            if session.busy { ProgressView().frame(maxWidth: .infinity) }
                            else { Label("Sign in with Google", systemImage: "person.badge.key").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.busy)
                        if let s = session.status { Text(s).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 4)
                    if session.needsSafelist { SafelistHelp().listRowInsets(EdgeInsets()) }
                }
            }
            Section {
                if papers.isEmpty {
                    Text(session.signedIn ? (loading ? "Loading your papers…" : "No papers yet. Start one or add a file below.")
                                          : "Your papers appear here after signing in.")
                        .foregroundStyle(.secondary)
                }
                ForEach(papers) { p in row(p) }
                if let loadError { Label(loadError, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange) }
            } header: {
                HStack {
                    Text("Papers")
                    Spacer()
                    if loading { ProgressView() }
                }
            }
            if session.signedIn {
                Section {
                    Button { newTitle = ""; showNew = true } label: { Label("New paper", systemImage: "square.and.pencil") }
                    Button { showImport = true } label: { Label("Add a paper from a file (.tex, .docx, .html, .md)", systemImage: "doc.badge.plus") }
                }
            }
        }
        .navigationTitle("Papers")
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: session.uid) { _, _ in Task { await reload() } }
        .sheet(item: $reading) { p in
            NavigationStack {
                ReaderView(paperID: p.id, title: p.name)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { reading = nil } } }
            }
        }
        .sheet(item: $asking) { p in AssistantView(store: store, paperID: p.id) }
        .sheet(isPresented: $showImport) {
            ImportSheet { id in
                Task { await reload(); _ = store.openManuscript(id) }
            }
        }
        .alert("New paper", isPresented: $showNew) {
            TextField("Title", text: $newTitle)
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A private paper in your Manuscript Studio, opened in the editor.")
        }
    }

    private func row(_ p: StudioPaper) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.name).font(.headline)
            if !p.description.isEmpty { Text(p.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 8) {
                Button { _ = store.openManuscript(p.id) } label: { Label("Write", systemImage: "pencil") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.signedIn)
                Button { reading = p } label: { Label("Read", systemImage: "book") }
                    .buttonStyle(.bordered)
                Button { asking = p } label: { Label("Ask AI", systemImage: "sparkles") }
                    .buttonStyle(.bordered)
                    .disabled(!session.signedIn)
                if let tracker = store.paper(p.id) {
                    Spacer()
                    let t = Tree(tracker)
                    Text("\(Int((t.fraction(nil) * 100).rounded()))%").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func reload() async {
        guard session.signedIn else { return }
        loading = true
        defer { loading = false }
        do {
            papers = try await StudioStore().papers()
            loadError = nil
        } catch {
            loadError = "Showing the last saved list: \(error.localizedDescription)"
        }
    }

    private func create() async {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !creating else { return }
        creating = true
        defer { creating = false }
        let id = PaperImport.projectID(title: title, suffix: UUID().uuidString)
        do {
            try await StudioStore().createPaper(id: id, name: title, description: "Started on the iPhone",
                                                text: "<h1>\(ManuscriptHTML.escape(title))</h1><p></p>", format: "html",
                                                sourceName: "Paper Quest")
            await reload()
            _ = store.openManuscript(id)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
