import Foundation
import UIKit

/// Automatic upload of finished scans to Google Drive › Crystal Bowl Scans.
extension AppModel {
    static let autoUploadKey = "drive.autoUpload"
    static let uploadPhotosKey = "drive.uploadPhotos"
    private static let indexIDKey = "drive.indexID"
    private static let readmeIDKey = "drive.readmeID"

    var autoUpload: Bool { UserDefaults.standard.object(forKey: Self.autoUploadKey) as? Bool ?? true }
    var uploadPhotos: Bool { UserDefaults.standard.bool(forKey: Self.uploadPhotosKey) }

    func refreshDriveAccount() {
        driveSignedIn = GoogleAuth.shared.isSignedIn
        driveEmail = GoogleAuth.shared.email
    }

    func signInToDrive() async {
        do {
            try await GoogleAuth.shared.signIn()
            refreshDriveAccount()
            await syncAllPending(force: true)
        } catch {
            refreshDriveAccount()
            let text = error.localizedDescription
            if !text.lowercased().contains("cancel") { errorMessage = "Google sign-in didn't work: \(text)" }
        }
    }

    func signOutOfDrive() {
        GoogleAuth.shared.signOut()
        refreshDriveAccount()
    }

    /// Uploads every finished scan that has files Drive doesn't have yet.
    func syncAllPending(force: Bool = false) async {
        guard driveSignedIn, !isSyncing, force || autoUpload else { return }
        let unmetered = await NetworkState.isUnmetered()
        for scan in scans where scan.hasModel {
            if needsSync(scan, photosAllowed: unmetered) { await sync(scan) }
        }
    }

    func needsSync(_ scan: Scan, photosAllowed: Bool) -> Bool {
        guard let state = scan.drive, state.complete else { return true }
        let files = ScanPackage.files(for: scan, includePhotos: uploadPhotos && photosAllowed)
        return files.contains { rel, url in
            guard let rec = state.files[rel] else { return true }
            return Self.changed(url, rec)
        }
    }

