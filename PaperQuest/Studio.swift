import Foundation
import PaperCore
import SwiftUI

// Manuscript Studio (Firebase project of the web app at manuscript-studio-181489801873.web.app/write/).
// The same Google account signs in here; data is read and written with the same rules and the same atomic
// revision/version/event writes as the web app, so the web editor, the bridge and this app stay in step.

struct StudioPaper: Identifiable, Hashable {
    var id: String
    var name: String
    var description: String
    var canEdit: Bool
}

struct StudioManuscript {
    var title: String
    var text: String
    var format: String
    var revision: Int
    var updateTime: String?
}

struct StudioComment: Identifiable {
    var id: String
    var raw: [String: Any]
    var updateTime: String?
    var note: String { raw["note"] as? String ?? "" }
    var quote: String { raw["quote"] as? String ?? "" }
    var status: String { raw["status"] as? String ?? "open" }
    var author: String { raw["author"] as? String ?? "Researcher" }
    var replies: [[String: Any]] { raw["replies"] as? [[String: Any]] ?? [] }

    var forAssistant: PaperComment {
        PaperComment(id: id, author: author, quote: quote, note: note, status: status,
                     replies: replies.map { "\($0["author"] as? String ?? "Someone"): \($0["text"] as? String ?? "")" })
    }
}

struct StudioError: LocalizedError {
    var message: String
    var status: Int?
    var errorDescription: String? { message }
}

/// The Firebase sign-in, kept in the Keychain so it survives updates (service "PaperQuest", like the Google one).
@MainActor
final class StudioSession: ObservableObject {
    static let shared = StudioSession()
    static let refreshKey = "firebase.refresh"
    static let configKey = "firebase.config"
    static let profileKey = "firebase.profile"

    @Published private(set) var uid: String?
    @Published private(set) var email: String?
    @Published private(set) var displayName: String?
    @Published var status: String?
    @Published var busy = false
    @Published var needsSafelist = false

    private var idToken: String?
    private var idExpiry = Date.distantPast
    private var photoURL: String?
    private var googleSub: String?

    var signedIn: Bool { uid != nil && Keychain.get(Self.refreshKey) != nil }

    init() {
        if let d = UserDefaults.standard.dictionary(forKey: Self.profileKey) {
            uid = d["uid"] as? String
            email = d["email"] as? String
            displayName = d["name"] as? String
            photoURL = d["photo"] as? String
            googleSub = d["sub"] as? String
        }
    }

    // MARK: Config

    var cachedConfig: FirebaseWebConfig? {
        UserDefaults.standard.data(forKey: Self.configKey).flatMap { try? JSONDecoder().decode(FirebaseWebConfig.self, from: $0) }
    }

