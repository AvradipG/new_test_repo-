import Foundation

/// A change Claude (or anyone) asks for by dropping a JSON file into the paper's `claude-inbox` folder on Drive.
///
///     {"from": "Claude", "ops": [
///       {"op": "set_status", "id": "gc/eq:harmonic", "status": "done"},
///       {"op": "add", "parent_match": "Results", "title": "Re-run ensemble with 320 realizations"},
///       {"op": "note", "match": "Cover letter", "text": "Mention the TI benchmark."}]}
///
/// A bare array of ops is accepted too. Targets are found by `id`, else by `match` (title, anchor, or part of a title).
public struct InboxOp: Codable, Hashable, Sendable {
    public var op: String
    public var id: String?
    public var match: String?
    public var parent: String?
    public var parentMatch: String?
    public var title: String?
    public var status: String?
    public var text: String?
    public var anchor: String?

    public init(op: String, id: String? = nil, match: String? = nil, parent: String? = nil, parentMatch: String? = nil,
                title: String? = nil, status: String? = nil, text: String? = nil, anchor: String? = nil) {
        self.op = op
        self.id = id
        self.match = match
        self.parent = parent
        self.parentMatch = parentMatch
        self.title = title
        self.status = status
        self.text = text
        self.anchor = anchor
    }

    enum CodingKeys: String, CodingKey {
        case op, id, match, parent, parentMatch = "parent_match", title, status, text, anchor
    }
}

public struct InboxFile: Codable, Sendable {
    public var from: String?
    public var ops: [InboxOp]

    public init(from: String? = nil, ops: [InboxOp]) {
        self.from = from
        self.ops = ops
    }

    public static func parse(_ data: Data) -> InboxFile? {
        if let f = try? JSONDecoder().decode(InboxFile.self, from: data) { return f }
        if let ops = try? JSONDecoder().decode([InboxOp].self, from: data) { return InboxFile(ops: ops) }
        if let op = try? JSONDecoder().decode(InboxOp.self, from: data) { return InboxFile(ops: [op]) }
        return nil
    }
}

public enum Inbox {
    /// Applies the ops in order and returns one line per op saying what happened.
    @discardableResult
    public static func apply(_ file: InboxFile, to paper: inout Paper, now: Date = Date()) -> [String] {
        var report: [String] = []
        for op in file.ops {
            let tree = Tree(paper)
            func target() -> Node? {
                if let id = op.id, let n = tree.byID[id] { return n }
                if let m = op.match ?? op.id { return tree.find(m) }
                return nil
            }
            switch op.op.lowercased() {
            case "set_status", "status", "tick":
                var wanted: Status? = op.status.flatMap { Status(loose: $0) }
                if wanted == nil && op.op.lowercased() == "tick" { wanted = .done }
                guard let n = target(), let s = wanted else { report.append("skipped \(op.op): entry or status not found"); continue }
                Edit.setStatus(&paper, id: n.id, to: s, now: now)
                report.append("\(n.title): \(s.label)")
            case "add":
                guard let title = op.title, !title.isEmpty else { report.append("skipped add: no title"); continue }
                var parentID: String?
                if let p = op.parent { parentID = tree.byID[p]?.id ?? tree.find(p)?.id }
                if parentID == nil, let pm = op.parentMatch { parentID = tree.find(pm)?.id }
                if (op.parent != nil || op.parentMatch != nil) && parentID == nil {
                    report.append("skipped add \(title): parent not found")
                    continue
                }
                let parentChildren = tree.children(of: parentID)
                if parentChildren.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                    report.append("skipped add \(title): already there")
                    continue
                }
                let newID = Edit.add(&paper, title: title, under: parentID, detail: op.text ?? "", anchor: op.anchor, now: now)
                if let s = op.status.flatMap(Status.init(loose:)), s != .todo { Edit.setStatus(&paper, id: newID, to: s, now: now) }
                report.append("added \(title)")
            case "note":
                guard let n = target(), let text = op.text else { report.append("skipped note: entry not found"); continue }
                let joined = n.note.isEmpty ? text : n.note + "\n" + text
                Edit.setNote(&paper, id: n.id, note: joined, now: now)
                report.append("note on \(n.title)")
            case "rename":
                guard let n = target(), let title = op.title else { report.append("skipped rename: entry not found"); continue }
                Edit.rename(&paper, id: n.id, to: title, now: now)
                report.append("renamed \(n.title) to \(title)")
            case "delete":
                guard let n = target() else { report.append("skipped delete: entry not found"); continue }
                Edit.delete(&paper, id: n.id, now: now)
                report.append("deleted \(n.title)")
            default:
                report.append("skipped unknown op \(op.op)")
            }
        }
        return report
    }
}

