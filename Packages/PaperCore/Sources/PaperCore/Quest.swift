import Foundation

/// XP is computed from the tree, never stored, so it always matches what is ticked.
public enum Points {
    public static let leaf = 10

    /// Bonus for finishing a whole parent: a top-level section, a subsection, or anything deeper.
    public static func bonus(depth: Int) -> Int {
        switch depth {
        case 0: return 100
        case 1: return 30
        default: return 15
        }
    }

    public static func xp(_ tree: Tree) -> Int {
        var total = 0
        for n in tree.ordered() {
            guard tree.mark(n.id) == .done else { continue }
            total += tree.hasChildren(n.id) ? bonus(depth: tree.depth(n.id)) : leaf
        }
        return total
    }

    public static func possible(_ tree: Tree) -> Int {
        tree.ordered().reduce(0) { $0 + (tree.hasChildren($1.id) ? bonus(depth: tree.depth($1.id)) : leaf) }
    }
}

public struct Level: Equatable, Sendable {
    public let number: Int
    public let title: String
    /// XP where this level starts and where the next one starts.
    public let floor: Int
    public let next: Int

    public static let titles = [
        "Blank Page", "Outliner", "Drafter", "Equation Tamer", "Figure Smith", "Wordsmith",
        "Referee Whisperer", "Camera-Ready", "Published", "Prolific", "Distinguished",
    ]

    /// Level n starts at 50·n·(n−1) XP: 0, 100, 300, 600, 1000, 1500, …
    public static func start(_ n: Int) -> Int { 50 * n * (n - 1) }

    public static func of(xp: Int) -> Level {
        var n = 1
        while start(n + 1) <= xp { n += 1 }
        let title = titles[min(n - 1, titles.count - 1)]
        return Level(number: n, title: title, floor: start(n), next: start(n + 1))
    }

    public func fraction(xp: Int) -> Double {
        next > floor ? min(1, max(0, Double(xp - floor) / Double(next - floor))) : 1
    }
}

public enum Streak {
    /// Consecutive days (ending today, or yesterday if nothing is done yet today) with at least one tick.
    public static func days(_ dates: [Date], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor) {
            guard let y = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = y
        }
        var n = 0
        while days.contains(cursor) {
            n += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return n
    }

    public static func today(_ dates: [Date], now: Date = Date(), calendar: Calendar = .current) -> Int {
        dates.filter { calendar.isDate($0, inSameDayAs: now) }.count
    }
}

/// What the screen celebrates after a change: the biggest thing that just became done.
public enum Celebration: Equatable, Sendable {
    case item(String)
    case group(String)
    case section(String)
    case paper(String)

    public var title: String {
        switch self {
        case .item(let t), .group(let t), .section(let t), .paper(let t): return t
        }
    }

    public var headline: String {
        switch self {
        case .item: return "+\(Points.leaf) XP"
        case .group: return "Subsection cleared"
        case .section: return "Section complete!"
        case .paper: return "Paper complete!"
        }
    }

    public var isBig: Bool {
        switch self {
        case .item: return false
        default: return true
        }
    }
}

public enum Cheers {
    public static let all = [
        "Nice. Next one?", "One step closer to submission.", "Tiny wins add up.",
        "Reviewer 2 can't stop you.", "Momentum! Keep riding it.", "Your future self says thanks.",
        "Done is better than perfect.",
    ]
}

/// Every change to a paper. Pure functions, so the app, the merge and Claude's inbox all behave the same.
public enum Edit {
    /// Sets a mark. On a parent, `done` or `todo` applies to every leaf under it; `inProgress` starts its next leaf.
    @discardableResult
    public static func setStatus(_ paper: inout Paper, id: String, to status: Status, now: Date = Date(),
                                 calendar: Calendar = .current) -> Celebration? {
        let before = Tree(paper)
        guard before.byID[id] != nil else { return nil }
        let targets: [String]
        let newStatus = status
        if before.hasChildren(id) {
            let leaves = before.leaves(under: id)
            if status == .inProgress {
                guard let first = leaves.first(where: { $0.status != .done }) else { return nil }
                targets = [first.id]
            } else {
                targets = leaves.map(\.id)
            }
        } else {
            targets = [id]
        }
        let targetSet = Set(targets)
        for i in paper.nodes.indices where targetSet.contains(paper.nodes[i].id) {
            let old = paper.nodes[i].status
            guard old != newStatus else { continue }
            paper.nodes[i].status = newStatus
            paper.nodes[i].updatedAt = now
            if newStatus == .done {
                paper.nodes[i].completedAt = now
                paper.wins.append(Win(id: UUID().uuidString, nodeID: paper.nodes[i].id, at: now))
            } else if old == .done {
                paper.nodes[i].completedAt = nil
                // Un-ticking the same day takes back today's tick, so the daily goal can't be farmed.
                let nodeID = paper.nodes[i].id
                if let w = paper.wins.lastIndex(where: { $0.nodeID == nodeID && calendar.isDate($0.at, inSameDayAs: now) }) {
                    paper.wins.remove(at: w)
                }
            }
        }
        paper.updatedAt = now
        return celebration(before: before, after: Tree(paper))
    }

