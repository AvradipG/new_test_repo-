import Foundation

// Manuscript Studio (Firebase) data, as plain logic: the public web config, Firestore's JSON value format, the
// signed-in user record the web app keeps, and safe edits to the manuscript's HTML (the TipTap document).

/// The public Firebase identifiers served at /firebase-config.js (not secrets: every visitor's browser loads them).
public struct FirebaseWebConfig: Codable, Equatable, Sendable {
    public var apiKey: String
    public var authDomain: String
    public var projectId: String
    public var storageBucket: String

    public init(apiKey: String, authDomain: String, projectId: String, storageBucket: String) {
        self.apiKey = apiKey
        self.authDomain = authDomain
        self.projectId = projectId
        self.storageBucket = storageBucket
    }

    public static let site = URL(string: "https://manuscript-studio-181489801873.web.app")!
    public static let configURL = URL(string: "https://manuscript-studio-181489801873.web.app/firebase-config.js")!
    public static let database = "manuscript-studio"

    /// Reads `window.GA_FIREBASE_CONFIG = { apiKey: "...", ... }` (quotes of either kind, keys quoted or not).
    public static func parse(js: String) -> FirebaseWebConfig? {
        func value(_ key: String) -> String? {
            let pattern = "[\"']?\(key)[\"']?\\s*:\\s*[\"']([^\"']*)[\"']"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
                  let r = Range(m.range(at: 1), in: js) else { return nil }
            return String(js[r])
        }
        guard let key = value("apiKey"), !key.isEmpty, let project = value("projectId"), !project.isEmpty else { return nil }
        return FirebaseWebConfig(apiKey: key, authDomain: value("authDomain") ?? "", projectId: project,
                                 storageBucket: value("storageBucket") ?? "")
    }

    public static func manuscriptURL(paper: String?) -> URL {
        var c = URLComponents(url: site.appendingPathComponent("write/"), resolvingAgainstBaseURL: false)!
        if let paper, !paper.isEmpty { c.queryItems = [URLQueryItem(name: "paper", value: paper)] }
        return c.url!
    }
}

/// Firestore REST values ({"stringValue": …}, {"integerValue": "3"}, …) to and from plain JSON-like values.
public enum FirestoreValue {
    /// Marker for a server timestamp; encode() leaves it out and the caller adds a field transform.
    public struct ServerTime: Sendable { public init() {} }

    public static func encode(_ value: Any?) -> [String: Any] {
        guard let v = value, !(v is NSNull) else { return ["nullValue": NSNull()] }
        // Exact Swift types first, so an Int is never taken for a Bool (or the reverse).
        if type(of: v) == Bool.self, let b = v as? Bool { return ["booleanValue": b] }
        if type(of: v) == Int.self, let i = v as? Int { return ["integerValue": String(i)] }
        if type(of: v) == Double.self, let d = v as? Double { return ["doubleValue": d] }
        if let s = v as? String { return ["stringValue": s] }
        if let date = v as? Date { return ["timestampValue": ISO8601DateFormatter.firestore.string(from: date)] }
        if let a = v as? [Any] { return ["arrayValue": ["values": a.map { encode($0) }]] }
        if let m = v as? [String: Any] { return ["mapValue": ["fields": fields(m)]] }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return ["booleanValue": n.boolValue] }
            if CFNumberIsFloatType(n) { return ["doubleValue": n.doubleValue] }
            return ["integerValue": n.stringValue]
        }
        return ["stringValue": String(describing: v)]
    }

    public static func fields(_ object: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in object where !(v is ServerTime) { out[k] = encode(v) }
        return out
    }

    public static func decode(_ v: [String: Any]) -> Any? {
        if let s = v["stringValue"] as? String { return s }
        if let i = v["integerValue"] as? String { return Int(i) ?? 0 }
        if let i = v["integerValue"] as? Int { return i }
        if let d = v["doubleValue"] as? Double { return d }
        if let b = v["booleanValue"] as? Bool { return b }
        if let t = v["timestampValue"] as? String { return t }
        if v["nullValue"] != nil { return nil }
        if let a = v["arrayValue"] as? [String: Any] {
            return (a["values"] as? [[String: Any]] ?? []).map { decode($0) ?? NSNull() }
        }
        if let m = v["mapValue"] as? [String: Any] { return object(m["fields"] as? [String: Any] ?? [:]) }
        if let r = v["referenceValue"] as? String { return r }
        return nil
    }

    public static func object(_ fields: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in fields {
            if let inner = v as? [String: Any], let d = decode(inner) { out[k] = d }
        }
        return out
    }
}

extension ISO8601DateFormatter {
    static let firestore: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// The signed-in user as Firebase Auth (JS SDK 12) stores it in IndexedDB `firebaseLocalStorageDb`, so the web app
/// inside Paper Quest opens already signed in with the account the owner chose on the iPhone.
public enum FirebaseUserRecord {
    public static func storageKey(apiKey: String) -> String { "firebase:authUser:\(apiKey):[DEFAULT]" }

