// Agent Board for iPhone: a thin shell around the hosted board, so every update of the
// board is there at once. Adds Google sign-in (Google does not allow it inside a web
// view), saving files, and a page for when there is no connection on the first start.
import SwiftUI
import UIKit
import WebKit

let boardHost = "agent-board-181489801873.web.app"
let boardURL = URL(string: "https://\(boardHost)/")!

@main
struct AgentBoardApp: App {
    @Environment(\.scenePhase) private var phase
    private let web = WebController()

    var body: some Scene {
        WindowGroup {
            WebScreen(web: web)
                .ignoresSafeArea()
                .background(Color(red: 0.043, green: 0.059, blue: 0.082).ignoresSafeArea())
        }
        .onChange(of: phase) { _, now in
            if now == .active { web.becameActive() }
        }
    }
}

struct WebScreen: UIViewControllerRepresentable {
    let web: WebController
    func makeUIViewController(context: Context) -> WebController { web }
    func updateUIViewController(_ controller: WebController, context: Context) {}
}

final class WebController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply, WKDownloadDelegate {
    private var view1: WKWebView!
    private var showsOffline = false
    private var downloadFile: URL?
    private let signIn = GoogleSignIn()

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let config = WKWebViewConfiguration()
        config.limitsNavigationsToAppBoundDomains = true // needed for the offline copy (service worker)
        config.applicationNameForUserAgent = "AgentBoardApp"
        let version = versionText.replacingOccurrences(of: "\"", with: "")
        let bridge = """
        window.agentBoardShell = Object.freeze({
          kind: 'ios',
          getVersion: () => "\(version)",
          googleIdToken: () => window.webkit.messageHandlers.agentBoard.postMessage({ op: 'signIn' }),
        });
        """
        config.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "agentBoard")

        view1 = WKWebView(frame: view.bounds, configuration: config)
        view1.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view1.navigationDelegate = self
        view1.uiDelegate = self
        view1.isOpaque = false
        view1.backgroundColor = UIColor(red: 0.043, green: 0.059, blue: 0.082, alpha: 1)
        view1.scrollView.backgroundColor = view1.backgroundColor
        view1.scrollView.contentInsetAdjustmentBehavior = .never
        view1.scrollView.bounces = false
        view1.allowsBackForwardNavigationGestures = false
        view.addSubview(view1)
        load()
    }

    private func load() {
        showsOffline = false
        view1.load(URLRequest(url: boardURL))
    }

    func becameActive() {
        if showsOffline { load() }
    }

    // MARK: calls from the board

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "https", origin.host == boardHost,
              let body = message.body as? [String: Any], body["op"] as? String == "signIn" else {
            replyHandler(nil, "Not allowed")
            return
        }
        signIn.start(from: view.window) { result in
            switch result {
            case .success(let token): replyHandler(token, nil)
            case .failure(let error): replyHandler(nil, error.localizedDescription)
            }
        }
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let main = action.targetFrame?.isMainFrame ?? true
        if !main || url.isFileURL || (url.scheme == "https" && url.host == boardHost) || url.scheme == "blob" || url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "https" || url.scheme == "http" { UIApplication.shared.open(url) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.scheme == "https" || url.scheme == "http" { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        if code == NSURLErrorCancelled || code == 102 { return } // replaced by a newer load, or a download
        showsOffline = true
        webView.loadHTMLString("""
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <body style="margin:0;height:100vh;display:grid;place-items:center;background:#0b0f15;color:#e7eaf0;font:17px -apple-system">
        <div style="text-align:center;padding:28px"><h2>Agent Board cannot be reached</h2>
        <p style="color:#9aa4b2">It needs a connection the first time it opens on this iPhone. Check the connection and open the app again.</p></div>
        """, baseURL: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { load() }

    // MARK: messages of the page

    private func ask(_ text: String, cancel: Bool, done: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        if cancel { alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(false) }) }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done(true) })
        if presentedViewController != nil { done(false); return }
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        ask(message, cancel: false) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        ask(message, cancel: true, done: completionHandler)
    }

    // MARK: saving files (exports, backups)

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        downloadFile = folder.appendingPathComponent((suggestedFilename as NSString).lastPathComponent)
        completionHandler(downloadFile)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloadFile else { return }
        offer(file, tries: 120)
    }

    // Waits for an open message to be answered; the file stays until it has been offered.
    private func offer(_ file: URL, tries: Int) {
        if presentedViewController != nil {
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.offer(file, tries: tries - 1) } }
            return
        }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        present(share, animated: true)
    }
}
