import PaperCore
import SwiftUI
import WebKit

extension StudioStore {
    /// Storage path and type of a paper's asset (figure, picture), from assets/{id}.
    func asset(_ pid: String, _ assetID: String) async throws -> (path: String, type: String) {
        let c = try await session.config()
        let token = try await session.token()
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(c.projectId)/databases/\(FirebaseWebConfig.database)/documents/manuscriptProjects/\(pid)/assets/\(assetID)")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw StudioError(message: "Figure \(assetID) not found.")
        }
        let f = FirestoreValue.object(doc["fields"] as? [String: Any] ?? [:])
        guard let path = f["path"] as? String else { throw StudioError(message: "Figure \(assetID) has no file.") }
        return (path, f["type"] as? String ?? "image/png")
    }

    /// The bytes of a stored file (Firebase Storage REST, signed in as the owner).
    func download(path: String) async throws -> Data {
        let c = try await session.config()
        let token = try await session.token()
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        var req = URLRequest(url: URL(string: "https://firebasestorage.googleapis.com/v0/b/\(c.storageBucket)/o/\(encoded)?alt=media")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw StudioError(message: "Couldn't download \(path).") }
        return data
    }
}

/// Serves pqasset://ID to the reader page: from the phone's cache, else downloaded once and cached.
/// WebKit asks only for images near the screen (loading="lazy"), so figures load as you scroll.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    let paperID: String
    private var stopped = Set<ObjectIdentifier>()
    static let cacheDir: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PaperAssets", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init(paperID: String) { self.paperID = paperID }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let id = url.host, !id.isEmpty else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let key = ObjectIdentifier(task)
        let file = Self.cacheDir.appendingPathComponent("\(paperID)-\(id)")
        Task { @MainActor in
            var data = try? Data(contentsOf: file)
            var type = "image/png"
            if data == nil {
                do {
                    let store = StudioStore()
                    let a = try await store.asset(paperID, id)
                    type = a.type
                    let bytes = try await store.download(path: a.path)
                    try? bytes.write(to: file, options: .atomic)
                    data = bytes
                } catch {
                    if !self.stopped.contains(key) { task.didFailWithError(error) }
                    self.stopped.remove(key)
                    return
                }
            }
            guard !self.stopped.contains(key), let data else { self.stopped.remove(key); return }
            task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}

struct SectionPage: UIViewRepresentable {
    let paperID: String
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AssetSchemeHandler(paperID: paperID), forURLScheme: "pqasset")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.loadHTMLString(html, baseURL: nil)
        context.coordinator.loaded = html
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.loaded != html {
            context.coordinator.loaded = html
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded = "" }
}

/// A paper from Manuscript Studio, one section at a time.
struct ReaderView: View {
    let paperID: String
    let title: String
    @Environment(\.colorScheme) private var scheme
    @State private var sections: [ReaderPaper.Section] = []
    @State private var source: String?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading the paper's text…")
            } else if let error {
                ContentUnavailableView("Couldn't open the paper", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let source {
                ScrollView { Text(source).font(.footnote.monospaced()).textSelection(.enabled).padding() }
            } else {
                List(sections) { s in
                    NavigationLink {
                        ReaderSectionView(paperID: paperID, sections: sections, index: s.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.title).font(.headline)
                            Text(detail(s)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func detail(_ s: ReaderPaper.Section) -> String {
        var parts = ["\(ManuscriptHTML.wordCount(s.html)) words"]
        if s.equations > 0 { parts.append("\(s.equations) equations") }
        if s.figures > 0 { parts.append("\(s.figures) figure\(s.figures == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        defer { loading = false }
        do {
            let m = try await StudioStore().manuscript(paperID)
            if m.format == "html" { sections = ReaderPaper.sections(m.text) } else { source = m.text }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ReaderSectionView: View {
    let paperID: String
    let sections: [ReaderPaper.Section]
    @State var index: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SectionPage(paperID: paperID, html: ReaderPaper.page(sections[index], dark: scheme == .dark))
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(sections[index].title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { index -= 1 } label: { Label("Previous", systemImage: "chevron.left") }.disabled(index == 0)
                    Spacer()
                    Text("\(index + 1) of \(sections.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { index += 1 } label: { Label("Next", systemImage: "chevron.right") }.disabled(index >= sections.count - 1)
                }
            }
    }
}
