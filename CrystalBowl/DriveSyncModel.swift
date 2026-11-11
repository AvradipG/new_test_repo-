import Foundation
import UIKit

/// Automatic upload of finished scans to Google Drive › Crystal Bowl Scans.
extension AppModel {
    static let autoUploadKey = "drive.autoUpload"
    static let uploadPhotosKey = "drive.uploadPhotos"
    private static let indexIDKey = "drive.indexID"
    private static let readmeIDKey = "drive.readmeID"

    /// Always on: every finished scan goes to Drive by itself.
    var autoUpload: Bool { true }
    /// On by default: the original photos let a Mac or PC rebuild the model at full detail later.
    var uploadPhotos: Bool { UserDefaults.standard.object(forKey: Self.uploadPhotosKey) as? Bool ?? true }

    func refreshDriveAccount() {
        driveSignedIn = GoogleAuth.shared.isSignedIn
        driveEmail = GoogleAuth.shared.email
        // One place on Drive only: once signed in, the Files-folder copy (which could land anywhere) stops.
        if driveSignedIn && UserDefaults.standard.data(forKey: Self.folderBookmarkKey) != nil { unlinkFolder() }
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
        await syncFolderPending(force: force)
        guard driveSignedIn, !isSyncing else { return }
        reload()
        let unmetered = await NetworkState.isUnmetered()
        for scan in scans where scan.hasModel && scan.buildRequested != true {
            if needsSync(scan, photosAllowed: unmetered) { await sync(scan) }
        }
        await uploadAppLog()
    }

    // MARK: App log

    static let uploadLogKey = "applog.upload"
    private static let logRecordsKey = "applog.driveFiles"
    static let logCopyRecordsKey = "applog.folderFiles"
    static let lastLogUploadKey = "applog.lastUpload"

    /// On by default: the app's diary and iOS crash reports go to Drive with the scans.
    var uploadLog: Bool { UserDefaults.standard.object(forKey: Self.uploadLogKey) as? Bool ?? true }