    static func celebration(before: Tree, after: Tree) -> Celebration? {
        let newlyDone = after.ordered().filter { after.mark($0.id) == .done && before.mark($0.id) != .done }
        guard !newlyDone.isEmpty else { return nil }
        let rootsDone = after.children(of: nil).allSatisfy { after.mark($0.id) == .done }
        if rootsDone && !before.children(of: nil).allSatisfy({ before.mark($0.id) == .done }) {
            return .paper(after.paper.title)
        }
        let parents = newlyDone.filter { after.hasChildren($0.id) }
        if let top = parents.min(by: { after.depth($0.id) < after.depth($1.id) }) {
            return after.depth(top.id) == 0 ? .section(top.title) : .group(top.title)
        }
        return .item(newlyDone[0].title)
    }

    /// Adds an entry at the end of `parent` (nil for a new section). Returns its id.
    @discardableResult
    public static func add(_ paper: inout Paper, title: String, under parent: String?, detail: String = "",
                           anchor: String? = nil, id: String? = nil, now: Date = Date()) -> String {
        let siblings = paper.nodes.filter { $0.parentID == parent && !$0.deleted }
        let order = (siblings.map(\.order).max() ?? 0) + 1
        let newID = id ?? "n-" + UUID().uuidString.prefix(8).lowercased()
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        paper.nodes.append(Node(id: newID, parentID: parent, title: clean.isEmpty ? "Untitled" : clean, detail: detail,
                                order: order, anchor: anchor, updatedAt: now))
        paper.updatedAt = now
        return newID
    }

    public static func update(_ paper: inout Paper, id: String, now: Date = Date(), _ change: (inout Node) -> Void) {
        guard let i = paper.nodes.firstIndex(where: { $0.id == id }) else { return }
        change(&paper.nodes[i])
        paper.nodes[i].updatedAt = now
        paper.updatedAt = now
    }

    public static func rename(_ paper: inout Paper, id: String, to title: String, now: Date = Date()) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        update(&paper, id: id, now: now) { $0.title = clean }
    }

    public static func setNote(_ paper: inout Paper, id: String, note: String, now: Date = Date()) {
        update(&paper, id: id, now: now) { $0.note = note }
    }

    /// Deletes an entry and everything under it (as tombstones, so the delete syncs).
    public static func delete(_ paper: inout Paper, id: String, now: Date = Date()) {
        var doomed: Set<String> = [id]
        var grew = true
        while grew {
            grew = false
            for n in paper.nodes where !doomed.contains(n.id) {
                if let p = n.parentID, doomed.contains(p) {
                    doomed.insert(n.id)
                    grew = true
                }
            }
        }
        for i in paper.nodes.indices where doomed.contains(paper.nodes[i].id) && !paper.nodes[i].deleted {
            paper.nodes[i].deleted = true
            paper.nodes[i].updatedAt = now
        }
        paper.updatedAt = now
    }

    /// Moves an entry one place up (-1) or down (+1) among its siblings.
    public static func move(_ paper: inout Paper, id: String, by step: Int, now: Date = Date()) {
        let tree = Tree(paper)
        guard let node = tree.byID[id] else { return }
        let siblings = tree.children(of: node.parentID)
        guard let pos = siblings.firstIndex(where: { $0.id == id }) else { return }
        let target = pos + step
        guard siblings.indices.contains(target) else { return }
        var reordered = siblings
        reordered.swapAt(pos, target)
        for (k, n) in reordered.enumerated() where n.order != Double(k + 1) {
            update(&paper, id: n.id, now: now) { $0.order = Double(k + 1) }
        }
    }
}

/// Combines two copies of a paper (this phone and Google Drive, written by another device or by Claude).
/// For each entry the newer edit wins; deletes win ties; ticks from both sides are kept.
public enum Merge {
    public static func merge(local: Paper, remote: Paper, calendar: Calendar = .current) -> Paper {
        var out = local.updatedAt >= remote.updatedAt ? local : remote
        var nodes: [String: Node] = [:]
        var order: [String] = []
        for n in local.nodes + remote.nodes {
            if let have = nodes[n.id] {
                if n.updatedAt > have.updatedAt || (n.updatedAt == have.updatedAt && n.deleted && !have.deleted) {
                    nodes[n.id] = n
                }
            } else {
                nodes[n.id] = n
                order.append(n.id)
            }
        }
        out.nodes = order.compactMap { nodes[$0] }
        var wins: [String: Win] = [:]
        for w in local.wins + remote.wins { wins[w.id] = w }
        // A tick later taken back the same day (on either device) is dropped.
        out.wins = wins.values.filter { w in
            guard let n = nodes[w.nodeID] else { return true }
            let undone = n.status != .done && n.updatedAt >= w.at && calendar.isDate(n.updatedAt, inSameDayAs: w.at)
            return !undone
        }.sorted { $0.at < $1.at }
        out.appliedInbox = Array(Set(local.appliedInbox).union(remote.appliedInbox)).sorted()
        out.updatedAt = max(local.updatedAt, remote.updatedAt)
        out.createdAt = min(local.createdAt, remote.createdAt)
        return out
    }
}
