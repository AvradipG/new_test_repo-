import Foundation
import PaperCore
import UIKit

/// Two-way sync with Google Drive › Paper Quest, one folder per paper:
///   progress.json   the paper (read back and merged, so the iPhone, an iPad and Claude stay in step)
///   progress.md     readable checklist (what Claude reads through the Drive connector)
///   claude-inbox/   JSON files with changes asked for by Claude (folder route only, see README.txt)
/// Two routes, as in Crystal Bowl and Tidy Atlas: a folder of the Google Drive app (no sign-in here) or direct
/// Google sign-in. A burst of edits becomes one sync a few seconds later; opening and leaving the app sync too.
extension Store {
    static let rootFolderName = "Paper Quest"
    static let folderBookmarkKey = "drive.folderBookmark"
    static let lastSyncKey = "drive.lastSync"

    struct PaperDrive: Codable {
        var folderID: String?
        var jsonID: String?
        var mdID: String?
        var jsonHash: String?
    }

    struct DriveState: Codable {
        var rootID: String?
        var readmeID: String?
        var papers: [String: PaperDrive] = [:]
    }

    static var stateURL: URL { docs.appendingPathComponent("drive-state.json") }
    static func loadState() -> DriveState {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(DriveState.self, from: $0) } ?? DriveState()
    }
    static func saveState(_ s: DriveState) {
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL, options: .atomic) }
    }

    /// "Green–Christoffel polarization (green-christoffel-writing)". The id in brackets is what is matched,
    /// so renaming a paper never makes a second folder.
    nonisolated static func folderName(_ p: Paper) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let t = p.title.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return "\(String(t.prefix(60))) (\(p.id))"
    }

    nonisolated static func paperID(fromFolder name: String) -> String? {
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return nil }
        let id = String(name[open.upperBound..<name.index(before: name.endIndex)])
        return id.isEmpty ? nil : id
    }

    // MARK: Account

    func refreshDriveAccount() {
        driveSignedIn = GoogleAuth.shared.isSignedIn
        driveEmail = GoogleAuth.shared.email
        // One route at a time: once signed in, the folder link stops.
        if driveSignedIn && UserDefaults.standard.data(forKey: Self.folderBookmarkKey) != nil { unlinkFolder() }
        refreshFolderLink()
        lastDriveSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    func signInToDrive() async {
        do {
            try await GoogleAuth.shared.signIn()
            refreshDriveAccount()
            await syncDrive()
        } catch {
            refreshDriveAccount()
            let text = error.localizedDescription
            if !text.lowercased().contains("cancel") { driveStatus = "Google sign-in didn't work: \(text)" }
        }
    }

    func signOutOfDrive() {
        GoogleAuth.shared.signOut()
        refreshDriveAccount()
    }

    var driveConnected: Bool { driveSignedIn || folderLinked }

    func scheduleSync() {
        guard driveConnected else { return }
        syncTask?.cancel()
        syncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self.syncDrive()
        }
    }

    func syncDrive() async {
        guard driveConnected else { return }
        guard !isSyncing else {
            syncAgain = true
            return
        }
        isSyncing = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "paper-quest-sync")
        do {
            if folderLinked && !driveSignedIn { try await syncFolder() } else { try await syncSignedIn() }
            lastDriveSync = Date()
            UserDefaults.standard.set(lastDriveSync, forKey: Self.lastSyncKey)
            driveStatus = nil
        } catch {
            driveStatus = "Sync paused: \(error.localizedDescription). It tries again after your next change or when the app opens."
        }
        isSyncing = false
        UIApplication.shared.endBackgroundTask(bg)
        if syncAgain {
            syncAgain = false
            await syncDrive()
        }
    }

    // MARK: Direct Google sign-in (drive.file scope: the app sees only files it created)

    private func syncSignedIn() async throws {
        let drive = DriveClient()
        var st = Self.loadState()
        let root = try await drive.folder(named: Self.rootFolderName, in: "root")
        if st.rootID != root { st = DriveState(rootID: root) }
        if st.readmeID == nil {
            st.readmeID = try await drive.put(Data(MarkdownExport.readme.utf8), name: "README.txt", parent: root, existingID: nil)
            Self.saveState(st)
        }
        let top = try await drive.list(in: root)
        let folders = top.filter(\.isFolder)

        // Papers made on another device.
        for f in folders {
            guard let pid = Self.paperID(fromFolder: f.name), paper(pid) == nil, !removed.contains(pid) else { continue }
            let inside = try await drive.list(in: f.id)
            guard let json = inside.first(where: { $0.name == "progress.json" }) else { continue }
            let data = try await drive.download(json.id)
            if let p = try? PaperJSON.decode(data) {
                absorb(p)
                st.papers[pid] = PaperDrive(folderID: f.id, jsonID: json.id)
            }
        }

        for id in papers.map(\.id) {
            var pd = st.papers[id] ?? PaperDrive()
            if let fid = pd.folderID, !folders.contains(where: { $0.id == fid }) { pd = PaperDrive() }
            if pd.folderID == nil, let p = paper(id) {
                if let existing = folders.first(where: { Self.paperID(fromFolder: $0.name) == id }) {
                    pd.folderID = existing.id
                } else {
                    pd.folderID = try await drive.createFolder(named: Self.folderName(p), in: root)
                }
            }
            guard let folderID = pd.folderID else { continue }

            // Pull: another device may have written a newer copy.
            if pd.jsonID == nil {
                pd.jsonID = try await drive.list(in: folderID).first(where: { $0.name == "progress.json" })?.id
            }
            if let jsonID = pd.jsonID {
                do {
                    let data = try await drive.download(jsonID)
                    if data.sha256 != pd.jsonHash, let remote = try? PaperJSON.decode(data) { absorb(remote) }
                } catch let e as DriveError where e.isMissing {
                    pd.jsonID = nil
                    pd.jsonHash = nil
                }
            }

            // Push.
            guard let current = paper(id) else { continue }
            let json = try PaperJSON.encode(current)
            if json.sha256 != pd.jsonHash || pd.jsonID == nil {
                pd.jsonID = try await drive.put(json, name: "progress.json", parent: folderID, existingID: pd.jsonID)
                pd.jsonHash = json.sha256
                let md = Data(MarkdownExport.render(current).utf8)
                pd.mdID = try await drive.put(md, name: "progress.md", parent: folderID, existingID: pd.mdID)
            }
            st.papers[id] = pd
            Self.saveState(st)
        }
        Self.saveState(st)
    }

    // MARK: Folder of the Google Drive app (reads Claude's inbox too)

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

    func linkFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.folderBookmarkKey)
            refreshFolderLink()
            Task { await syncDrive() }
        } catch {
            driveStatus = "Couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }

    func unlinkFolder() {
        UserDefaults.standard.removeObject(forKey: Self.folderBookmarkKey)
        refreshFolderLink()
    }

    private func syncFolder() async throws {
        guard let root = Self.resolveFolder() else {
            refreshFolderLink()
            throw DriveError(message: "The Drive folder can't be reached. Choose it again in Settings.")
        }
        let localIDs = papers.map(\.id)
        let removedIDs = removed
        // 1. Read (off the main thread: the Google Drive app may download files first).
        let snapshot = try await Task.detached { try FolderIO.read(root: root, localIDs: localIDs, removed: removedIDs) }.value

        // 2. Merge and apply Claude's inbox.
        for data in snapshot.progress.values {
            if let p = try? PaperJSON.decode(data) { absorb(p) }
        }
        var reports: [String] = []
        for (pid, files) in snapshot.inbox {
            guard var p = paper(pid) else { continue }
            var changed = false
            for (name, data) in files where !p.appliedInbox.contains(name) {
                if let file = InboxFile.parse(data) {
                    let lines = Inbox.apply(file, to: &p)
                    reports.append("\(file.from ?? "Inbox"): " + lines.joined(separator: "; "))
                }
                p.appliedInbox.append(name)
                changed = true
            }
            if changed { save(p) }
        }
        if !reports.isEmpty { inboxReport = reports.joined(separator: "\n") }

        // 3. Write.
        let out = papers.map { p in
            (folder: snapshot.folders[p.id] ?? Self.folderName(p),
             json: (try? PaperJSON.encode(p)) ?? Data(),
             md: Data(MarkdownExport.render(p).utf8))
        }
        let readme = Data(MarkdownExport.readme.utf8)
        try await Task.detached {
            try FolderIO.write(root: root, readme: readme, papers: out.map { ($0.folder, $0.json, $0.md) })
        }.value
    }
}

