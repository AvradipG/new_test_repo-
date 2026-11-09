import PaperCore
import SafariServices
import SwiftUI
import UIKit
import WebKit

/// The live Manuscript Studio web app (every feature: writer, equations, highlights, comments with pictures,
/// replies, history, references, files, PDF ink, templates, tabs and split views, Word/PDF export) inside the app.
@MainActor
final class StudioWeb: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    @Published var loading = false
    @Published var shareURL: URL?
    @Published var lastError: String?
    private(set) var opened = false
    private var destinations: [ObjectIdentifier: URL] = [:]

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
    }

    /// Opens the workspace (optionally on one paper), signed in with the account chosen in Paper Quest.
    func open(paper: String?, record: (key: String, json: String, uid: String)?) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        if let record {
            ucc.addUserScript(WKUserScript(source: Self.seedScript(key: record.key, json: record.json, uid: record.uid),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        opened = true
        webView.load(URLRequest(url: FirebaseWebConfig.manuscriptURL(paper: paper)))
    }

    func reload() { webView.reload() }

    /// Puts the Firebase user into the web app's own IndexedDB (and localStorage) before it starts, then reloads
    /// once so the app picks it up. An existing record for the same account is left alone (the web app refreshes it).
    static func seedScript(key: String, json: String, uid: String) -> String {
        func js(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        return """
        (function(){try{
          var KEY=\(js(key)), REC=\(json), UID=\(js(uid));
          try{var old=localStorage.getItem(KEY);if(!old||JSON.parse(old).uid!==UID)localStorage.setItem(KEY,JSON.stringify(REC));}catch(e){}
          var req=indexedDB.open('firebaseLocalStorageDb',1);
          req.onupgradeneeded=function(){try{req.result.createObjectStore('firebaseLocalStorage',{keyPath:'fbase_key'});}catch(e){}};
          req.onsuccess=function(){var db=req.result;try{
            var tx=db.transaction('firebaseLocalStorage','readwrite'),st=tx.objectStore('firebaseLocalStorage'),g=st.get(KEY);
            g.onsuccess=function(){var cur=g.result&&g.result.value;if(cur&&cur.uid===UID){return;}
              st.put({fbase_key:KEY,value:REC});
              tx.oncomplete=function(){db.close();try{if(!sessionStorage.getItem('pq-seeded')){sessionStorage.setItem('pq-seeded','1');location.reload();}}catch(e){}};};
          }catch(e){}};
        }catch(e){}})();
        """
    }

    /// Removes the web app's stored sign-in (used when signing out in Paper Quest).
    func forgetWebSignIn() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let mine = records.filter { $0.displayName.contains("manuscript-studio") || $0.displayName.contains("web.app") }
        await store.removeData(ofTypes: types, for: mine)
        opened = false
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        guard let url = navigationAction.request.url else { return (.allow, preferences) }
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        let scheme = url.scheme?.lowercased() ?? ""
        if isMain, ["http", "https"].contains(scheme), url.host != FirebaseWebConfig.site.host {
            await UIApplication.shared.open(url)
            return (.cancel, preferences)
        }
        if ["mailto", "tel", "itms-apps"].contains(scheme) {
            await UIApplication.shared.open(url)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; lastError = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        lastError = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    // MARK: Downloads (Word, PDF, source, BibTeX exports and attachments) → share sheet

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(suggestedFilename.isEmpty ? "Manuscript" : suggestedFilename)
        try? FileManager.default.removeItem(at: url)
        destinations[ObjectIdentifier(download)] = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        shareURL = destinations.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        lastError = "Download failed: \(error.localizedDescription)"
    }

    // MARK: Pop-ups and dialogs (the web app uses prompt() for replies and confirm() before restores)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.scheme == "blob" || url.host == FirebaseWebConfig.site.host { webView.load(navigationAction.request) }
            else { UIApplication.shared.open(url) }
        }
        return nil
    }

    private func present(_ alert: UIAlertController) {
        var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in cont.resume() })
            present(a)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cont.resume(returning: false) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in cont.resume(returning: true) })
            present(a)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            a.addTextField { $0.text = defaultText }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cont.resume(returning: nil) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { [weak a] _ in cont.resume(returning: a?.textFields?.first?.text ?? "") })
            present(a)
        }
    }
}

