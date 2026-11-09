import PaperCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Word → HTML with mammoth (the converter the web app itself loads), run in a hidden web view.
@MainActor
final class WordConverter: NSObject, WKNavigationDelegate {
    private let web = WKWebView(frame: .zero)
    private var loaded: CheckedContinuation<Void, Error>?

    func html(from docx: Data) async throws -> (html: String, droppedImages: Int) {
        web.navigationDelegate = self
        let page = "<!doctype html><meta charset=utf-8><script src=\"https://cdn.jsdelivr.net/npm/mammoth@1.10.0/mammoth.browser.min.js\"></script>"
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            web.loadHTMLString(page, baseURL: URL(string: "https://cdn.jsdelivr.net/"))
        }
        let js = """
        for (let i = 0; i < 100 && typeof mammoth === 'undefined'; i++) { await new Promise(r => setTimeout(r, 100)); }
        if (typeof mammoth === 'undefined') { throw new Error('The Word converter could not be loaded. Check the connection.'); }
        const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0));
        const r = await mammoth.convertToHtml({arrayBuffer: bytes.buffer});
        return r.value;
        """
        let value = try await web.callAsyncJavaScript(js, arguments: ["data": docx.base64EncodedString()], contentWorld: .page)
        guard var html = value as? String else { throw StudioError(message: "The Word file couldn't be converted.") }
        // Embedded pictures can't be stored inside the text (Manuscript Studio keeps figures as files).
        let images = ManuscriptHTML.occurrences(of: "<img", in: html).count
        html = html.replacingOccurrences(of: "<img[^>]*>", with: "", options: .regularExpression)
        return (html, images)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }
}

/// Adds a paper (LaTeX, Markdown, HTML, text or Word) to Manuscript Studio as a new paper with its own tab,
/// plus a Paper Quest tracker built from its headings.
struct ImportSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let opened: (String) -> Void

    @State private var picking = false
    @State private var fileName = ""
    @State private var text = ""
    @State private var format = ""
    @State private var title = ""
    @State private var headings: [PaperImport.Heading] = []
    @State private var equations = 0
    @State private var notes: [String] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { picking = true } label: {
                        Label(fileName.isEmpty ? "Choose the paper file" : fileName, systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("From Files or Google Drive: .tex (best: equations come through), .md, .html, .txt or .docx. The original file isn't changed.")
                }
                if !text.isEmpty {
                    Section("Paper") {
                        TextField("Title", text: $title, axis: .vertical)
                        LabeledContent("Stored as", value: format == "latex" ? "LaTeX" : format == "html" ? "Formatted (HTML)" : "Markdown")
                        LabeledContent("Sections found", value: "\(headings.filter { $0.level == 1 }.count)")
                        if equations > 0 { LabeledContent("Numbered equations", value: "\(equations)") }
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))
                    }
                    if !notes.isEmpty {
                        Section {
                            ForEach(notes, id: \.self) { Label($0, systemImage: "info.circle").font(.footnote) }
                        }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Add a paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Add") { Task { await add() } }
                            .disabled(text.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
                if case let .success(url) = result { Task { await load(url) } }
            }
        }
    }

    private func load(_ url: URL) async {
        error = nil
        notes = []
        busy = true
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { data = try? Data(contentsOf: $0) }
        guard let data else { error = "Couldn't read that file."; return }
        fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if ext == "docx" {
            do {
                let (html, images) = try await WordConverter().html(from: data)
                text = html
                format = "html"
                notes.append("Word equations and pictures don't survive conversion. For equations, use the LaTeX file if you have one.")
                if images > 0 { notes.append("\(images) embedded picture\(images == 1 ? "" : "s") left out; add figures afterwards in the editor.") }
            } catch {
                self.error = error.localizedDescription
                return
            }
        } else if let f = PaperImport.format(forExtension: ext) {
            text = String(decoding: data, as: UTF8.self)
            format = f
        } else {
            error = "Choose a .tex, .md, .html, .txt or .docx file."
            return
        }
        switch format {
        case "latex":
            title = PaperImport.title(latex: text) ?? url.deletingPathExtension().lastPathComponent
            headings = PaperImport.headings(latex: text)
            equations = PaperImport.equationCount(latex: text)
            notes.append("Opens in Manuscript Studio's LaTeX view; “Create formatted draft” there turns it into the rich editor with equation blocks.")
        case "html":
            title = PaperImport.title(html: text) ?? url.deletingPathExtension().lastPathComponent
            headings = PaperImport.headings(html: text)
            equations = ManuscriptHTML.occurrences(of: "data-equation", in: text).count
        default:
            title = PaperImport.title(markdown: text) ?? url.deletingPathExtension().lastPathComponent
            headings = PaperImport.headings(markdown: text)
            equations = 0
        }
        if text.utf8.count > 800_000 { error = "Too large for one paper in Manuscript Studio (limit about 800 KB of text)." }
    }

    private func add() async {
        busy = true
        defer { busy = false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = PaperImport.projectID(title: name, suffix: UUID().uuidString)
        do {
            try await StudioStore().createPaper(id: id, name: name, description: "Imported from \(fileName)", text: text,
                                                format: format, sourceName: fileName)
            let tracker = PaperImport.tracker(id: id, title: name, headings: headings, equations: equations,
                                              manuscriptURL: FirebaseWebConfig.manuscriptURL(paper: id).absoluteString)
            store.addTracker(tracker)
            dismiss()
            opened(id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