/// Coordinated file access inside the linked Google Drive folder (from Crystal Bowl's FolderSync).
enum FolderIO {
    struct Snapshot: Sendable {
        var folders: [String: String] = [:]          // paper id → folder name
        var progress: [String: Data] = [:]           // paper id → progress.json
        var inbox: [String: [(String, Data)]] = [:]  // paper id → inbox files, by name
    }

    static func withAccess<T>(_ root: URL, _ body: () throws -> T) throws -> T {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    static func readFile(_ url: URL) -> Data? {
        var result: Data?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    static func writeFile(_ data: Data, to url: URL) throws {
        if readFile(url) == data { return }
        var err: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let e = err ?? writeError { throw e }
    }

    static func subfolders(_ url: URL) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    static func read(root: URL, localIDs: [String], removed: Set<String>) throws -> Snapshot {
        try withAccess(root) {
            var s = Snapshot()
            for dir in subfolders(root) {
                guard let pid = Store.paperID(fromFolder: dir.lastPathComponent), !removed.contains(pid) else { continue }
                s.folders[pid] = dir.lastPathComponent
                if let data = readFile(dir.appendingPathComponent("progress.json")) { s.progress[pid] = data }
                let inboxDir = dir.appendingPathComponent("claude-inbox", isDirectory: true)
                let files = ((try? FileManager.default.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension.lowercased() == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                let loaded = files.compactMap { f in readFile(f).map { (f.lastPathComponent, $0) } }
                if !loaded.isEmpty { s.inbox[pid] = loaded }
            }
            return s
        }
    }

    static func write(root: URL, readme: Data, papers: [(String, Data, Data)]) throws {
        try withAccess(root) {
            let fm = FileManager.default
            try writeFile(readme, to: root.appendingPathComponent("README.txt"))
            for (folder, json, md) in papers {
                let dir = root.appendingPathComponent(folder, isDirectory: true)
                try fm.createDirectory(at: dir.appendingPathComponent("claude-inbox", isDirectory: true), withIntermediateDirectories: true)
                try writeFile(json, to: dir.appendingPathComponent("progress.json"))
                try writeFile(md, to: dir.appendingPathComponent("progress.md"))
            }
        }
    }
}