    private static func changed(_ url: URL, _ rec: DriveFileRecord) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mod = a[.modificationDate] as? Date ?? .distantPast
        return size != rec.size || abs(mod.timeIntervalSince(rec.modified)) > 1
    }

    func sync(_ original: Scan) async {
        guard driveSignedIn, !isSyncing else { return }
        isSyncing = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "drive-upload")
        defer {
            isSyncing = false
            UIApplication.shared.endBackgroundTask(bg)
        }
        var scan = scans.first { $0.id == original.id } ?? original
        driveStatus[scan.id] = "Preparing upload…"
        var state = scan.drive ?? DriveSync()
        state.complete = false
        do {
            // Lab formats go to Drive with every scan, so make them if they don't exist yet.
            let plyPath = scan.exportsURL.appendingPathComponent("\(scan.fileStem).ply").path
            if !FileManager.default.fileExists(atPath: plyPath) {
                let s = scan
                _ = await Task.detached { MeshTools.exportAll(s) }.value
            }
            let photosNow = uploadPhotos && scan.hasPhotos ? await NetworkState.isUnmetered() : false
            let files = ScanPackage.files(for: scan, includePhotos: photosNow)

            let client = DriveClient()
            let root = try await client.folder(named: ScanPackage.rootFolder, in: "root")
            let folderID = try await client.folder(named: "\(scan.id)_\(scan.fileStem)", in: root)
            if state.folderID != folderID { state.files = [:] } // folder was recreated on Drive
            state.folderID = folderID
            var folders: [String: String] = ["": folderID]

            func folder(for rel: String) async throws -> String {
                let dir = (rel as NSString).deletingLastPathComponent
                if let id = folders[dir] { return id }
                let parent = try await folder(for: dir)
                let id = try await client.folder(named: (dir as NSString).lastPathComponent, in: parent)
                folders[dir] = id
                return id
            }

            for (i, (rel, url)) in files.enumerated() {
                let a = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (a[.size] as? NSNumber)?.int64Value ?? 0
                let mod = a[.modificationDate] as? Date ?? Date()
                if let rec = state.files[rel], !Self.changed(url, rec) { continue }
                driveStatus[scan.id] = "Uploading \(i + 1) of \(files.count)…"
                let parent = try await folder(for: rel)
                let id = try await uploadReplacing(client, url, name: url.lastPathComponent, parent: parent, existing: state.files[rel]?.id)
                state.files[rel] = DriveFileRecord(id: id, size: size, modified: mod)
                scan.drive = state
                try? ScanStore.save(scan)
            }

            // The manifest goes last, so its presence on Drive means the package is complete.
            driveStatus[scan.id] = "Writing manifest…"
            let hashes: [String: String] = await Task.detached {
                var h: [String: String] = [:]
                for (rel, url) in files { h[rel] = ScanPackage.sha256(url) }
                return h
            }.value
            let manifestURL = scan.folderURL.appendingPathComponent("manifest.json")
            try ScanPackage.manifest(for: scan, files: files, hashes: hashes, photosUploaded: photosNow).write(to: manifestURL, options: .atomic)
            let mid = try await uploadReplacing(client, manifestURL, name: "manifest.json", parent: folderID, existing: state.files["manifest.json"]?.id)
            state.files["manifest.json"] = DriveFileRecord(id: mid, size: 0, modified: Date())
            state.complete = true
            state.lastSync = Date()
            scan.drive = state
            try? ScanStore.save(scan)

            if photosNow && !UserDefaults.standard.bool(forKey: Self.keepPhotosKey) { ScanStore.deletePhotos(scan) }
            reload()
            await writeIndex(client, root: root)
            driveStatus[scan.id] = nil
        } catch {
            scan.drive = state
            try? ScanStore.save(scan)
            reload()
            driveStatus[scan.id] = "Upload paused: \(error.localizedDescription). It retries when you next open the app."
        }
    }

    /// Updates a file in place; if it was deleted on Drive, uploads it as a new file.
    private func uploadReplacing(_ client: DriveClient, _ url: URL, name: String, parent: String, existing: String?) async throws -> String {
        if let existing {
            if let id = try? await client.upload(url, name: name, parent: parent, existingID: existing) { return id }
        }
        return try await client.upload(url, name: name, parent: parent, existingID: nil)
    }

    /// Crystal Bowl Scans/index.json lists every scan, newest first; README.txt explains the layout.
    private func writeIndex(_ client: DriveClient, root: String) async {
        let f = ISO8601DateFormatter()
        let entries: [[String: Any]] = scans.compactMap { s in
            guard let d = s.drive, d.folderID != nil else { return nil }
            var e: [String: Any] = [
                "scan_id": s.id, "specimen_alias": s.name, "created_utc": f.string(from: s.created),
                "folder": "\(s.id)_\(s.fileStem)", "folder_id": d.folderID ?? "",
                "status": d.complete ? "complete" : "incomplete",
                "last_upload_utc": d.lastSync.map { f.string(from: $0) } ?? NSNull(),
            ]
            if let st = s.stats {
                e["principal_axes_mm"] = ["a": st.axisA, "b": st.axisB, "c": st.axisC]
                e["volume_cm3"] = st.volumeCM3
            }
            return e
        }
        let index: [String: Any] = ["schema": "crystal-bowl.index/0.1", "updated_utc": f.string(from: Date()), "scans": entries]
        let tmp = FileManager.default.temporaryDirectory
        let indexURL = tmp.appendingPathComponent("index.json")
        let readmeURL = tmp.appendingPathComponent("README.txt")
        guard let data = try? JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: indexURL, options: .atomic)) != nil else { return }
        let ud = UserDefaults.standard
        if let id = try? await uploadReplacing(client, indexURL, name: "index.json", parent: root, existing: ud.string(forKey: Self.indexIDKey)) {
            ud.set(id, forKey: Self.indexIDKey)
        }
        if ud.string(forKey: Self.readmeIDKey) == nil, (try? ScanPackage.readme.write(to: readmeURL, atomically: true, encoding: .utf8)) != nil,
           let id = try? await client.upload(readmeURL, name: "README.txt", parent: root, existingID: nil) {
            ud.set(id, forKey: Self.readmeIDKey)
        }
    }
}
