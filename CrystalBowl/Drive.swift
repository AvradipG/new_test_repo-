import Foundation
import AuthenticationServices
import CryptoKit
import Network
import Security
import UIKit

// MARK: Keychain

enum Keychain {
    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                   kSecAttrService as String: "CrystalBowl"]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecAttrService as String: "CrystalBowl", kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: Google sign-in (OAuth 2.0 with PKCE, iOS client, no secret)

struct DriveError: LocalizedError {
    var message: String
    /// HTTP status when Google answered (3.6), so "file gone" can be told from "try again later".
    var status: Int? = nil
    var errorDescription: String? { message }
    /// The file to update no longer exists on Drive: only then is a new one created instead.
    var fileGone: Bool { status == 404 || status == 410 }
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
    private var session: ASWebAuthenticationSession?

    /// Client ID baked in at build time, or pasted in the app if the build has none.
    var clientID: String? {
        let pasted = UserDefaults.standard.string(forKey: Self.clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pasted, !pasted.isEmpty { return pasted }
        let built = Bundle.main.object(forInfoDictionaryKey: "CBGoogleClientID") as? String ?? ""
        return built.hasSuffix(".apps.googleusercontent.com") ? built : nil
    }

    var isSignedIn: Bool { Keychain.get(Self.refreshKey) != nil }
    var email: String? { UserDefaults.standard.string(forKey: Self.emailKey) }

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
        }
    }

    func signOut() {
        Keychain.set(nil, for: Self.refreshKey)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        accessToken = nil
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

    private func store(_ json: [String: Any]) {
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
}

// MARK: Drive REST client

@MainActor
struct DriveClient {
    static let folderMime = "application/vnd.google-apps.folder"
    let auth = GoogleAuth.shared

    private func send(_ make: (String) -> URLRequest, retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let req = make(try await auth.token())
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
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

    /// Finds a folder this app created under `parent`, or creates it.
    func folder(named name: String, in parent: String) async throws -> String {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [
            .init(name: "q", value: "name = '\(escaped)' and mimeType = '\(Self.folderMime)' and '\(parent)' in parents and trashed = false"),
            .init(name: "fields", value: "files(id)"), .init(name: "spaces", value: "drive"),
        ]
        let (data, _) = try await send { t in
            var r = URLRequest(url: c.url!)
            r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            return r
        }
        if let files = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["files"] as? [[String: Any]],
           let id = files.first?["id"] as? String {
            return id
        }
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

    /// Moves a file this app made to the Drive bin, where it can still be restored for 30 days (3.8).
    func trash(_ id: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["trashed": true])
        _ = try await send { t in
            var r = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!)
            r.httpMethod = "PATCH"
            r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
            return r
        }
    }

    /// Uploads a file with a resumable session. Replaces the content of `existingID` when given.
    func upload(_ file: URL, name: String, parent: String, existingID: String?) async throws -> String {
        let sessionURL = try await startUpload(file, name: name, parent: parent, existingID: existingID)
        var put = URLRequest(url: sessionURL)
        put.httpMethod = "PUT"
        put.setValue(Self.mimeType(for: file.pathExtension), forHTTPHeaderField: "Content-Type")
        put.timeoutInterval = 600
        let (data, resp) = try await URLSession.shared.upload(for: put, fromFile: file)
        let code = (resp as? HTTPURLResponse)?.statusCode
        guard let code, (200..<300).contains(code),
              let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String else {
            throw DriveError(message: "Upload of \(name) failed (HTTP \(code.map(String.init) ?? "none")).", status: code)
        }
        return id
    }

    /// Opens a Google resumable upload session for one file and returns its URL. The URL itself authorises
    /// the upload for a week, so the bytes can be sent later by iOS in the background without a token.
    func startUpload(_ file: URL, name: String, parent: String, existingID: String?) async throws -> URL {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let mime = Self.mimeType(for: file.pathExtension)
        var meta: [String: Any] = ["name": name]
        if existingID == nil { meta["parents"] = [parent] }
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        let start: URL = existingID.map { URL(string: "https://www.googleapis.com/upload/drive/v3/files/\($0)?uploadType=resumable&fields=id")! }
            ?? URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!
        let (_, http) = try await send { t in
            var r = URLRequest(url: start)
            r.httpMethod = existingID == nil ? "POST" : "PATCH"
            r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
            r.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            r.httpBody = metaData
            return r
        }
        guard let location = http.value(forHTTPHeaderField: "Location"), let sessionURL = URL(string: location) else {
            throw DriveError(message: "Google Drive didn't start the upload of \(name).")
        }
        return sessionURL
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "txt", "md": return "text/plain"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "jpg", "jpeg": return "image/jpeg"
        case "usdz": return "model/vnd.usdz+zip"
        case "obj": return "model/obj"
        case "stl": return "model/stl"
        default: return "application/octet-stream"
        }
    }
}

