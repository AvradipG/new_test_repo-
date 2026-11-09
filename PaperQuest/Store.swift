import Foundation
import PaperCore
import SwiftUI
import UIKit

enum AppTab: Hashable { case quests, manuscript, settings }

/// What the screen shows after a tick: a small "+10 XP" toast, or confetti for a cleared subsection, section or paper.
struct CelebrationEvent: Identifiable, Equatable {
    let id = UUID()
    let headline: String
    let title: String
    let cheer: String
    let big: Bool
}

/// Owns every paper. Each paper is one JSON file in Documents/Papers (the same file that goes to Drive), so the
/// owner can also see them in Files › On My iPhone › Paper Quest.
@MainActor
final class Store: ObservableObject {
    static let dailyGoalKey = "quest.dailyGoal"
    static let removedKey = "papers.removed"

    @Published private(set) var papers: [Paper] = []
    @Published var celebration: CelebrationEvent?
    @Published var isSyncing = false
    @Published var driveStatus: String?
    @Published var lastDriveSync: Date?
    @Published var driveSignedIn = false
    @Published var driveEmail: String?
    @Published var folderLinked = false
    @Published var folderName: String?
    @Published var inboxReport: String?
    @Published var latestRemote: RemoteVersion?
    @Published var tab: AppTab = .quests
    /// A paper to show in the Manuscript tab (set from a tracker; the tab opens it and clears this).
    @Published var manuscriptRequest: String?