/// The human- and Claude-readable copy written next to progress.json.
public enum MarkdownExport {
    public static func render(_ paper: Paper, now: Date = Date()) -> String {
        let tree = Tree(paper)
        let c = tree.counts(nil)
        let pct = c.total == 0 ? 0 : Int((Double(c.done) / Double(c.total) * 100).rounded())
        let iso = ISO8601DateFormatter().string(from: now)
        var lines = [
            "# \(paper.title)",
            "",
            "Paper Quest progress, written by the iPhone app at \(iso).",
            "\(c.done) of \(c.total) items done (\(pct)%). XP \(Points.xp(tree)) of \(Points.possible(tree)).",
            "Ticks today: \(Streak.today(paper.wins.map(\.at), now: now)). Streak: \(Streak.days(paper.wins.map(\.at), now: now)) days.",
            "",
            "Marks: [x] done, [~] in progress, [ ] to do. Ids in backticks can be used in claude-inbox ops (see README.txt).",
        ]
        if let next = tree.nextUp() {
            lines.append("Next up: \(next.title) `\(next.id)`")
        }
        if let url = paper.manuscriptURL { lines.append("Manuscript: \(url)") }
        lines.append("")
        func mark(_ s: Status) -> String { s == .done ? "[x]" : s == .inProgress ? "[~]" : "[ ]" }
        func walk(_ n: Node, _ depth: Int) {
            let k = tree.counts(n.id)
            if depth == 0 {
                lines.append("## \(mark(tree.mark(n.id))) \(n.title) (\(k.done)/\(k.total)) `\(n.id)`")
            } else {
                let indent = String(repeating: "  ", count: depth - 1)
                let count = tree.hasChildren(n.id) ? " (\(k.done)/\(k.total))" : ""
                lines.append("\(indent)- \(mark(tree.mark(n.id))) \(n.title)\(count) `\(n.id)`")
            }
            if !n.note.isEmpty {
                let indent = String(repeating: "  ", count: max(0, depth))
                for l in n.note.split(separator: "\n") { lines.append("\(indent)  > \(l)") }
            }
            for ch in tree.children(of: n.id) { walk(ch, depth + 1) }
            if depth == 0 { lines.append("") }
        }
        tree.children(of: nil).forEach { walk($0, 0) }
        return lines.joined(separator: "\n") + "\n"
    }

    public static let readme = """
    Paper Quest
    ===========
    Written by the Paper Quest iPhone app. One folder per paper, updated after every change and whenever the app
    opens or closes.

    progress.json   the whole tracker: sections > subsections > items, each with status (todo, in_progress,
                    done), note and the manuscript object it is about. Schema paper-quest.progress/1.
    progress.md     the same as a readable checklist with counts, XP and streak.

    Asking for changes (Claude, or you on a computer)
    -------------------------------------------------
    Put a .json file in the paper's claude-inbox folder. The app applies it the next time it syncs, once.
    It works when the app is linked to this folder through the Google Drive app (Settings › Google Drive).
    {"from": "Claude", "ops": [
      {"op": "set_status", "id": "<id from progress.md>", "status": "done"},
      {"op": "add", "parent_match": "Results", "title": "New item"},
      {"op": "note", "match": "Cover letter", "text": "A note"},
      {"op": "rename", "id": "<id>", "title": "Better name"},
      {"op": "delete", "id": "<id>"}]}
    "match" finds an entry by its title, anchor (e.g. eq:harmonic) or part of its title.
    """
}
