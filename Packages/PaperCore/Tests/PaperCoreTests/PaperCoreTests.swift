import XCTest
@testable import PaperCore

final class PaperCoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func small() -> Paper {
        var p = Paper(id: "p", title: "Test", now: t0)
        Edit.add(&p, title: "Intro", under: nil, id: "s1", now: t0)
        Edit.add(&p, title: "Text", under: "s1", id: "s1/t", now: t0)
        Edit.add(&p, title: "Draft", under: "s1/t", id: "a", now: t0)
        Edit.add(&p, title: "Polish", under: "s1/t", id: "b", now: t0)
        Edit.add(&p, title: "Methods", under: nil, id: "s2", now: t0)
        Edit.add(&p, title: "Write it", under: "s2", id: "c", now: t0)
        return p
    }

    func testStatusCycleAndLooseParsing() {
        XCTAssertEqual(Status.todo.next, .inProgress)
        XCTAssertEqual(Status.inProgress.next, .done)
        XCTAssertEqual(Status.done.next, .todo)
        XCTAssertEqual(Status(loose: "In Progress"), .inProgress)
        XCTAssertEqual(Status(loose: "complete"), .done)
        XCTAssertNil(Status(loose: "maybe"))
    }

    func testRollUpMarksAndCounts() {
        var p = small()
        var tree = Tree(p)
        XCTAssertEqual(tree.mark("s1"), .todo)
        XCTAssertEqual(tree.counts(nil).total, 3)
        Edit.setStatus(&p, id: "a", to: .inProgress, now: t0)
        tree = Tree(p)
        XCTAssertEqual(tree.mark("s1/t"), .inProgress)
        XCTAssertEqual(tree.mark("s1"), .inProgress)
        Edit.setStatus(&p, id: "a", to: .done, now: t0)
        Edit.setStatus(&p, id: "b", to: .done, now: t0)
        tree = Tree(p)
        XCTAssertEqual(tree.mark("s1"), .done)
        XCTAssertEqual(tree.mark("s2"), .todo)
        XCTAssertEqual(tree.counts("s1").done, 2)
        XCTAssertEqual(tree.counts(nil).done, 2)
        XCTAssertEqual(tree.fraction(nil), 2.0 / 3.0, accuracy: 1e-9)
    }

    func testParentDoneTicksEveryLeafAndCelebratesSection() {
        var p = small()
        let c = Edit.setStatus(&p, id: "s1", to: .done, now: t0)
        XCTAssertEqual(c, .section("Intro"))
        let tree = Tree(p)
        XCTAssertEqual(tree.leaves(under: "s1").map(\.status), [.done, .done])
        XCTAssertEqual(p.wins.count, 2)
        XCTAssertEqual(Edit.setStatus(&p, id: "c", to: .done, now: t0), .paper("Test"))
    }

    func testSubsectionAndItemCelebrations() {
        var p = small()
        Edit.add(&p, title: "Figures", under: "s1", id: "s1/f", now: t0)
        Edit.add(&p, title: "Fig 1", under: "s1/f", id: "f1", now: t0)
        XCTAssertEqual(Edit.setStatus(&p, id: "a", to: .done, now: t0), .item("Draft"))
        XCTAssertEqual(Edit.setStatus(&p, id: "b", to: .done, now: t0), .group("Text"))
        XCTAssertNil(Edit.setStatus(&p, id: "b", to: .done, now: t0))
    }

    func testParentInProgressStartsFirstOpenLeaf() {
        var p = small()
        Edit.setStatus(&p, id: "a", to: .done, now: t0)
        Edit.setStatus(&p, id: "s1", to: .inProgress, now: t0)
        XCTAssertEqual(Tree(p).byID["b"]?.status, .inProgress)
    }

    func testSameDayUndoTakesBackTheTick() {
        var p = small()
        Edit.setStatus(&p, id: "a", to: .done, now: t0)
        XCTAssertEqual(p.wins.count, 1)
        Edit.setStatus(&p, id: "a", to: .todo, now: t0.addingTimeInterval(60))
        XCTAssertEqual(p.wins.count, 0)
        Edit.setStatus(&p, id: "a", to: .done, now: t0)
        Edit.setStatus(&p, id: "a", to: .todo, now: t0.addingTimeInterval(3 * 86400))
        XCTAssertEqual(p.wins.count, 1, "an old day's tick stays in the streak history")
    }

    func testXPAndLevels() {
        var p = small()
        XCTAssertEqual(Points.xp(Tree(p)), 0)
        // leaves 3×10, subsection Text 30, sections 2×100
        XCTAssertEqual(Points.possible(Tree(p)), 30 + 30 + 200)
        Edit.setStatus(&p, id: "s1", to: .done, now: t0)
        XCTAssertEqual(Points.xp(Tree(p)), 20 + 30 + 100)
        XCTAssertEqual(Level.of(xp: 0).number, 1)
        XCTAssertEqual(Level.of(xp: 99).number, 1)
        XCTAssertEqual(Level.of(xp: 100).number, 2)
        XCTAssertEqual(Level.of(xp: 300).number, 3)
        XCTAssertEqual(Level.of(xp: 150).fraction(xp: 150), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Level.of(xp: 1_000_000).title, Level.titles.last)
    }

    func testStreak() {
        let cal = Calendar(identifier: .gregorian)
        let day: TimeInterval = 86400
        let now = t0
        XCTAssertEqual(Streak.days([], now: now, calendar: cal), 0)
        XCTAssertEqual(Streak.days([now, now - day, now - 2 * day], now: now, calendar: cal), 3)
        XCTAssertEqual(Streak.days([now - day, now - 2 * day], now: now, calendar: cal), 2)
        XCTAssertEqual(Streak.days([now - 3 * day], now: now, calendar: cal), 0)
        XCTAssertEqual(Streak.today([now, now, now - day], now: now, calendar: cal), 2)
    }

    func testDeleteIsTombstonedWithChildrenAndHidden() {
        var p = small()
        Edit.delete(&p, id: "s1", now: t0)
        let tree = Tree(p)
        XCTAssertNil(tree.byID["s1"])
        XCTAssertNil(tree.byID["a"])
        XCTAssertEqual(p.nodes.filter(\.deleted).count, 4)
        XCTAssertEqual(tree.counts(nil).total, 1)
    }

    func testMoveReorders() {
        var p = small()
        Edit.move(&p, id: "s2", by: -1, now: t0)
        XCTAssertEqual(Tree(p).children(of: nil).map(\.id), ["s2", "s1"])
        Edit.move(&p, id: "s2", by: -1, now: t0)
        XCTAssertEqual(Tree(p).children(of: nil).map(\.id), ["s2", "s1"])
    }

    func testRowsFollowExpansionAndHideDone() {
        var p = small()
        var rows = Tree(p).rows(expanded: [])
        XCTAssertEqual(rows.map(\.id), ["s1", "s2"])
        rows = Tree(p).rows(expanded: ["s1", "s1/t"])
        XCTAssertEqual(rows.map(\.id), ["s1", "s1/t", "a", "b", "s2"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 2, 0])
        Edit.setStatus(&p, id: "a", to: .done, now: t0)
        rows = Tree(p).rows(expanded: ["s1", "s1/t"], hideDone: true)
        XCTAssertEqual(rows.map(\.id), ["s1", "s1/t", "b", "s2"])
    }

    func testNextUpPrefersInProgress() {
        var p = small()
        XCTAssertEqual(Tree(p).nextUp()?.id, "a")
        Edit.setStatus(&p, id: "c", to: .inProgress, now: t0)
        XCTAssertEqual(Tree(p).nextUp()?.id, "c")
    }

    func testOrphanGoesToTopAndCycleIsSafe() {
        var p = small()
        p.nodes.append(Node(id: "x", parentID: "missing", title: "Orphan", updatedAt: t0))
        p.nodes.append(Node(id: "y", parentID: "z", title: "Y", updatedAt: t0))
        p.nodes.append(Node(id: "z", parentID: "y", title: "Z", updatedAt: t0))
        let tree = Tree(p)
        XCTAssertTrue(tree.children(of: nil).contains { $0.id == "x" })
        _ = tree.rows(expanded: Set(tree.byID.keys))
    }

    func testMergeNewerWinsDeletesSyncAndTicksUnion() {
        var a = small()
        var b = a
        Edit.setStatus(&a, id: "a", to: .done, now: t0.addingTimeInterval(10))
        Edit.rename(&b, id: "a", to: "Draft v2", now: t0.addingTimeInterval(5))
        Edit.delete(&b, id: "s2", now: t0.addingTimeInterval(20))
        Edit.add(&b, title: "New", under: "s1", id: "n", now: t0.addingTimeInterval(30))
        let m = Merge.merge(local: a, remote: b)
        let tree = Tree(m)
        XCTAssertEqual(tree.byID["a"]?.status, .done, "a's later tick wins over b's earlier rename")
        XCTAssertNil(tree.byID["s2"])
        XCTAssertNotNil(tree.byID["n"])
        XCTAssertEqual(m.wins.count, 1)
        XCTAssertEqual(Merge.merge(local: b, remote: a).nodes.count, m.nodes.count)
    }

    func testMergeDropsTickTakenBackOnAnotherDevice() {
        var a = small()
        Edit.setStatus(&a, id: "a", to: .done, now: t0)
        var b = a
        Edit.setStatus(&b, id: "a", to: .todo, now: t0.addingTimeInterval(60))
        let m = Merge.merge(local: a, remote: b)
        XCTAssertEqual(Tree(m).byID["a"]?.status, .todo)
        XCTAssertEqual(m.wins.count, 0)
    }

    func testJSONRoundTripAndLenientDecode() throws {
        let p = small()
        let back = try PaperJSON.decode(PaperJSON.encode(p))
        XCTAssertEqual(back, p)
        let hand = """
        {"id": "h", "title": "Hand", "nodes": [{"id": "1", "title": "One", "status": "in progress"},
          {"id": "2", "parent_id": "1", "status": "done", "updated_at": "2026-11-07T10:00:00Z"}]}
        """
        let h = try PaperJSON.decode(Data(hand.utf8))
        XCTAssertEqual(h.nodes.count, 2)
        XCTAssertEqual(h.nodes[0].status, .inProgress)
        XCTAssertEqual(Tree(h).mark("1"), .done)
    }

    func testInboxOps() {
        var p = small()
        let json = """
        {"from": "Claude", "ops": [
          {"op": "set_status", "id": "a", "status": "done"},
          {"op": "tick", "match": "polish"},
          {"op": "add", "parent_match": "Methods", "title": "Describe the solver", "status": "in_progress"},
          {"op": "add", "parent_match": "Methods", "title": "describe the solver"},
          {"op": "add", "parent_match": "Nowhere", "title": "Lost"},
          {"op": "note", "match": "Write it", "text": "Use the 2026 data"},
          {"op": "rename", "id": "c", "title": "Write methods"},
          {"op": "explode"}
        ]}
        """
        guard let file = InboxFile.parse(Data(json.utf8)) else { return XCTFail("did not parse") }
        let report = Inbox.apply(file, to: &p, now: t0)
        XCTAssertEqual(report.count, 8)
        let tree = Tree(p)
        XCTAssertEqual(tree.mark("s1"), .done)
        let added = tree.children(of: "s2").first { $0.title == "Describe the solver" }
        XCTAssertEqual(added?.status, .inProgress)
        XCTAssertEqual(tree.children(of: "s2").count, 2, "duplicate add is skipped")
        XCTAssertEqual(tree.byID["c"]?.note, "Use the 2026 data")
        XCTAssertEqual(tree.byID["c"]?.title, "Write methods")
        XCTAssertTrue(report.last?.contains("unknown") ?? false)
        XCTAssertNotNil(InboxFile.parse(Data(#"[{"op":"tick","id":"a"}]"#.utf8)))
    }

    func testGreenChristoffelTemplate() {
        let p = Templates.greenChristoffel(now: t0)
        let tree = Tree(p)
        XCTAssertEqual(tree.children(of: nil).count, 13)
        XCTAssertEqual(tree.leaves(under: nil).filter { $0.anchor?.hasPrefix("eq:") ?? false }.count, 39)
        XCTAssertEqual(tree.leaves(under: nil).filter { $0.anchor?.hasPrefix("fig:") ?? false }.count, 7)
        XCTAssertEqual(tree.leaves(under: nil).filter { $0.anchor?.hasPrefix("tab:") ?? false }.count, 2)
        XCTAssertEqual(tree.counts(nil).total, 97)
        XCTAssertEqual(tree.counts(nil).done, 1, "the corrected DOI flag starts done")
        XCTAssertEqual(Set(p.nodes.map(\.id)).count, p.nodes.count, "ids are unique")
        XCTAssertEqual(tree.byID["gc/eq:harmonic"]?.title, "Eq. (2) · Harmonic convention")
        XCTAssertEqual(tree.byID["gc/fig:source"]?.title, "Fig. 7 · Source and spectral dependence")
        XCTAssertEqual(tree.byID["gc/st-sign"]?.parentID, "gc/sec-formulation/review")
        XCTAssertEqual(Templates.greenChristoffel(now: t0), p, "deterministic, so two devices merge cleanly")
    }

    func testArticleTemplateAndMarkdown() {
        var p = Templates.article(title: "  Paper two ", id: "p2", now: t0)
        XCTAssertEqual(p.title, "Paper two")
        XCTAssertEqual(Tree(p).children(of: nil).count, 9)
        Edit.setStatus(&p, id: "p2/s1/1", to: .done, now: t0)
        Edit.setNote(&p, id: "p2/s1/2", note: "Keep it short", now: t0)
        let md = MarkdownExport.render(p, now: t0)
        XCTAssertTrue(md.contains("## [~] Abstract (1/4) `p2/s1`"))
        XCTAssertTrue(md.contains("- [x] Outline `p2/s1/1`"))
        XCTAssertTrue(md.contains("> Keep it short"))
        XCTAssertTrue(md.contains("Next up: First draft"))
    }
}