    var syncTask: Task<Void, Never>?
    var syncAgain = false

    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let papersDir: URL = {
        let url = docs.appendingPathComponent("Papers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        load()
        if papers.isEmpty && !removed.contains(Templates.greenChristoffelID) {
            save(Templates.greenChristoffel())
        }
        refreshDriveAccount()
    }

    // MARK: Totals for the quest header

    var dailyGoal: Int {
        get { max(1, UserDefaults.standard.object(forKey: Self.dailyGoalKey) as? Int ?? 3) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(max(1, newValue), forKey: Self.dailyGoalKey)
        }
    }

    var allTicks: [Date] { papers.flatMap { $0.wins.map(\.at) } }
    var totalXP: Int { papers.reduce(0) { $0 + Points.xp(Tree($1)) } }
    var level: Level { Level.of(xp: totalXP) }
    var streak: Int { Streak.days(allTicks) }
    var today: Int { Streak.today(allTicks) }

    func paper(_ id: String) -> Paper? { papers.first { $0.id == id } }

    // MARK: Files

    static func fileURL(_ id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return papersDir.appendingPathComponent("\(safe).json")
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.papersDir, includingPropertiesForKeys: nil)) ?? []
        papers = files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? PaperJSON.decode($0) } }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Saves one paper (replacing the copy in memory) without starting a sync.
    func save(_ paper: Paper) {
        if let i = papers.firstIndex(where: { $0.id == paper.id }) { papers[i] = paper } else { papers.append(paper) }
        if let data = try? PaperJSON.encode(paper) { try? data.write(to: Self.fileURL(paper.id), options: .atomic) }
    }

    var removed: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Self.removedKey) ?? []) }

    // MARK: Changes

    /// Applies a change, saves it, celebrates and syncs a few seconds later.
    func change(_ paperID: String, _ body: (inout Paper) -> Celebration?) {
        guard var p = paper(paperID) else { return }
        let ticksBefore = today
        let result = body(&p)
        save(p)
        celebrate(result, ticksBefore: ticksBefore)
        scheduleSync()
    }

    func setStatus(_ paperID: String, _ nodeID: String, _ status: Status) {
        change(paperID) { Edit.setStatus(&$0, id: nodeID, to: status) }
    }

    /// Tapping a mark on an item: to do → in progress → done → to do.
    func cycle(_ paperID: String, _ nodeID: String) {
        guard let p = paper(paperID), let n = Tree(p).byID[nodeID] else { return }
        setStatus(paperID, nodeID, n.status.next)
    }

    @discardableResult
    func add(_ paperID: String, title: String, under parent: String?) -> String? {
        var newID: String?
        change(paperID) { p in
            newID = Edit.add(&p, title: title, under: parent)
            return nil
        }
        return newID
    }

    func rename(_ paperID: String, _ nodeID: String, to title: String) {
        change(paperID) { Edit.rename(&$0, id: nodeID, to: title); return nil }
    }

    func setNote(_ paperID: String, _ nodeID: String, _ note: String) {
        change(paperID) { Edit.setNote(&$0, id: nodeID, note: note); return nil }
    }

    func delete(_ paperID: String, _ nodeID: String) {
        change(paperID) { Edit.delete(&$0, id: nodeID); return nil }
    }

    func move(_ paperID: String, _ nodeID: String, by step: Int) {
        change(paperID) { Edit.move(&$0, id: nodeID, by: step); return nil }
    }

    func renamePaper(_ paperID: String, title: String, url: String) {
        change(paperID) { p in
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { p.title = t }
            let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
            p.manuscriptURL = u.isEmpty ? nil : u
            p.updatedAt = Date()
            return nil
        }
    }

    func newPaper(title: String, url: String) {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        save(Templates.article(title: title, manuscriptURL: u.isEmpty ? nil : u))
        scheduleSync()
    }

    /// Shows a paper in the Manuscript tab. False when Manuscript Studio isn't signed in (use Safari then).
    func openManuscript(_ paperID: String) -> Bool {
        guard StudioSession.shared.signedIn else { return false }
        tab = .manuscript
        manuscriptRequest = paperID
        return true
    }

    /// A tracker for a Manuscript Studio paper, sharing its id so Claude/ChatGPT can update both.
    func trackStudioPaper(id: String, title: String) {
        guard paper(id) == nil else { return }
        if id == Templates.greenChristoffelID {
            restoreGreenChristoffel()
            return
        }
        save(Templates.article(title: title, id: id, manuscriptURL: FirebaseWebConfig.manuscriptURL(paper: id).absoluteString))
        scheduleSync()
    }

    func restoreGreenChristoffel() {
        var r = removed
        r.remove(Templates.greenChristoffelID)
        UserDefaults.standard.set(Array(r), forKey: Self.removedKey)
        if paper(Templates.greenChristoffelID) == nil { save(Templates.greenChristoffel()) }
        scheduleSync()
    }

    /// Removes a paper from this phone. Its Drive folder stays (delete it there if wanted); it isn't re-imported.
    func removePaper(_ paperID: String) {
        papers.removeAll { $0.id == paperID }
        try? FileManager.default.removeItem(at: Self.fileURL(paperID))
        var r = removed
        r.insert(paperID)
        UserDefaults.standard.set(Array(r), forKey: Self.removedKey)
    }

    /// Applies Claude/ChatGPT tracker ops (same format as a claude-inbox file) and returns what happened.
    @discardableResult
    func applyInbox(_ paperID: String, _ file: InboxFile) -> [String] {
        var report: [String] = []
        change(paperID) { p in
            report = Inbox.apply(file, to: &p)
            return nil
        }
        return report
    }

    /// Takes in a copy from Drive (another device, or Claude's inbox) and keeps whichever edits are newer.
    func absorb(_ remote: Paper) {
        guard !removed.contains(remote.id) else { return }
        if let local = paper(remote.id) {
            let merged = Merge.merge(local: local, remote: remote)
            if merged != local { save(merged) }
        } else {
            save(remote)
        }
    }

    // MARK: Celebration

    private func celebrate(_ c: Celebration?, ticksBefore: Int) {
        let after = today
        let goal = dailyGoal
        let cheer = Cheers.all.randomElement() ?? ""
        if let c, c.isBig {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            celebration = CelebrationEvent(headline: c.headline, title: c.title, cheer: cheer, big: true)
        } else if ticksBefore < goal && after >= goal {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            celebration = CelebrationEvent(headline: "Daily goal met!", title: "\(after) ticks today", cheer: "Streak: \(streak) days", big: true)
        } else if let c {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            celebration = CelebrationEvent(headline: c.headline, title: c.title, cheer: cheer, big: false)
        } else {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