    static func loadRecords(_ key: String) -> [String: DriveFileRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: DriveFileRecord].self, from: data)) ?? [:]
    }

    static func saveRecords(_ records: [String: DriveFileRecord], _ key: String) {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Documents › App log goes to My Drive › Crystal Bowl Scans › _app-log; only files that changed.
    func uploadAppLog() async {
        await copyAppLogToFolder()
        guard driveSignedIn, uploadLog, !uploadingLog else { return }
        uploadingLog = true
        defer { uploadingLog = false }
        AppLog.flush()
        var records = Self.loadRecords(Self.logRecordsKey)
        let todo = AppLog.files().filter { rel, url in records[rel].map { Self.changed(url, $0) } ?? true }
        guard !todo.isEmpty else {
            UserDefaults.standard.set(Date(), forKey: Self.lastLogUploadKey)
            return
        }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "drive-log")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        do {
            let client = DriveClient()
            let root = try await client.folder(named: ScanPackage.rootFolder, in: "root")
            let logFolder = try await client.folder(named: "_app-log", in: root)
            var subfolders: [String: String] = [:]
            for (rel, url) in todo {
                var parent = logFolder
                // "iOS reports/…" and "Screens/…" (3.13) go into folders of that name.
                if let slash = rel.firstIndex(of: "/") {
                    let sub = String(rel[..<slash])
                    if subfolders[sub] == nil { subfolders[sub] = try await client.folder(named: sub, in: logFolder) }
                    parent = subfolders[sub] ?? logFolder
                }
                let before = FolderCopy.record(url) // a file that grows during the upload goes again next time
                // Upload a still copy: the log keeps growing while it is sent, and a file larger than the size
                // announced when the upload opened is refused by Google with HTTP 400 (seen in 3.8's log).
                let still = FileManager.default.temporaryDirectory.appendingPathComponent("upload-" + url.lastPathComponent)
                try? FileManager.default.removeItem(at: still)
                try FileManager.default.copyItem(at: url, to: still)
                defer { try? FileManager.default.removeItem(at: still) }
                let id = try await uploadReplacing(client, still, name: url.lastPathComponent, parent: parent, existing: records[rel]?.id)
                records[rel] = DriveFileRecord(id: id, size: before.size, modified: before.modified)
                Self.saveRecords(records, Self.logRecordsKey)
            }
            UserDefaults.standard.set(Date(), forKey: Self.lastLogUploadKey)
        } catch {
            AppLog.warn("drive", "App log upload paused: \(AppLog.describe(error))")
        }
    }

    func needsSync(_ scan: Scan, photosAllowed: Bool) -> Bool {
        guard let state = scan.drive, state.complete else { return true }
        let files = ScanPackage.files(for: scan, includePhotos: state.photos ?? (uploadPhotos && photosAllowed))
        return files.contains { rel, url in
            guard let rec = state.files[rel] else { return true }
            return Self.changed(url, rec)
        }
    }

    static func changed(_ url: URL, _ rec: DriveFileRecord) -> Bool {
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
        var state = scan.drive ?? DriveSync()
        do {
            // Lab formats go to Drive with every scan, so make them if they don't exist yet.
            let plyPath = scan.exportsURL.appendingPathComponent("\(scan.fileStem).ply").path
            if !FileManager.default.fileExists(atPath: plyPath) {
                driveStatus[scan.id] = "Preparing upload…"
                let s = scan
                _ = await Task.detached { MeshTools.exportAll(s) }.value
            }
            if state.photos == nil || state.complete {
                state.photos = uploadPhotos && (scan.hasPhotos || scan.detailCount > 0) ? await NetworkState.isUnmetered() : false
            }
            let files = ScanPackage.files(for: scan, includePhotos: state.photos ?? false)
            let running = await DriveBackground.shared.inFlight()[scan.id] ?? []

            let client = DriveClient()
            let root = try await client.folder(named: ScanPackage.rootFolder, in: "root")
            let folderID = try await client.folder(named: "\(scan.id)_\(scan.fileStem)", in: root)
            if state.folderID != folderID { state.files = [:] } // folder was recreated on Drive
            state.folderID = folderID
            state.complete = false
            scan.drive = state
            try? ScanStore.save(scan)
            reload()
            var folders: [String: String] = ["": folderID]

            func folder(for rel: String) async throws -> String {
                let dir = (rel as NSString).deletingLastPathComponent
                if let id = folders[dir] { return id }
                let parent = try await folder(for: dir)
                let id = try await client.folder(named: (dir as NSString).lastPathComponent, in: parent)
                folders[dir] = id
                return id
            }

            // Hand every missing file to iOS, which uploads them in the background, also with the app closed.
            let todo = files.filter { rel, url in
                !running.contains(rel) && (state.files[rel].map { Self.changed(url, $0) } ?? true)
            }
            for (n, (rel, url)) in todo.enumerated() {
                driveStatus[scan.id] = "Handing files to iOS for upload: \(n + 1) of \(todo.count)…"
                let a = try FileManager.default.attributesOfItem(atPath: url.path)
                let item = DriveBackground.Item(scanID: scan.id, rel: rel,
                                                size: (a[.size] as? NSNumber)?.int64Value ?? 0,
                                                modified: a[.modificationDate] as? Date ?? Date())
                let parent = try await folder(for: rel)
                let sessionURL: URL
                if let existing = state.files[rel]?.id,
                   let u = try? await client.startUpload(url, name: url.lastPathComponent, parent: parent, existingID: existing) {
                    sessionURL = u
                } else {
                    sessionURL = try await client.startUpload(url, name: url.lastPathComponent, parent: parent, existingID: nil)
                }
                DriveBackground.shared.submit(item, to: sessionURL, file: url, mime: DriveClient.mimeType(for: url.pathExtension))
            }
            updateUploadStatus(scan.id)
            await finishIfUploaded(scan.id)
        } catch {
            driveStatus[scan.id] = "Upload paused: \(error.localizedDescription). It carries on by itself when the phone is online."
            AppDelegate.scheduleUploadTask()
        }
    }

    /// Called (also with the app in the background) each time iOS finishes uploading one file.
    func backgroundUploadFinished(_ item: DriveBackground.Item, fileID: String?) {
        guard var scan = ScanStore.loadAll().first(where: { $0.id == item.scanID }) else { return }
        if let fileID {
            var state = scan.drive ?? DriveSync()
            state.files[item.rel] = DriveFileRecord(id: fileID, size: item.size, modified: item.modified)
            scan.drive = state
            try? ScanStore.save(scan)
            reload()
        } else {
            AppDelegate.scheduleUploadTask() // retried later; nothing is lost
        }
        updateUploadStatus(item.scanID)
    }

    /// Writes the manifest and the index for every scan whose files are all on Drive.
    func finishCompletedUploads() async {
        reload()
        for scan in scans where scan.drive != nil && scan.drive?.complete != true {
            await finishIfUploaded(scan.id)
        }
    }

    private func updateUploadStatus(_ id: String) {
        guard let scan = scans.first(where: { $0.id == id }), let state = scan.drive, !state.complete else {
            driveStatus[id] = nil
            return
        }
        let files = ScanPackage.files(for: scan, includePhotos: state.photos ?? false)
        let done = files.filter { rel, _ in state.files[rel] != nil }.count
        driveStatus[id] = "Uploading \(done) of \(files.count) files. It carries on in the background, also with the phone locked."
    }

    /// The manifest goes last, so its presence on Drive means the package is complete.
    func finishIfUploaded(_ id: String) async {
        guard driveSignedIn, var scan = scans.first(where: { $0.id == id }), var state = scan.drive,
              let folderID = state.folderID else { return }
        let photos = state.photos ?? false
        let files = ScanPackage.files(for: scan, includePhotos: photos)
        let missing = files.contains { rel, url in state.files[rel].map { Self.changed(url, $0) } ?? true }
        guard !missing else { return }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "drive-manifest")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        driveStatus[id] = "Writing manifest…"
        do {
            let hashes: [String: String] = await Task.detached {
                var h: [String: String] = [:]
                for (rel, url) in files { h[rel] = ScanPackage.sha256(url) }
                return h
            }.value
            // Every file needs its checksum before the package counts as complete and photos may be deleted (3.6).
            let unhashed = files.filter { hashes[$0.0] == nil }.map { $0.0 }
            guard unhashed.isEmpty else {
                AppLog.warn("drive", "Manifest held back: \(unhashed.count) file(s) could not be read for a checksum, e.g. \(unhashed.prefix(3).joined(separator: ", "))", scan: scan)
                driveStatus[id] = nil
                return
            }
            let client = DriveClient()
            // Sheets made again replace the old ones on the phone; their old copies on Drive (another angle, the
            // older layout) go to the Drive bin so the folder only holds the current set (3.8).
            let current = Set(files.map { $0.0 })
            let stale = state.files.keys.filter { $0.hasPrefix("model/sheet/") && !current.contains($0) }.sorted()
            var binned = 0
            for rel in stale {
                guard let fid = state.files[rel]?.id else { state.files[rel] = nil; continue }
                do {
                    try await client.trash(fid)
                    binned += 1
                    state.files[rel] = nil
                } catch let e as DriveError where e.fileGone {
                    state.files[rel] = nil
                } catch {
                    AppLog.warn("drive", "Old sheet \((rel as NSString).lastPathComponent) not moved to the Drive bin: \(error.localizedDescription)", scan: scan)
                }
            }
            if binned > 0 { AppLog.info("drive", "\(binned) old sheet file(s) moved to the Drive bin", scan: scan) }
            let manifestURL = scan.folderURL.appendingPathComponent("manifest.json")
            try ScanPackage.manifest(for: scan, files: files, hashes: hashes, photosUploaded: photos).write(to: manifestURL, options: .atomic)
            let mid = try await uploadReplacing(client, manifestURL, name: "manifest.json", parent: folderID, existing: state.files["manifest.json"]?.id)
            state.files["manifest.json"] = DriveFileRecord(id: mid, size: 0, modified: Date())
            state.complete = true
            state.lastSync = Date()
            scan.drive = state
            try? ScanStore.save(scan)
            if photos && !UserDefaults.standard.bool(forKey: Self.keepPhotosKey) { ScanStore.deletePhotos(scan) }
            reload()
            driveStatus[id] = nil
            let root = try await client.folder(named: ScanPackage.rootFolder, in: "root")
            await writeIndex(client, root: root)
            Notifier.post(id: "drive-\(id)", title: "\(scan.name): on Google Drive",
                          body: "My Drive › \(ScanPackage.rootFolder) › \(scan.id)_\(scan.fileStem)")
        } catch {
            driveStatus[id] = "Upload paused: \(error.localizedDescription). It carries on by itself when the phone is online."
            AppDelegate.scheduleUploadTask()
        }
    }

    /// Updates a file in place; if it was deleted on Drive, uploads it as a new file.
    private func uploadReplacing(_ client: DriveClient, _ url: URL, name: String, parent: String, existing: String?) async throws -> String {
        if let existing {
            do {
                return try await client.upload(url, name: name, parent: parent, existingID: existing)
            } catch let e as DriveError where e.fileGone {
                AppLog.info("drive", "\(name) was gone from Drive (HTTP \(e.status ?? 0)); uploading it as a new file")
            }
            // Any other failure (busy, 5xx, network) is thrown, so the next try updates the same file
            // instead of leaving a duplicate on Drive (3.6).
        }
        return try await client.upload(url, name: name, parent: parent, existingID: nil)
    }

    /// Crystal Bowl Scans/index.json: one entry per scan on Drive, newest first, with what it is, when it was
    /// scanned, its sizes and where its files are. Software can read this one file instead of every folder.
    private func writeIndex(_ client: DriveClient, root: String) async {
        let f = ISO8601DateFormatter()
        let local = ISO8601DateFormatter()
        local.timeZone = .current
        local.formatOptions = [.withInternetDateTime]
        let entries: [[String: Any]] = scans.compactMap { s in
            guard let d = s.drive, let folderID = d.folderID else { return nil }
            var e: [String: Any] = [
                "scan_id": s.id, "name": s.name, "sample_key": s.sampleKey, "kind": s.isPieces ? "pieces" : "sample",
                "pieces": s.piecesResult.map { $0.json(scan: s) as Any } ?? NSNull(),
                "scanned_utc": f.string(from: s.created), "scanned_local": local.string(from: s.created),
                "folder": "\(s.id)_\(s.fileStem)", "folder_id": folderID,
                "folder_url": ScanPackage.folderLink(folderID)?.absoluteString ?? "",
                "manifest": "\(s.id)_\(s.fileStem)/manifest.json",
                "manifest_file_id": d.files["manifest.json"]?.id ?? NSNull(),
                "dimensions_file": "\(s.id)_\(s.fileStem)/model/\(s.fileStem)-dimensions.json",
                "status": d.complete ? "complete" : "uploading",
                "last_upload_utc": d.lastSync.map { f.string(from: $0) } ?? NSNull(),
                "quick_scan": s.quick ?? false,
                "photos_included": d.photos ?? false,
                "close_up_photos": s.detailCount,
                "scale": s.scaleSource,
            ]
            if let st = s.stats {
                let k = s.scaleFactor
                e["size_mm"] = ["a": st.axisA * k, "b": st.axisB * k, "c": st.axisC * k]
                e["volume_cm3"] = st.volumeCM3 * k * k * k
                if let b = st.box { e["feret_mm"] = ["max": b.maxFeretMM * k, "min": b.minFeretMM * k] }
                if let shape = s.shape { e["shape"] = shape.json(scale: k) }
                if let m = s.mark { e["reference_mark_deg"] = m.angle; e["reference_mark_source"] = m.source }
                if let u = st.upright {
                    e["micro_ct"] = ["height_mm": u.heightMM * k,
                                     "cylinder_diameter_mm": (u.cylinderDiameterMM ?? u.maxDiameterMM) * k]
                }
            }
            return e
        }
        let index: [String: Any] = [
            "schema": "crystal-bowl.index/1",
            "about": "Every scan in this folder, newest first. Sizes in mm (a >= b >= c, smallest box around the rock). Each scan's manifest.json is the full record with every file; a scan is complete when its status is complete.",
            "updated_utc": f.string(from: Date()),
            "scan_count": entries.count,
            "scans": entries,
        ]
        let tmp = FileManager.default.temporaryDirectory
        let indexURL = tmp.appendingPathComponent("index.json")
        let readmeURL = tmp.appendingPathComponent("README.txt")
        guard let data = try? JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: indexURL, options: .atomic)) != nil else { return }
        let ud = UserDefaults.standard
        if let id = try? await uploadReplacing(client, indexURL, name: "index.json", parent: root, existing: ud.string(forKey: Self.indexIDKey)) {
            ud.set(id, forKey: Self.indexIDKey)
        }
        if (try? ScanPackage.readme.write(to: readmeURL, atomically: true, encoding: .utf8)) != nil,
           let id = try? await uploadReplacing(client, readmeURL, name: "README.txt", parent: root, existing: ud.string(forKey: Self.readmeIDKey)) {
            ud.set(id, forKey: Self.readmeIDKey)
        }
    }
}
