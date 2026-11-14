import XCTest
@testable import TidyCore

final class MemoryTests: XCTestCase {
    func testSectionSplit() {
        let idx = SectionSplit.assign([(0, 0), (5, 0), (4.6, 1), (0.4, -1)], centers: [(0, 0), (5, 0)])
        XCTAssertEqual(idx, [0, 1, 1, 0])
        XCTAssertEqual(SectionSplit.assign([(1, 1)], centers: []), [0])
    }

    func testDigest() {
        let d0 = Date(timeIntervalSince1970: 1_800_000_000)
        let text = MemoryDigest.render(
            memories: [.init(date: d0, source: "owner", text: "Keys go on the hook"),
                       .init(date: d0.addingTimeInterval(86_400), source: "Claude", text: "Prefers short steps")],
            events: [.init(date: d0, source: "", text: "Put away: charger → Desk › Top drawer")])
        XCTAssertTrue(text.contains("Prefers short steps"))
        XCTAssertLessThan(text.range(of: "Prefers")!.lowerBound, text.range(of: "Keys")!.lowerBound, "newest first")
        XCTAssertTrue(text.contains("What happened recently"))
        XCTAssertEqual(MemoryDigest.render(memories: [], events: []), "")
    }

    func testBridgeLines() {
        let p = BridgeInbox.parse(BridgeInbox.template + """

        - SUGGEST: [Kitchen] Clear the counter — keep only the kettle out
        SUGGEST: Charging station - one place for all cables
        REMEMBER: The owner works from home on Fridays
        just a note
        """)
        XCTAssertEqual(p.suggestions.count, 2, "the template's example lines are inside the header, not real requests")
        XCTAssertEqual(p.suggestions[0].room, "Kitchen")
        XCTAssertEqual(p.suggestions[0].title, "Clear the counter")
        XCTAssertEqual(p.suggestions[0].detail, "keep only the kettle out")
        XCTAssertEqual(p.suggestions[1].title, "Charging station")
        XCTAssertEqual(p.remember, ["The owner works from home on Fridays"])
        XCTAssertNotEqual(BridgeInbox.key("a"), BridgeInbox.key("b"))
        XCTAssertEqual(BridgeInbox.key("Same"), BridgeInbox.key("same"))
    }

    func testBridgeJSON() {
        let p = BridgeInbox.parse(#"{"suggestions":[{"title":"Add a shoe rack","detail":"by the door","room":"Hallway"}],"remember":["Likes Japandi"]}"#)
        XCTAssertEqual(p.suggestions.first?.room, "Hallway")
        XCTAssertEqual(p.remember, ["Likes Japandi"])
    }

    func testSchemas() {
        XCTAssertFalse(Prompts.schemaObject(Assistant.schema).isEmpty)
        XCTAssertFalse(Prompts.schemaObject(Assistant.reviewSchema).isEmpty)
        let r = try? AIResults.decoder.decode(Assistant.Result.self, from: Data(#"{"reply":"It's in the drawer","action":"find","room_ref":null,"item_ref":"i3","text":"","remember":[]}"#.utf8))
        XCTAssertEqual(r?.itemRef, "i3")
    }
}
