import Foundation
import UIKit

/// Copies finished scans into a folder the user picked in the Files app, normally My Drive › Crystal Bowl Scans
/// from the Google Drive app. Needs no Google sign-in or client ID: the Google Drive app uploads the files
/// itself, in its own time, also after this app is closed. Same folder layout as the direct Drive upload.
extension AppModel {
    static let folderBookmarkKey = "drive.folderBookmark"

    func refreshFolderLink() {
        if let url = Self.resolveFolder() {
            folderLinked = true
            folderName = url.lastPathComponent
        } else {
            folderLinked = false
            folderName = nil
        }
    }

    static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: folderBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: folderBookmarkKey)
            }
        }
        return url
    }

    /// Stores access to the picked folder and copies every finished scan into it.
    func linkFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.folderBookmarkKey)
            for var scan in scans where scan.folderSync != nil {
                scan.folderSync = nil // a new folder: copy everything again
                try? ScanStore.save(scan)
            }
            reload()
            refreshFolderLink()
            Task { await syncFolderPending(force: true) }
        } catch {
            errorMessage = "Couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }

    func unlinkFolder() {
        UserDefaults.standard.removeObject(forKey: Self.folderBookmarkKey)
        refreshFolderLink()
    }

    /// Copies every finished scan with files the folder doesn't have yet.
    func syncFolderPending(force: Bool = false) async {
        guard folderLinked, !driveSignedIn, !isFolderSyncing, force || autoUpload else { return }
        let unmetered = await NetworkState.isUnmetered()
        for scan in scans where scan.hasModel && scan.buildRequested != true {
            if needsCopy(scan.folderSync, scan: scan, photosAllowed: unmetered) { await syncToFolder(scan) }
        }
    }

    func needsCopy(_ state: DriveSync?, scan: Scan, photosAllowed: Bool) -> Bool {
        guard let state, state.complete else { return true }
        let files = ScanPackage.files(for: scan, includePhotos: uploadPhotos && photosAllowed)
        return files.contains { rel, url in
            guard let rec = state.files[rel] else { return true }
            return Self.changed(url, rec)
        }
    }

    func syncToFolder(_ original: Scan) async {
        guard let root = Self.resolveFolder(), !isFolderSyncing else { return }
        isFolderSyncing = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "drive-folder-copy")
        defer {
            isFolderSyncing = false
            UIApplication.shared.endBackgroundTask(bg)
        }
        var scan = scans.first { $0.id == original.id } ?? original
        var state = scan.folderSync ?? DriveSync()
        state.complete = false
        folderStatus[scan.id] = "Copying to the Drive folder…"
        let photosNow = uploadPhotos && (scan.hasPhotos || scan.detailCount > 0) ? await NetworkState.isUnmetered() : false
        let files = ScanPackage.files(for: scan, includePhotos: photosNow)
        let todo = files.filter { rel, url in state.files[rel].map { Self.changed(url, $0) } ?? true }
        let folder = "\(scan.id)_\(scan.fileStem)"

        let copied: Result<[String: DriveFileRecord], Error> = await Task.detached {
            do {
                var done: [String: DriveFileRecord] = [:]
                try FolderCopy.withAccess(root) {
                    let dest = root.appendingPathComponent(folder, isDirectory: true)
                    for (rel, url) in todo {
                        try FolderCopy.copy(url, to: dest.appendingPathComponent(rel))
                        done[rel] = FolderCopy.record(url)
                    }
                }
                return .success(done)
            } catch {
                return .failure(error)
            }
        }.value

        switch copied {
        case .failure(let error):
            AppLog.warn("drive", "Copy of \(scan.name) to the Drive folder paused: \(AppLog.describe(error))")
            folderStatus[scan.id] = "Copy paused: \(error.localizedDescription). It retries when you next open the app."
            return
        case .success(let done):
            state.files.merge(done) { _, new in new }
        }

        // The manifest goes last, so its presence means the package is complete.
        let hashes: [String: String] = await Task.detached {
            var h: [String: String] = [:]
            for (rel, url) in files { h[rel] = ScanPackage.sha256(url) }
            return h
        }.value
        let unhashed = files.filter { hashes[$0.0] == nil }
        guard unhashed.isEmpty else {
            AppLog.warn("folder", "Manifest held back: \(unhashed.count) file(s) could not be read for a checksum", scan: scan)
            scan.folderSync = state
            try? ScanStore.save(scan)
            return
        }
        let manifestURL = scan.folderURL.appendingPathComponent("manifest.json")
        let readmeURL = FileManager.default.temporaryDirectory.appendingPathComponent("README.txt")
        do {
            try ScanPackage.manifest(for: scan, files: files, hashes: hashes, photosUploaded: photosNow).write(to: manifestURL, options: .atomic)
            try ScanPackage.readme.write(to: readmeURL, atomically: true, encoding: .utf8)
            try await Task.detached {
                try FolderCopy.withAccess(root) {
                    try FolderCopy.copy(manifestURL, to: root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("manifest.json"))
                    try FolderCopy.copy(readmeURL, to: root.appendingPathComponent("README.txt"))
                }
            }.value
            state.complete = true
            state.lastSync = Date()
            scan.folderSync = state
            try? ScanStore.save(scan)
            folderStatus[scan.id] = nil
            if photosNow && !driveSignedIn && !UserDefaults.standard.bool(forKey: Self.keepPhotosKey) { ScanStore.deletePhotos(scan) }
        } catch {
            scan.folderSync = state
            try? ScanStore.save(scan)
            folderStatus[scan.id] = "Copy paused: \(error.localizedDescription). It retries when you next open the app."
        }
        reload()
    }
}