struct StudioWebContainer: UIViewRepresentable {
    let web: StudioWeb
    func makeUIView(context: Context) -> WKWebView { web.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ManuscriptView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var session = StudioSession.shared
    @StateObject private var web = StudioWeb()
    @State private var papers: [StudioPaper] = []
    @State private var current: String = UserDefaults.standard.string(forKey: "studio.paper") ?? Templates.greenChristoffelID
    @State private var showAssistant = false
    @State private var showQuest = false
    @State private var safari: URL?
    @State private var showImport = false

    var body: some View {
        Group {
            if session.signedIn {
                ZStack(alignment: .bottomTrailing) {
                    StudioWebContainer(web: web)
                        .ignoresSafeArea(.container, edges: .bottom)
                    if web.loading {
                        ProgressView().padding(10).background(.regularMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 8)
                    }
                    actions
                }
            } else {
                signIn
            }
        }
        .navigationTitle(papers.first { $0.id == current }?.name ?? "Manuscript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.signedIn {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(papers) { p in
                            Button { openPaper(p.id) } label: {
                                Label(p.name, systemImage: p.id == current ? "checkmark" : "doc.text")
                            }
                        }
                        Divider()
                        Button { web.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        Button { safari = FirebaseWebConfig.manuscriptURL(paper: current) } label: {
                            Label("Open in Safari view", systemImage: "safari")
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImport = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a paper")
                }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportSheet { id in
                Task {
                    if let list = try? await StudioStore().papers() { papers = list }
                    openPaper(id)
                }
            }
        }
        .task { await start() }
        .onChange(of: session.uid) { _, _ in Task { await start(force: true) } }
        .onChange(of: store.manuscriptRequest) { _, req in
            if let req { openPaper(req); store.manuscriptRequest = nil }
        }
        .sheet(isPresented: $showAssistant) { AssistantView(store: store, paperID: current) }
        .sheet(isPresented: $showQuest) { questSheet }
        .sheet(item: $web.shareURL) { url in ShareSheet(url: url) }
        .sheet(item: $safari) { url in SafariView(url: url).ignoresSafeArea() }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { showQuest = true } label: {
                Image(systemName: "checklist").font(.title3.weight(.semibold)).frame(width: 50, height: 50)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Paper Quest tracker")
            Button { showAssistant = true } label: {
                Image(systemName: "sparkles").font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56).background(Palette.accent, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            }
            .accessibilityLabel("Ask Claude or ChatGPT")
        }
        .padding(.trailing, 16)
        .padding(.bottom, 24)
    }

    @ViewBuilder private var questSheet: some View {
        NavigationStack {
            if store.paper(current) != nil {
                PaperView(paperID: current)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showQuest = false } } }
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView("No tracker for this paper yet", systemImage: "checklist",
                                           description: Text("Make a Paper Quest checklist for it: sections, steps, XP and Drive sync."))
                    Button("Track this paper") {
                        let name = papers.first { $0.id == current }?.name ?? "Paper"
                        store.trackStudioPaper(id: current, title: name)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showQuest = false } } }
            }
        }
    }

    private var signIn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Manuscript Studio").font(.display(.title2))
                Text("Your papers from the Firebase Manuscript Studio, with everything it does: the writer, equations, highlights, comments with pictures and replies, version history, references, files, PDF ink, templates, tabs and split views, and Word/PDF export. Plus Claude and ChatGPT editing from this app.")
                    .foregroundStyle(.secondary)
                Button {
                    Task { await session.signIn() }
                } label: {
                    if session.busy { ProgressView().frame(maxWidth: .infinity) }
                    else { Label("Sign in with Google", systemImage: "person.badge.key").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(session.busy)
                if let s = session.status { Text(s).font(.footnote).foregroundStyle(.secondary) }
                if session.needsSafelist { SafelistHelp() }
                Button("Open in Safari view instead") { safari = FirebaseWebConfig.manuscriptURL(paper: current) }
                    .font(.footnote)
            }
            .padding(20)
        }
    }

    private func start(force: Bool = false) async {
        guard session.signedIn else { return }
        if !web.opened || force {
            let record = await session.webUserRecord()
            web.open(paper: current, record: record)
        }
        if let list = try? await StudioStore().papers() { papers = list }
    }

    private func openPaper(_ id: String) {
        current = id
        UserDefaults.standard.set(id, forKey: "studio.paper")
        Task {
            let record = await session.webUserRecord()
            web.open(paper: id, record: record)
        }
    }
}

/// Shown when Firebase refuses the Google token from this app's sign-in client: a one-time setting in Firebase.
struct SafelistHelp: View {
    let clientID = GoogleAuth.shared.clientID ?? ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("One-time step in Firebase", systemImage: "wrench.and.screwdriver").font(.headline)
            Text("Firebase only accepts Google sign-ins from clients it trusts. On a computer: Firebase console › project-ed65bb90-aac3-42cd-b77 › Authentication › Sign-in method › Google › Safelist client IDs from external projects › add this ID, Save, then sign in here again.")
                .font(.footnote)
            Text(clientID).font(.caption.monospaced()).textSelection(.enabled)
            Button(copied ? "Copied" : "Copy the client ID") {
                UIPasteboard.general.string = clientID
                copied = true
            }
            .font(.footnote)
        }
        .card()
    }
}