    /// The public web config, read from the live site (so it always matches the deployed web app).
    func config() async throws -> FirebaseWebConfig {
        var req = URLRequest(url: FirebaseWebConfig.configURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
           let c = FirebaseWebConfig.parse(js: String(decoding: data, as: UTF8.self)) {
            if let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: Self.configKey) }
            return c
        }
        if let c = cachedConfig { return c }
        throw StudioError(message: "Couldn't reach Manuscript Studio to read its settings. Check the connection and try again.")
    }

    // MARK: Sign-in

    /// Google sign-in (the same one as Drive) → Firebase sign-in with that Google account.
    func signIn() async {
        busy = true
        status = nil
        needsSafelist = false
        defer { busy = false }
        do {
            if !GoogleAuth.shared.isSignedIn { try await GoogleAuth.shared.signIn() }
            let c = try await config()
            let googleID = try await GoogleAuth.shared.idToken()
            var json: [String: Any]
            do {
                json = try await signInWithIdp(c, postBody: "id_token=\(googleID)&providerId=google.com")
            } catch let e as StudioError where e.message.contains("INVALID_IDP_RESPONSE") || e.message.contains("audience") {
                let access = try await GoogleAuth.shared.currentAccessToken()
                do {
                    json = try await signInWithIdp(c, postBody: "access_token=\(access)&providerId=google.com")
                } catch {
                    needsSafelist = true
                    throw e
                }
            }
            try store(json, refreshField: "refreshToken", idField: "idToken", expiresField: "expiresIn")
            uid = json["localId"] as? String
            email = json["email"] as? String
            displayName = json["displayName"] as? String
            photoURL = json["photoUrl"] as? String
            googleSub = (json["federatedId"] as? String).flatMap { $0.split(separator: "/").last.map(String.init) }
            UserDefaults.standard.set(["uid": uid ?? "", "email": email ?? "", "name": displayName ?? "",
                                       "photo": photoURL ?? "", "sub": googleSub ?? ""], forKey: Self.profileKey)
            status = "Signed in as \(email ?? "your Google account")."
        } catch {
            let text = error.localizedDescription
            if !text.lowercased().contains("cancel") { status = "Manuscript Studio sign-in didn't work: \(text)" }
        }
    }

    func signOut() {
        Keychain.set(nil, for: Self.refreshKey)
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        uid = nil
        email = nil
        displayName = nil
        idToken = nil
        status = nil
    }

    private func signInWithIdp(_ c: FirebaseWebConfig, postBody: String) async throws -> [String: Any] {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(c.apiKey)")!
        return try await postJSON(url, ["postBody": postBody, "requestUri": "http://localhost",
                                        "returnIdpCredential": true, "returnSecureToken": true])
    }

    /// A valid Firebase ID token, refreshed through securetoken when close to expiry.
    func token() async throws -> String {
        if let idToken, idExpiry > Date().addingTimeInterval(120) { return idToken }
        guard let refresh = Keychain.get(Self.refreshKey) else {
            throw StudioError(message: "Sign in to Manuscript Studio first (Settings or the Manuscript tab).")
        }
        let c = try await config()
        var req = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(c.apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=refresh_token&refresh_token=\(refresh)".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown"
            if msg.contains("TOKEN_EXPIRED") || msg.contains("INVALID_REFRESH_TOKEN") || msg.contains("USER_DISABLED") { signOut() }
            throw StudioError(message: "Manuscript Studio sign-in expired (\(msg)). Sign in again.")
        }
        try store(json, refreshField: "refresh_token", idField: "id_token", expiresField: "expires_in")
        guard let idToken else { throw StudioError(message: "No Firebase token.") }
        return idToken
    }

    private func store(_ json: [String: Any], refreshField: String, idField: String, expiresField: String) throws {
        guard let id = json[idField] as? String else { throw StudioError(message: "Firebase didn't return a token.") }
        idToken = id
        let secs = Double(json[expiresField] as? String ?? "") ?? (json[expiresField] as? Double) ?? 3600
        idExpiry = Date().addingTimeInterval(secs)
        if let r = json[refreshField] as? String { Keychain.set(r, for: Self.refreshKey) }
    }

    /// The user record the web app expects in its IndexedDB, so it opens signed in (nil when signed out).
    func webUserRecord() async -> (key: String, json: String, uid: String)? {
        guard let uid, let email, let refresh = Keychain.get(Self.refreshKey),
              let id = try? await token(), let c = cachedConfig else { return nil }
        let rec = FirebaseUserRecord.json(uid: uid, email: email, displayName: displayName?.isEmpty == false ? displayName : nil,
                                          photoURL: photoURL?.isEmpty == false ? photoURL : nil, googleSub: googleSub,
                                          idToken: id, refreshToken: refresh, expiresAt: idExpiry, apiKey: c.apiKey)
        guard let data = try? JSONSerialization.data(withJSONObject: rec) else { return nil }
        return (FirebaseUserRecord.storageKey(apiKey: c.apiKey), String(decoding: data, as: UTF8.self), uid)
    }

    private func postJSON(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            throw StudioError(message: msg, status: (resp as? HTTPURLResponse)?.statusCode)
        }
        return json
    }
}

/// Firestore REST against the named database "manuscript-studio".
@MainActor
struct StudioStore {
    let session = StudioSession.shared

    private func base() async throws -> (String, String) {
        let c = try await session.config()
        let root = "projects/\(c.projectId)/databases/\(FirebaseWebConfig.database)/documents"
        return ("https://firestore.googleapis.com/v1/" + root, root)
    }

