// Google Drive client, adapted from the Crystal Bowl Scanner / Tidy Atlas (Drive.swift), where it is used daily.
// Changes: Keychain service "PaperQuest", Info.plist key PQGoogleClientID, HTTP status on errors (only a 404/410
// makes a new file, Crystal Bowl lesson B03), listing and downloading so other devices' changes come back.
import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

// MARK: Keychain

enum Keychain {
    /// Synchronizable, so the Google sign-in survives updates, a reinstall and a new iPhone (iCloud Keychain).
    /// Never rename the service: the owner would have to sign in again.
    static let service = "PaperQuest"

    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                   kSecAttrService as String: service]
        var del = base
        del[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(del as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrSynchronizable as String] = kCFBooleanTrue
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecAttrService as String: service, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: Google sign-in (OAuth 2.0 with PKCE, iOS client, no secret)

struct DriveError: LocalizedError {
    var message: String
    var status: Int? = nil
    var errorDescription: String? { message }
    var isMissing: Bool { status == 404 || status == 410 }
}

@MainActor
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleAuth()
    static let scopes = "openid email https://www.googleapis.com/auth/drive.file"
    private static let refreshKey = "google.refresh"
    private static let emailKey = "google.email"
    static let clientIDKey = "google.clientID"

    private var accessToken: String?
    private var expiry = Date.distantPast
    /// Google ID token (openid scope), used to sign in to Manuscript Studio's Firebase project.
    private var googleIDToken: String?
    private var session: ASWebAuthenticationSession?

    /// Client ID baked in at build time, or pasted in the app if the build has none.
    var clientID: String? {
        let pasted = UserDefaults.standard.string(forKey: Self.clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pasted, !pasted.isEmpty { return pasted }
        let built = Bundle.main.object(forInfoDictionaryKey: "PQGoogleClientID") as? String ?? ""
        return built.hasSuffix(".apps.googleusercontent.com") ? built : nil
    }

    var isSignedIn: Bool { Keychain.get(Self.refreshKey) != nil }
    var email: String? { UserDefaults.standard.string(forKey: Self.emailKey) ?? Keychain.get(Self.emailKey) }

    private func redirect(_ clientID: String) -> (scheme: String, uri: String) {
        let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        return (scheme, "\(scheme):/oauth2redirect")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    func signIn() async throws {
        guard let clientID else { throw DriveError(message: "No Google client ID set up yet.") }
        let (scheme, redirectURI) = redirect(clientID)
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? DriveError(message: "Sign-in was cancelled.")) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            s.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw DriveError(message: "Google didn't return a sign-in code.")
        }
        let json = try await tokenRequest([
            "code": code, "client_id": clientID, "redirect_uri": redirectURI,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String else { throw DriveError(message: "Google didn't return a refresh token.") }
        Keychain.set(refresh, for: Self.refreshKey)
        store(json)
        if let idToken = json["id_token"] as? String, let mail = Self.email(fromIDToken: idToken) {
            UserDefaults.standard.set(mail, forKey: Self.emailKey)
            Keychain.set(mail, for: Self.emailKey)
        }
    }

    func signOut() {
        Keychain.set(nil, for: Self.refreshKey)
        Keychain.set(nil, for: Self.emailKey)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        accessToken = nil
        googleIDToken = nil
    }

    func token() async throws -> String {
        if let accessToken, expiry > Date().addingTimeInterval(60) { return accessToken }
        guard let clientID, let refresh = Keychain.get(Self.refreshKey) else { throw DriveError(message: "Not signed in to Google Drive.") }
        let json = try await tokenRequest(["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"])
        store(json)
        guard let accessToken else { throw DriveError(message: "Google didn't return an access token.") }
        return accessToken
    }

    func invalidate() { accessToken = nil }

    /// A fresh Google ID token (refreshes when the cached one is close to expiry).
    func idToken() async throws -> String {
        if googleIDToken == nil || expiry <= Date().addingTimeInterval(120) {
            accessToken = nil
            _ = try await token()
        }
        guard let t = googleIDToken else { throw DriveError(message: "Google didn't return an ID token. Sign in again.") }
        return t
    }

    /// Current access token, for Firebase sign-in when Google's ID token isn't accepted.
    func currentAccessToken() async throws -> String { try await token() }

    private func store(_ json: [String: Any]) {
        if let id = json["id_token"] as? String { googleIDToken = id }
        accessToken = json["access_token"] as? String
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3000)
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            if json["error"] as? String == "invalid_grant" { signOut() }
            throw DriveError(message: "Google sign-in failed: \(json["error_description"] ?? json["error"] ?? "unknown error"). Sign in again in Settings.")
        }
        return json
    }

    static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64URL
    }

    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var sha256: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

