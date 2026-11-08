import Foundation

/// A row of the visible, flattened tree.
public struct Row: Identifiable, Hashable, Sendable {
    public let node: Node
    public let depth: Int
    public let hasChildren: Bool
    public var id: String { node.id }
}

/// Read-only index over a paper: children, roll-up marks and counts. Built once per change (papers have a few
/// hundred entries at most), so every lookup the screen makes is a dictionary read.
public struct Tree: Sendable {
    public let paper: Paper
    public let byID: [String: Node]
    private let kids: [String: [Node]]
    private let roots: [Node]
    private var effectiveMark: [String: Status] = [:]
    private var leafCounts: [String: (done: Int, total: Int)] = [:]

    public init(_ paper: Paper) {
        self.paper = paper
        let all = Dictionary(paper.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        // A node is visible when it and all its ancestors are live. A parent id that names nothing puts the
        // node at the top (Claude may name a parent that doesn't exist).
        var visible: [String: Node] = [:]
        func isVisible(_ n: Node, _ seen: Set<String>) -> Bool {
            if n.deleted { return false }
            guard let p = n.parentID, let parent = all[p], !seen.contains(p) else { return true }
            return isVisible(parent, seen.union([n.id]))
        }
        for n in all.values where isVisible(n, []) { visible[n.id] = n }
        byID = visible
        var k: [String: [Node]] = [:]
        var r: [Node] = []
        for n in visible.values {
            if let p = n.parentID, visible[p] != nil, p != n.id { k[p, default: []].append(n) } else { r.append(n) }
        }
        let sorter: (Node, Node) -> Bool = { a, b in a.order != b.order ? a.order < b.order : a.id < b.id }
        kids = k.mapValues { $0.sorted(by: sorter) }
        roots = r.sorted(by: sorter)
        for root in roots { _ = fill(root) }
    }

    private mutating func fill(_ n: Node) -> (Status, Int, Int) {
        let children = kids[n.id] ?? []
        if children.isEmpty {
            effectiveMark[n.id] = n.status
            let c = (n.status == .done ? 1 : 0, 1)
            leafCounts[n.id] = c
            return (n.status, c.0, c.1)
        }
        var done = 0, total = 0, allDone = true, anyStarted = false
        for child in children {
            let (s, d, t) = fill(child)
            done += d
            total += t
            if s != .done { allDone = false }
            if s != .todo { anyStarted = true }
        }
        let mark: Status = allDone ? .done : (anyStarted ? .inProgress : .todo)
        effectiveMark[n.id] = mark
        leafCounts[n.id] = (done, total)
        return (mark, done, total)
    }

    public func children(of id: String?) -> [Node] {
        guard let id else { return roots }
        return kids[id] ?? []
    }

    public func hasChildren(_ id: String) -> Bool { !(kids[id] ?? []).isEmpty }

    /// The mark shown for a node: its own for a leaf, rolled up from the children for a parent.
    public func mark(_ id: String) -> Status { effectiveMark[id] ?? byID[id]?.status ?? .todo }

    /// Finished leaves / all leaves under `id`, or in the whole paper for nil.
    public func counts(_ id: String?) -> (done: Int, total: Int) {
        if let id { return leafCounts[id] ?? (0, 0) }
        return roots.reduce((0, 0)) { acc, n in
            let c = leafCounts[n.id] ?? (0, 0)
            return (acc.0 + c.done, acc.1 + c.total)
        }
    }

    public func fraction(_ id: String?) -> Double {
        let c = counts(id)
        return c.total == 0 ? 0 : Double(c.done) / Double(c.total)
    }

    public func depth(_ id: String) -> Int {
        var d = 0
        var cur = byID[id]?.parentID
        while let p = cur, let n = byID[p], d < 64 {
            d += 1
            cur = n.parentID
        }
        return d
    }

    /// Ancestors from the top down, not including the node itself.
    public func path(_ id: String) -> [Node] {
        var out: [Node] = []
        var cur = byID[id]?.parentID
        while let p = cur, let n = byID[p], out.count < 64 {
            out.insert(n, at: 0)
            cur = n.parentID
        }
        return out
    }

    /// Every visible node in reading order (depth first).
    public func ordered() -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            out.append(n)
            for c in kids[n.id] ?? [] { walk(c) }
        }
        roots.forEach(walk)
        return out
    }

    public func leaves(under id: String?) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            let c = kids[n.id] ?? []
            if c.isEmpty { out.append(n) } else { c.forEach(walk) }
        }
        if let id, let n = byID[id] { walk(n) } else { roots.forEach(walk) }
        return out
    }

    /// The quest to work on: the first leaf in progress, else the first one still to do, in reading order.
    public func nextUp() -> Node? {
        let all = leaves(under: nil)
        return all.first { $0.status == .inProgress } ?? all.first { $0.status == .todo }
    }

    /// The rows to show. Children appear only under expanded parents; with `hideDone`, finished entries go.
    public func rows(expanded: Set<String>, hideDone: Bool = false) -> [Row] {
        var out: [Row] = []
        func walk(_ n: Node, _ depth: Int) {
            if hideDone && mark(n.id) == .done { return }
            let c = kids[n.id] ?? []
            out.append(Row(node: n, depth: depth, hasChildren: !c.isEmpty))
            if expanded.contains(n.id) { c.forEach { walk($0, depth + 1) } }
        }
        roots.forEach { walk($0, 0) }
        return out
    }

    /// Finds a node by id, or by its title (exact first, then containing), for Claude's inbox ops.
    public func find(_ key: String) -> Node? {
        if let n = byID[key] { return n }
        let k = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return nil }
        let all = ordered()
        return all.first { $0.title.lowercased() == k }
            ?? all.first { $0.anchor?.lowercased() == k }
            ?? all.first { $0.title.lowercased().contains(k) }
    }
}