    private func call(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        let token = try await session.token()
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        req.timeoutInterval = 60
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(code) else {
            let msg = ((json as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw StudioError(message: code == 403 ? "Manuscript Studio refused access: \(msg)" : "Manuscript Studio error \(code): \(msg)", status: code)
        }
        return json ?? [:]
    }

    /// Papers this account is a member of (as the web app's project picker shows them).
    func papers() async throws -> [StudioPaper] {
        let (url, _) = try await base()
        guard let uid = session.uid else { throw StudioError(message: "Sign in to Manuscript Studio first.") }
        let query: [String: Any] = ["structuredQuery": [
            "from": [["collectionId": "manuscriptProjects"]],
            "where": ["fieldFilter": ["field": ["fieldPath": "memberUids"], "op": "ARRAY_CONTAINS", "value": ["stringValue": uid]]],
        ]]
        let rows = try await call(URL(string: url + ":runQuery")!, method: "POST", body: query) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let doc = row["document"] as? [String: Any], let name = doc["name"] as? String else { return nil }
            let f = FirestoreValue.object(doc["fields"] as? [String: Any] ?? [:])
            let editors = f["editorUids"] as? [Any] ?? []
            let canEdit = (f["ownerUid"] as? String) == uid || editors.contains { ($0 as? String) == uid }
            return StudioPaper(id: String(name.split(separator: "/").last ?? ""), name: f["name"] as? String ?? "Untitled paper",
                               description: f["description"] as? String ?? "", canEdit: canEdit)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func manuscript(_ pid: String) async throws -> StudioManuscript {
        let (url, _) = try await base()
        let doc = try await call(URL(string: "\(url)/manuscriptProjects/\(pid)/manuscripts/main")!) as? [String: Any] ?? [:]
        let f = FirestoreValue.object(doc["fields"] as? [String: Any] ?? [:])
        return StudioManuscript(title: f["title"] as? String ?? "", text: f["text"] as? String ?? "",
                                format: f["format"] as? String ?? "html", revision: f["revision"] as? Int ?? 0,
                                updateTime: doc["updateTime"] as? String)
    }

    func comments(_ pid: String) async throws -> [StudioComment] {
        let (url, _) = try await base()
        var out: [StudioComment] = []
        var page: String?
        repeat {
            var c = URLComponents(string: "\(url)/manuscriptProjects/\(pid)/annotations")!
            c.queryItems = [URLQueryItem(name: "pageSize", value: "300")] + (page.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let json = try await call(c.url!) as? [String: Any] ?? [:]
            for doc in json["documents"] as? [[String: Any]] ?? [] {
                guard let name = doc["name"] as? String else { continue }
                let f = FirestoreValue.object(doc["fields"] as? [String: Any] ?? [:])
                guard (f["type"] as? String ?? "comment") == "comment" else { continue }
                out.append(StudioComment(id: String(name.split(separator: "/").last ?? ""), raw: f, updateTime: doc["updateTime"] as? String))
            }
            page = json["nextPageToken"] as? String
        } while page != nil
        return out
    }

    private static func serverTime(_ fields: [String]) -> [[String: Any]] {
        fields.map { ["fieldPath": $0, "setToServerValue": "REQUEST_TIME"] }
    }

    private func commit(_ writes: [[String: Any]]) async throws {
        let (url, _) = try await base()
        _ = try await call(URL(string: url + ":commit")!, method: "POST", body: ["writes": writes])
    }

    /// Saves new manuscript text exactly as the web app does: manuscripts/main (revision + 1), versions/{mutation}
    /// and events/{mutation} in one atomic commit, guarded by the document's update time.
    @discardableResult
    func save(_ pid: String, base current: StudioManuscript, text: String, label: String, assistant: String) async throws -> Int {
        guard let uid = session.uid else { throw StudioError(message: "Sign in to Manuscript Studio first.") }
        guard text.utf8.count <= 800_000 else { throw StudioError(message: "The paper would exceed Manuscript Studio's size limit.") }
        let (_, root) = try await base()
        let mutation = UUID().uuidString.lowercased()
        let revision = current.revision + 1
        let saved: [String: Any] = ["title": current.title, "text": text, "format": current.format, "revision": revision,
                                    "updatedBy": uid, "actor": "human", "assistant": assistant, "mutationId": mutation]
        var main: [String: Any] = ["update": ["name": "\(root)/manuscriptProjects/\(pid)/manuscripts/main", "fields": FirestoreValue.fields(saved)],
                                   "updateTransforms": Self.serverTime(["updatedAt"])]
        if let t = current.updateTime { main["currentDocument"] = ["updateTime": t] }
        var version = saved
        version["label"] = "\(label) · revision \(revision)"
        version["createdBy"] = uid
        let event: [String: Any] = ["type": "manuscript.saved", "revision": revision, "mutationId": mutation, "actor": "human",
                                    "assistant": assistant, "createdBy": uid]
        try await commit([
            main,
            ["update": ["name": "\(root)/manuscriptProjects/\(pid)/versions/\(mutation)", "fields": FirestoreValue.fields(version)],
             "currentDocument": ["exists": false], "updateTransforms": Self.serverTime(["updatedAt", "createdAt"])],
            ["update": ["name": "\(root)/manuscriptProjects/\(pid)/events/\(mutation)", "fields": FirestoreValue.fields(event)],
             "currentDocument": ["exists": false], "updateTransforms": Self.serverTime(["createdAt"])],
        ])
        return revision
    }

    /// A new paper, written like the web app's "New paper": the project (owner = this account), then the
    /// manuscript at revision 0 with a first version entry. Returns the paper id.
    func createPaper(id: String, name: String, description: String, text: String, format: String, sourceName: String) async throws {
        guard let uid = session.uid else { throw StudioError(message: "Sign in to Manuscript Studio first.") }
        guard text.utf8.count <= 800_000 else {
            throw StudioError(message: "This file is larger than Manuscript Studio's limit for one paper (about 800 KB of text).")
        }
        let (_, root) = try await base()
        let project: [String: Any] = ["id": id, "name": String(name.prefix(250)), "description": String(description.prefix(500)),
                                      "ownerUid": uid, "memberUids": [uid], "editorUids": [uid]]
        try await commit([
            ["update": ["name": "\(root)/manuscriptProjects/\(id)", "fields": FirestoreValue.fields(project)],
             "currentDocument": ["exists": false], "updateTransforms": Self.serverTime(["createdAt"])],
        ])
        let manuscript: [String: Any] = ["title": String(name.prefix(250)), "text": text, "format": format, "revision": 0, "updatedBy": uid]
        var version = manuscript
        version["label"] = "Imported from \(sourceName)"
        version["createdBy"] = uid
        try await commit([
            ["update": ["name": "\(root)/manuscriptProjects/\(id)/manuscripts/main", "fields": FirestoreValue.fields(manuscript)],
             "currentDocument": ["exists": false], "updateTransforms": Self.serverTime(["createdAt", "updatedAt"])],
            ["update": ["name": "\(root)/manuscriptProjects/\(id)/versions/\(UUID().uuidString.lowercased())", "fields": FirestoreValue.fields(version)],
             "currentDocument": ["exists": false], "updateTransforms": Self.serverTime(["createdAt"])],
        ])
    }

    /// A comment as the web app writes it (annotation + comment.created event in one batch).
    func addComment(_ pid: String, id: String, note: String, quote: String, anchored: Bool, author: String) async throws {
        guard let uid = session.uid else { throw StudioError(message: "Sign in to Manuscript Studio first.") }
        let (_, root) = try await base()
        let record: [String: Any] = ["id": id, "type": "comment", "note": note, "quote": quote, "anchorId": anchored ? (id as Any) : (NSNull() as Any),
                                     "attachmentIds": [Any](), "status": "open", "createdBy": uid, "author": author,
                                     "createdAt": ISO8601DateFormatter.firestoreJS.string(from: Date()), "replies": [Any]()]
        let event: [String: Any] = ["type": "comment.created", "annotation": record, "annotationId": id, "actor": "human", "createdBy": uid]
        try await commit([
            ["update": ["name": "\(root)/manuscriptProjects/\(pid)/annotations/\(id)", "fields": FirestoreValue.fields(record)],
             "currentDocument": ["exists": false]],
            ["update": ["name": "\(root)/manuscriptProjects/\(pid)/events/\(UUID().uuidString.lowercased())", "fields": FirestoreValue.fields(event)],
             "currentDocument": ["exists": false], "updateTransforms": Self.serverTime(["createdAt"])],
        ])
    }

    /// Reply to a comment, or resolve/reopen it (only `replies` / `status` change, as the rules require).
    func changeComment(_ pid: String, _ c: StudioComment, reply: String? = nil, status: String? = nil, author: String) async throws {
        guard let uid = session.uid else { throw StudioError(message: "Sign in to Manuscript Studio first.") }
        let (_, root) = try await base()
        var changed: [String: Any] = [:]
        if let reply {
            var list: [Any] = c.replies
            list.append(["id": UUID().uuidString.lowercased(), "text": reply, "createdBy": uid, "author": author,
                         "createdAt": ISO8601DateFormatter.firestoreJS.string(from: Date())])
            changed["replies"] = list
        }
        if let status { changed["status"] = status }
        guard !changed.isEmpty else { return }
        var write: [String: Any] = ["update": ["name": "\(root)/manuscriptProjects/\(pid)/annotations/\(c.id)", "fields": FirestoreValue.fields(changed)],
                                    "updateMask": ["fieldPaths": Array(changed.keys)]]
        if let t = c.updateTime { write["currentDocument"] = ["updateTime": t] }
        var merged = c.raw
        for (k, v) in changed { merged[k] = v }
        let event: [String: Any] = ["type": "comment.updated", "annotation": merged, "annotationId": c.id, "actor": "human", "createdBy": uid]
        try await commit([
            write,
            ["update": ["name": "\(root)/manuscriptProjects/\(pid)/events/\(UUID().uuidString.lowercased())", "fields": FirestoreValue.fields(event)],
             "currentDocument": ["exists": false], "updateTransforms": Self.serverTime(["createdAt"])],
        ])
    }
}

extension ISO8601DateFormatter {
    /// Same shape as JavaScript's Date.toISOString(), which the web app stores in comments.
    static let firestoreJS: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