// MARK: Sync state and manifest

/// What has been uploaded for one scan. Stored in scan.json so uploads resume after a restart.
struct DriveSync: Codable, Hashable {
    var folderID: String?
    var files: [String: DriveFileRecord] = [:]
    var lastSync: Date?
    var complete = false
    /// Whether this upload includes the photos (decided once per upload, on Wi-Fi).
    var photos: Bool?
}

struct DriveFileRecord: Codable, Hashable {
    var id: String
    var size: Int64
    var modified: Date
}

enum NetworkState {
    /// True on Wi-Fi or Ethernet; false on cellular or a personal hotspot.
    static func isUnmetered() async -> Bool {
        await withCheckedContinuation { cont in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                cont.resume(returning: path.status == .satisfied && !path.isExpensive && !path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "net"))
        }
    }
}

enum ScanPackage {
    static let rootFolder = "Crystal Bowl Scans"

    static func f8601(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// Web link to a scan's Drive folder.
    static func folderLink(_ id: String) -> URL? { URL(string: "https://drive.google.com/drive/folders/\(id)") }

    /// Files that belong in the Drive copy, as (relative path, local URL), manifest excluded.
    static func files(for scan: Scan, includePhotos: Bool) -> [(String, URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = []
        func walk(_ dir: URL, prefix: String) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let rel = prefix.isEmpty ? url.lastPathComponent : "\(prefix)/\(url.lastPathComponent)"
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if !url.lastPathComponent.hasPrefix(".") { walk(url, prefix: rel) } // skips staging folders
                } else if !url.lastPathComponent.hasPrefix(".") && url.pathExtension != "zip" {
                    out.append((rel, url))
                }
            }
        }
        if scan.hasModel { out.append(("model/\(scan.modelURL.lastPathComponent)", scan.modelURL)) }
        if scan.hasModel2 { out.append(("model/\(scan.model2URL.lastPathComponent)", scan.model2URL)) }
        walk(scan.exportsURL, prefix: "model")
        walk(scan.sectionsURL, prefix: "sections")
        walk(scan.folderURL.appendingPathComponent("Logs", isDirectory: true), prefix: "logs")
        if includePhotos {
            walk(scan.imagesURL, prefix: "images")
            walk(scan.images2URL, prefix: "images_side2")
            walk(scan.detailURL, prefix: "detail")
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.0).inserted }
    }

    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        do {
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch {
            return nil // a read error must not pass for the hash of the part that was read
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func role(_ rel: String) -> String {
        if rel.hasPrefix("images/") || rel.hasPrefix("images_side2/") { return "original_photo" }
        if rel.hasPrefix("model/pieces/") {
            if rel.hasSuffix("_pieces.json") { return "pieces_report" }
            if rel.hasSuffix(".csv") { return "pieces_table" }
            if rel.hasSuffix("_assembled.obj") { return "pieces_assembled_model" }
            if rel.hasSuffix("_missing.obj") { return "pieces_missing_model" }
            return "pieces_image"
        }
        if rel.hasPrefix("model/sheet/") {
            if rel.contains("scientific") { return "sample_sheet_scientific" }
            if rel.contains("clean") { return "sample_sheet_clean" }
            if rel.contains("_figure-") { return "sheet_figure_with_ruler" }
            if rel.contains("unrolled") { return "unrolled_side_image" }
            if rel.hasSuffix(".json") { return "sample_sheet_description" }
            return "virtual_view"
        }
        if rel.hasPrefix("model/ct-frame/") { return rel.hasSuffix(".json") ? "ct_frame_description" : "ct_frame_model_mm" }
        if rel.hasSuffix("_lab-tools.json") { return "lab_tools" }
        if rel.hasPrefix("logs/") { return "build_log" }
        if rel == "detail/detail.json" { return "detail_photo_index" }
        if rel.hasPrefix("detail/") { return "detail_photo" }
        if rel.hasSuffix("dimensions.json") { return "dimensions" }
        if rel.hasPrefix("sections/") {
            if rel.hasSuffix("-geometry.json") { return "section_geometry" }
            if rel.hasSuffix(".csv") { return "section_table" }
            if rel.contains("contact-sheet") { return "section_contact_sheet" }
            if rel.hasSuffix("_all-slices.png") { return "section_all_in_one" }
            return "section_image"
        }
        switch (rel as NSString).pathExtension.lowercased() {
        case "usdz": return "surface_model_textured"
        case "obj", "mtl": return "surface_model_obj"
        case "ply": return "surface_model_ply"
        case "stl": return "surface_model_stl_print"
        case "txt": return "quality_report"
        default: return "other"
        }
    }

    /// Machine-readable description of the scan for the DRA software and AI agents.
    static func manifest(for scan: Scan, files: [(String, URL)], hashes: [String: String], photosUploaded: Bool) -> Data {
        let f = ISO8601DateFormatter()
        var fileList: [[String: Any]] = []
        for (rel, url) in files {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            fileList.append(["path": rel, "role": role(rel), "bytes": size, "sha256": hashes[rel] ?? NSNull()])
        }
        var measurements: Any = NSNull()
        if let s = scan.stats {
            measurements = [
                "principal_axes_mm": ["a": s.axisA, "b": s.axisB, "c": s.axisC],
                "volume_cm3": s.volumeCM3, "mesh_closed": s.isClosed,
                "triangles": s.triangleCount, "vertices": s.vertexCount,
                "volume_note": s.isClosed ? "closed mesh" : "mesh has gaps; volume approximate",
                "median_edge_mm": s.medianEdgeMM ?? NSNull(),
            ] as [String: Any]
            if scan.caliper != nil {
                let f = scan.scaleFactor
                measurements = [
                    "principal_axes_mm": ["a": s.axisA, "b": s.axisB, "c": s.axisC],
                    "principal_axes_mm_caliper_corrected": ["a": s.axisA * f, "b": s.axisB * f, "c": s.axisC * f],
                    "volume_cm3": s.volumeCM3, "volume_cm3_caliper_corrected": s.volumeCM3 * f * f * f,
                    "mesh_closed": s.isClosed, "triangles": s.triangleCount, "vertices": s.vertexCount,
                    "volume_note": s.isClosed ? "closed mesh" : "mesh has gaps; volume approximate",
                    "median_edge_mm": s.medianEdgeMM ?? NSNull(),
                ] as [String: Any]
            }
        }
        var scale: [String: Any] = ["source": "iPhone LiDAR / ARKit tracking", "independently_validated": false]
        if let c = scan.caliper {
            let f = scan.scaleFactor
            scale["independently_validated"] = true
            scale["caliper_check"] = [
                "axis": c.axisName, "measured_mm": c.measuredMM,
                "model_mm": c.measuredMM / f, "factor": f, "date_utc": f8601(c.date),
                "apply": "multiply mesh coordinates by factor for caliper-corrected geometry",
            ] as [String: Any]
        }
        var coverage: Any = NSNull()
        if let cov = scan.coverage, cov.count == 3 {
            coverage = ["low": cov[0], "middle": cov[1], "high": cov[2],
                        "note": "share of 15° sectors with photos on the last side scanned, by camera height"] as [String: Any]
        }
        let sections: [[String: Any]] = (scan.sections ?? []).map { s in
            ["axis": s.axisName, "spacing_mm": s.spacingMM, "count": s.rows.count,
             "folder": "sections/\(s.folderName)", "table": "sections/\(s.folderName)/\(s.folderName).csv",
             "depth_origin": "minimum projection of entire model along PCA axis; not confirmed mounted bottom",
             "geometry": "sections/\(s.folderName)/\(s.folderName)-geometry.json",
             "geometry_note": "Present for stacks re-cut in 1.6 or newer; original model scale",
             "unavailable_measurement_count": s.rows.filter { !$0.measurementsUsable }.count]
        }
        let dict: [String: Any] = [
            "schema": "crystal-bowl.scan/0.1",
            "status": "complete",
            "scan_id": scan.id,
            "specimen_alias": scan.name,
            "created_utc": f.string(from: scan.created),
            "uploaded_utc": f.string(from: Date()),
            "app": ["name": "Crystal Bowl Scanner (iPhone)", "version": AppInfo.version, "build": AppInfo.build, "commit": AppInfo.commit],
            "device": ["model": AppInfo.deviceModel(), "os": "iOS \(UIDevice.current.systemVersion)"],
            "capture": [
                "method": "Apple Object Capture, guided, LiDAR-assisted",
                "passes": scan.passes ?? 1,
                "placements_note": "passes after the first follow a flip of the specimen; Object Capture aligns them internally",
                "photo_count": scan.photoCount ?? NSNull(),
                "original_photos_in_package": photosUploaded,
                "guidance": "hand-held, motion-sensor coverage map with haptic cues",
                "coverage_last_side": coverage,
            ] as [String: Any],
            "reconstruction": [
                "engine": "RealityKit PhotogrammetrySession (on device)",
                "detail": "reduced (the only level iOS builds on the phone; rebuild from images/ on a Mac for full detail)",
                "sample_ordering": "sequential",
                "units": "m", "up_axis": "+Y",
                "coordinate_frame": "Object Capture model frame",
            ],
            "scale": scale,
            "measurements": measurements,
            "dimensions_file": "model/\(scan.fileStem)-dimensions.json",
            "size_method": scan.stats?.box != nil
                ? "a x b x c = sides of the smallest box around the main body (loose pieces under 5 % of the surface dropped)"
                : "a x b x c = extents along principal axes (measured before 1.8; tap Repair to update)",
            "kind": scan.isPieces ? "pieces" : "sample",
            "pieces": scan.piecesResult.map { $0.json(scan: scan) as Any } ?? NSNull(),
            "shape": scan.shape.map { $0.json(scale: scan.scaleFactor) as Any } ?? NSNull(),
            "reference_mark": scan.mark.map { $0.json() as Any } ?? NSNull(),
            "sample_sheet": "model/sheet/: clean and scientific sheets (views counted from the reference mark), single views, the unrolled 360° side and sample-sheet.json",
            "box_mm": scan.stats?.box.map { b -> Any in
                ["length": b.lengthMM, "width": b.widthMM, "thickness": b.thicknessMM,
                 "max_feret": b.maxFeretMM, "min_feret": b.minFeretMM]
            } ?? NSNull(),
            "micro_ct": scan.stats?.upright.map { u -> Any in
                ["height_mm": u.heightMM * scan.scaleFactor,
                 "cylinder_diameter_mm": (u.cylinderDiameterMM ?? u.maxDiameterMM) * scan.scaleFactor,
                 "note": "smallest vertical cylinder holding the rock as it stood when scanned; caliper-corrected when a check exists"]
            } ?? NSNull(),
            "detail_photos": scan.detailCount,
            "blurry_photos_set_aside": scan.blurrySetAside ?? 0,
            "quick_scan": scan.quick ?? false,
            "upright_as_scanned_mm": scan.stats?.upright.map { u -> Any in
                ["height": u.heightMM, "length": u.lengthMM, "width": u.widthMM, "max_diameter": u.maxDiameterMM, "min_width": u.minWidthMM]
            } ?? NSNull(),
            "sections": sections,
            "files": fileList,
            "limitations": [
                "Exterior surface only; not CT. Cross-sections show the outer outline.",
                scan.caliper == nil ? "Scale not validated against a reference; check one axis with calipers." : "Scale checked on one axis with calipers; see scale.caliper_check.",
                "STL carries no units; it is in metres like the other mesh files.",
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static let readme = """
    Crystal Bowl Scans
    ==================
    Written by the Crystal Bowl Scanner iPhone app. One folder per scan, named <scan id>_<sample>.

    Each scan folder:
      manifest.json      what the scan is, measurements, every file with its role and SHA-256.
                         Uploaded last: if it is missing, the upload is still in progress or was interrupted.
      model/             textured USDZ, OBJ, PLY, STL (metres, +Y up), a text report and
                         <sample>-dimensions.json (all overall sizes in mm in one small file).
      sections/          cross-section PNG stacks with a CSV per stack: depth or height, max diameter,
                         min width, extents, and area/perimeter where the outline is closed (mm).
                         h-axis stacks are horizontal slices up the model as it stood (height profile).
                         Each stack folder also carries dimensions.json, a contact sheet and
                         <stack>_all-slices.png: every slice at full drawing with its rulers in one PNG.
      images/            original capture photos, only when photo upload is switched on.
      detail/            close-up photos for surface patterns (all lenses, sharp ones only) with
                         detail.json (lens, zoom, direction round the rock, sharpness). Wi-Fi only.

    index.json in this folder lists every scan, newest first (schema crystal-bowl.index/1): scan_id,
    name, sample_key, scanned_utc and scanned_local, folder and folder_id, status (complete once
    manifest.json is on Drive), sizes in mm (size_mm a >= b >= c, feret_mm, micro_ct height and
    cylinder diameter), volume_cm3 and scale (LiDAR or caliper-corrected). Software should read
    index.json first, then the manifest.json of each scan it needs.

    model/sheet/ (single samples): the clean and the scientific sample sheet, views at 0, +90, 180 and -90
    degrees from the reference mark (the red/black line facing the X-ray source; + = sample turned
    counter-clockwise seen from above), top and bottom views, the unrolled 360-degree side image and
    sample-sheet.json (angles and pixels per mm of every image). manifest.json "reference_mark" gives
    the mark's protractor angle, how it was found and how sure.

    Piece sets (kind "pieces" in index.json and manifest.json): broken pieces scanned together, side 1
    and side 2 (every piece turned over). model/pieces/ holds <sample>_pieces.json (every piece: size,
    volume, where it lay, its 4x4 pose into the assembled frame, neighbours, confidence; missing regions
    with size and position; what to do next), <sample>_pieces.csv, <sample>_assembled.obj (+ .mtl,
    one group per piece, metres, target axis vertical), <sample>_missing.obj and PNG pictures.

    logs/build-log.txt in each scan folder: when the capture and build ran, each stage, pauses (phone
    locked), errors with their codes, and how long the build took.

    _app-log/ (next to the scan folders): the app's own diary, one crystal-bowl-<date>.log per day:
    starts, phone locks, builds, uploads, memory and heat warnings, every error, and a note when the
    previous run ended unexpectedly. _app-log/iOS reports/ holds crash, hang and exit reports from iOS
    (MetricKit JSON). No photos or passwords are in either.

    Folder names: <yyyyMMdd-HHmmss>_<sample name>, so they sort by scan time.
    """
}