// MARK: Drive REST client

struct DriveItem: Hashable {
    var id: String
    var name: String
    var isFolder: Bool
}

@MainActor
struct DriveClient {
    static let folderMime = "application/vnd.google-apps.folder"
    let auth = GoogleAuth.shared

    private func send(_ make: (String) -> URLRequest, retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let req = make(try await auth.token())
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DriveError(message: "No answer from Google Drive.") }
        if http.statusCode == 401 && retry {
            auth.invalidate()
            return try await send(make, retry: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DriveError(message: "Google Drive error \(http.statusCode): \(body.prefix(200))", status: http.statusCode)
        }
        return (data, http)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// Everything this app can see directly inside `parent` (with the drive.file scope: what this app created).
    func list(in parent: String) async throws -> [DriveItem] {
        var out: [DriveItem] = []
        var pageToken: String?
        repeat {
            var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var q: [URLQueryItem] = [
                .init(name: "q", value: "'\(Self.escape(parent))' in parents and trashed = false"),
                .init(name: "fields", value: "nextPageToken, files(id, name, mimeType)"),
                .init(name: "pageSize", value: "200"), .init(name: "spaces", value: "drive"),
            ]
            if let pageToken { q.append(.init(name: "pageToken", value: pageToken)) }
            c.queryItems = q
            let url = c.url!
            let (data, _) = try await send { t in
                var r = URLRequest(url: url)
                r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
                return r
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            for f in json["files"] as? [[String: Any]] ?? [] {
                guard let id = f["id"] as? String, let name = f["name"] as? String else { continue }
                out.append(DriveItem(id: id, name: name, isFolder: (f["mimeType"] as? String) == Self.folderMime))
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return out
    }

    /// Finds a folder this app created under `parent`, or creates it.
    func folder(named name: String, in parent: String) async throws -> String {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [
            .init(name: "q", value: "name = '\(Self.escape(name))' and mimeType = '\(Self.folderMime)' and '\(Self.escape(parent))' in parents and trashed = false"),
            .init(name: "fields", value: "files(id)"), .init(name: "spaces", value: "drive"),
        ]
        let url = c.url!
        let (data, _) = try await send { t in
            var r = URLRequest(url: url)
            r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            return r
        }
        if let files = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["files"] as? [[String: Any]],
           let id = files.first?["id"] as? String {
            return id
        }
        return try await createFolder(named: name, in: parent)
    }

    func createFolder(named name: String, in parent: String) async throws -> String {
        let meta = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": Self.folderMime, "parents": [parent]])
        let (created, _) = try await send { t in
            var r = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
            r.httpMethod = "POST"
            r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = meta
            return r
        }
        guard let id = ((try? JSONSerialization.jsonObject(with: created)) as? [String: Any])?["id"] as? String else {
            throw DriveError(message: "Couldn't create the Drive folder \(name).")
        }
        return id
    }

    func download(_ fileID: String) async throws -> Data {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!
        let (data, _) = try await send { t in
            var r = URLRequest(url: url)
            r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            r.cachePolicy = .reloadIgnoringLocalCacheData
            return r
        }
        return data
    }

    /// Writes `data` as a file named `name`: replaces `existingID`'s content when given, else creates the file.
    /// Only a missing file (404/410) leads to a new one; any other error is thrown so nothing is duplicated.
    func put(_ data: Data, name: String, parent: String, existingID: String?) async throws -> String {
        if let existingID {
            do {
                return try await upload(data, name: name, parent: parent, existingID: existingID)
            } catch let e as DriveError where e.isMissing {
                return try await upload(data, name: name, parent: parent, existingID: nil)
            }
        }
        return try await upload(data, name: name, parent: parent, existingID: nil)
    }

    private func upload(_ data: Data, name: String, parent: String, existingID: String?) async throws -> String {
        let boundary = "pq-" + UUID().uuidString
        var meta: [String: Any] = ["name": name]
        if existingID == nil { meta["parents"] = [parent] }
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: meta))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(Self.mimeType(for: (name as NSString).pathExtension))\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let url = existingID.map { URL(string: "https://www.googleapis.com/upload/drive/v3/files/\($0)?uploadType=multipart&fields=id")! }
            ?? URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!
        let payload = body
        let (out, _) = try await send { t in
            var r = URLRequest(url: url)
            r.httpMethod = existingID == nil ? "POST" : "PATCH"
            r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            r.httpBody = payload
            return r
        }
        guard let id = ((try? JSONSerialization.jsonObject(with: out)) as? [String: Any])?["id"] as? String else {
            throw DriveError(message: "Upload of \(name) failed.")
        }
        return id
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "json": return "application/json"
        case "md": return "text/markdown"
        case "txt": return "text/plain"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }
}