    public static func json(uid: String, email: String, displayName: String?, photoURL: String?, googleSub: String?,
                            idToken: String, refreshToken: String, expiresAt: Date, apiKey: String) -> [String: Any] {
        let ms = String(Int(Date().timeIntervalSince1970 * 1000))
        var provider: [String: Any] = ["providerId": "google.com", "uid": googleSub ?? email, "email": email,
                                       "displayName": displayName ?? NSNull(), "photoURL": photoURL ?? NSNull(),
                                       "phoneNumber": NSNull()]
        if displayName == nil { provider["displayName"] = NSNull() }
        return [
            "uid": uid, "email": email, "emailVerified": true, "isAnonymous": false,
            "displayName": displayName ?? NSNull(), "photoURL": photoURL ?? NSNull(), "phoneNumber": NSNull(),
            "tenantId": NSNull(), "providerData": [provider],
            "stsTokenManager": ["refreshToken": refreshToken, "accessToken": idToken,
                                "expirationTime": Int(expiresAt.timeIntervalSince1970 * 1000)],
            "createdAt": ms, "lastLoginAt": ms, "apiKey": apiKey, "appName": "[DEFAULT]",
        ]
    }
}

/// One exact replacement in the manuscript HTML, as the bridge's manuscript_edit tool does it.
public struct TextEdit: Codable, Hashable, Sendable {
    public var find: String
    public var replace: String
    public var why: String

    public init(find: String, replace: String, why: String = "") {
        self.find = find
        self.replace = replace
        self.why = why
    }
}

public enum ManuscriptHTML {
    public enum Failure: LocalizedError, Equatable {
        case notFound(String)
        case notUnique(String, Int)
        case insideTag(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .notFound(let s): return "Not found in the paper: “\(ManuscriptHTML.snippet(s))”"
            case .notUnique(let s, let n): return "Appears \(n) times, so it is ambiguous: “\(ManuscriptHTML.snippet(s))”"
            case .insideTag(let s): return "Spans formatting or sits inside markup: “\(ManuscriptHTML.snippet(s))”"
            case .empty: return "Empty text."
            }
        }
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func snippet(_ s: String) -> String {
        let t = plainText(s)
        return t.count > 80 ? String(t.prefix(77)) + "…" : t
    }

    public static func occurrences(of needle: String, in hay: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = hay.startIndex
        while let r = hay.range(of: needle, range: from..<hay.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    /// Applies exact replacements in order. Each `find` must occur exactly once at the moment it is applied.
    public static func apply(_ html: String, edits: [TextEdit]) throws -> String {
        var out = html
        for e in edits {
            guard !e.find.isEmpty else { throw Failure.empty }
            let hits = occurrences(of: e.find, in: out)
            if hits.isEmpty { throw Failure.notFound(e.find) }
            if hits.count > 1 { throw Failure.notUnique(e.find, hits.count) }
            out.replaceSubrange(hits[0], with: e.replace)
        }
        return out
    }

    /// Wraps the one place where `quote` (visible text) occurs inside a single run of text with open/close markup.
    public static func wrap(_ html: String, quote: String, open: String, close: String) throws -> String {
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw Failure.empty }
        // Try the text as written, then with HTML escaping (the stored form of & < > ").
        for needle in Array(Set([q, escape(q), q.replacingOccurrences(of: "&", with: "&amp;")])).sorted() {
            let hits = occurrences(of: needle, in: html).filter { !isInsideTag(html, at: $0.lowerBound) }
            if hits.count == 1 {
                var out = html
                out.replaceSubrange(hits[0], with: open + needle + close)
                return out
            }
            if hits.count > 1 { throw Failure.notUnique(q, hits.count) }
        }
        if plainText(html).contains(q) { throw Failure.insideTag(q) }
        throw Failure.notFound(q)
    }

    /// True if `index` falls inside an HTML tag (between "<" and ">").
    static func isInsideTag(_ html: String, at index: String.Index) -> Bool {
        let before = html[..<index]
        guard let lt = before.lastIndex(of: "<") else { return false }
        if let gt = before.lastIndex(of: ">") { return lt > gt }
        return true
    }

    public static func highlight(_ html: String, quote: String, color: String = "#fff1a6") throws -> String {
        let c = color.range(of: "^#[0-9a-fA-F]{3,8}$", options: .regularExpression) != nil ? color : "#fff1a6"
        return try wrap(html, quote: quote, open: "<mark data-color=\"\(c)\" style=\"background-color: \(c); color: inherit\">", close: "</mark>")
    }

    public static func anchorComment(_ html: String, quote: String, commentID: String) throws -> String {
        try wrap(html, quote: quote, open: "<span data-comment-id=\"\(escape(commentID))\" class=\"comment-anchor\">", close: "</span>")
    }

    /// Visible text: tags removed, common entities decoded, whitespace collapsed.
    public static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    public static func wordCount(_ html: String) -> Int {
        plainText(html).split(whereSeparator: { $0 == " " }).count
    }
}