extension AppModel {
    /// Without a Google sign-in, the app log is copied into the linked Drive folder instead (_app-log).
    func copyAppLogToFolder() async {
        guard folderLinked, !driveSignedIn, uploadLog, !uploadingLog, let root = Self.resolveFolder() else { return }
        uploadingLog = true
        defer { uploadingLog = false }
        AppLog.flush()
        var records = Self.loadRecords(Self.logCopyRecordsKey)
        let todo = AppLog.files().filter { rel, url in records[rel].map { Self.changed(url, $0) } ?? true }
        guard !todo.isEmpty else { return }
        let copied: Result<[String: DriveFileRecord], Error> = await Task.detached {
            do {
                var done: [String: DriveFileRecord] = [:]
                try FolderCopy.withAccess(root) {
                    let dest = root.appendingPathComponent("_app-log", isDirectory: true)
                    for (rel, url) in todo {
                        let before = FolderCopy.record(url)
                        try FolderCopy.copy(url, to: dest.appendingPathComponent(rel))
                        done[rel] = before
                    }
                }
                return .success(done)
            } catch {
                return .failure(error)
            }
        }.value
        switch copied {
        case .success(let done):
            records.merge(done) { _, new in new }
            Self.saveRecords(records, Self.logCopyRecordsKey)
        case .failure(let error):
            AppLog.warn("drive", "App log copy to the Drive folder paused: \(AppLog.describe(error))")
        }
    }
}

enum FolderCopy {
    static func withAccess(_ root: URL, _ body: () throws -> Void) throws {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        try body()
    }

    /// Replaces `dst` with a copy of `src`, coordinated with the folder's file provider (the Google Drive app).
    static func copy(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: dst, options: .forReplacing, error: &coordinationError) { url in
            do {
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                try fm.copyItem(at: src, to: url)
            } catch {
                copyError = error
            }
        }
        if let e = coordinationError ?? copyError { throw e }
    }

    static func record(_ url: URL) -> DriveFileRecord {
        let a = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return DriveFileRecord(id: "", size: (a[.size] as? NSNumber)?.int64Value ?? 0, modified: a[.modificationDate] as? Date ?? Date())
    }
}
