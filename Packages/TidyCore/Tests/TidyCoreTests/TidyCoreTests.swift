import XCTest
@testable import TidyCore

final class TidyCoreTests: XCTestCase {
    let sampleJSON = """
    {"room":{"room_type":"bedroom","width_m":3.6,"depth_m":4.2,"height_m":2.5,"clutter_score":14,"summary":"Cosy room."},
     "new_zones":[{"ref":"new-1","name":"Basket by the door","kind":"bin","pos_x":0.9,"pos_y":0,"pos_z":0.95,
                   "size_w":0.4,"size_h":0.3,"size_d":0.3,"exists_now":false}],
     "items":[
      {"existing_item_ref":"i1","name":"Blue mug","category":"kitchen & dishes","tags":["Blue","blue","ceramic"],
       "description":"","quantity":1,"bbox":{"x":0.1,"y":0.2,"w":0.05,"h":0.06},"pos_x":0.2,"pos_y":0.4,"pos_z":0.3,
       "current_zone_ref":"z1","out_of_place":true,"suggested_zone_ref":null,"action":"move","reason":"Back to the kitchen."},
      {"existing_item_ref":"i1","name":"Blue mug","category":"kitchen & dishes","tags":[],"description":"","quantity":1,
       "bbox":{"x":0.1,"y":0.2,"w":0.05,"h":0.06},"pos_x":0.2,"pos_y":0.4,"pos_z":0.3,"current_zone_ref":null,
       "out_of_place":true,"suggested_zone_ref":null,"action":"move","reason":""},
      {"existing_item_ref":null,"name":"Keys","category":"weird category","tags":["metal"],"description":"House keys",
       "quantity":0,"bbox":{"x":1.4,"y":-0.2,"w":0,"h":2},"pos_x":2,"pos_y":0.1,"pos_z":0.9,"current_zone_ref":"zz9",
       "out_of_place":false,"suggested_zone_ref":"new-1","action":"keep","reason":"Hang them by the door.",
       "size_cm":{"length":3,"width":9,"height":-4}}]}
    """

    func testDecodeAndMerge() throws {
        let a = try AIResults.decoder.decode(PhotoAnalysis.self, from: Data(sampleJSON.utf8))
        let mug = UUID(), desk = UUID()
        let plan = MergePlanner.plan(a, knownItems: ["i1": mug], knownZones: ["z1": desk])

        XCTAssertEqual(plan.clutterScore, 10, "clutter is clamped to 0...10")
        XCTAssertEqual(plan.newZones.count, 1)
        XCTAssertTrue(plan.newZones[0].isIdea)
        XCTAssertEqual(plan.newZones[0].kind, .bin)
        XCTAssertEqual(plan.updateCount, 1, "a re-sighted item is updated once")
        XCTAssertEqual(plan.insertCount, 2, "a second claim on the same ref becomes a new item")

        guard case let .update(id, first) = plan.ops[0] else { return XCTFail("first op should update") }
        XCTAssertEqual(id, mug)
        XCTAssertEqual(first.tags, ["blue", "ceramic"], "tags are lowercased and de-duplicated")
        XCTAssertEqual(first.currentZone, .existing(desk))

        guard case let .insert(keys) = plan.ops[2] else { return XCTFail("keys should be inserted") }
        XCTAssertEqual(keys.category, "other")
        XCTAssertEqual(keys.quantity, 1)
        XCTAssertEqual(keys.position.x, 1)
        XCTAssertEqual(keys.bbox.x, 1)
        XCTAssertEqual(keys.bbox.w, 0.01)
        XCTAssertEqual(keys.currentZone, .none, "unknown refs are dropped")
        XCTAssertEqual(keys.suggestedZone, .new("new-1"))
        XCTAssertTrue(keys.startsSorted)
        XCTAssertEqual(keys.sizeEstimate?.length, 9, "length is the longer side")
        XCTAssertEqual(keys.sizeEstimate?.width, 3)
        XCTAssertEqual(keys.sizeEstimate?.height, 0.5, "sizes are clamped")
        XCTAssertNil(first.sizeEstimate, "older answers without size_cm still decode")
    }

    func testSchemasParse() {
        for s in [Prompts.analysisSchema, Prompts.planSchema, Prompts.breakdownSchema, Prompts.askSchema] {
            XCTAssertFalse(Prompts.schemaObject(s).isEmpty)
        }
        let a = Prompts.schemaObject(Prompts.analysisSchema)
        let items = ((a["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"] as? [String: Any]
        let category = (items?["properties"] as? [String: Any])?["category"] as? [String: Any]
        XCTAssertEqual((category?["enum"] as? [String])?.count, Categories.all.count)
    }

    func testRequestBody() throws {
        let data = try ClaudeWire.body(system: "s", content: [ClaudeWire.textBlock("hi")],
                                       schema: Prompts.schemaObject(Prompts.askSchema), effort: .low)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(o["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(o["fallbacks"] as? String, "default")
        let cfg = try XCTUnwrap(o["output_config"] as? [String: Any])
        XCTAssertEqual(cfg["effort"] as? String, "low")
        XCTAssertEqual((cfg["format"] as? [String: Any])?["type"] as? String, "json_schema")
    }

    func testResponseParsing() throws {
        let ok = #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"answer\":\"In the drawer\",\"item_refs\":[\"i2\"]}"}]}"#
        let r = try ClaudeWire.decode(AskResult.self, status: 200, data: Data(ok.utf8))
        XCTAssertEqual(r.itemRefs, ["i2"])

        let refusal = #"{"stop_reason":"refusal","content":[]}"#
        XCTAssertThrowsError(try ClaudeWire.decode(AskResult.self, status: 200, data: Data(refusal.utf8))) {
            XCTAssertEqual($0 as? ClaudeWire.Failure, .refused)
        }
        XCTAssertThrowsError(try ClaudeWire.decode(AskResult.self, status: 401, data: Data("{}".utf8))) {
            XCTAssertEqual($0 as? ClaudeWire.Failure, .badKey)
        }
    }

    func testStreak() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        XCTAssertEqual(Streak.days(completions: [], now: now, calendar: cal), 0)
        XCTAssertEqual(Streak.days(completions: [now - day, now - 2 * day], now: now, calendar: cal), 2,
                       "a streak survives until the end of today")
        XCTAssertEqual(Streak.days(completions: [now, now - day, now - 3 * day], now: now, calendar: cal), 2)
        XCTAssertEqual(Streak.doneToday(completions: [now, now, now - day], now: now, calendar: cal), 2)
    }

    func testCropStaysInside() {
        let r = CropMath.rect(for: PhotoBox(x: 0.95, y: 0.9, w: 0.1, h: 0.2), imageWidth: 1000, imageHeight: 800)
        XCTAssertGreaterThanOrEqual(r.x, 0)
        XCTAssertLessThanOrEqual(r.x + r.width, 1000.0001)
        XCTAssertLessThanOrEqual(r.y + r.height, 800.0001)
        XCTAssertEqual(r.width, r.height, accuracy: 0.001, "thumbnails are square")
    }

    func testRoomLayout() throws {
        // A 4 m x 3 m room whose corner sits at (10, 0, 20), walls 2.5 m high.
        let walls = [
            WorldBox(cx: 12, cy: 1.25, cz: 20, width: 4, height: 2.5, depth: 0, yaw: 0, label: "wall"),
            WorldBox(cx: 12, cy: 1.25, cz: 23, width: 4, height: 2.5, depth: 0, yaw: 0, label: "wall"),
            WorldBox(cx: 10, cy: 1.25, cz: 21.5, width: 3, height: 2.5, depth: 0, yaw: .pi / 2, label: "wall"),
            WorldBox(cx: 14, cy: 1.25, cz: 21.5, width: 3, height: 2.5, depth: 0, yaw: .pi / 2, label: "wall"),
        ]
        let bed = WorldBox(cx: 13, cy: 0.3, cz: 22, width: 1.6, height: 0.6, depth: 2, yaw: 0, label: "bed")
        let layout = try XCTUnwrap(RoomLayout.from(walls: walls, objects: [bed]))
        XCTAssertEqual(layout.widthM, 4, accuracy: 0.01)
        XCTAssertEqual(layout.depthM, 3, accuracy: 0.01)
        XCTAssertEqual(layout.heightM, 2.5, accuracy: 0.01)
        XCTAssertEqual(layout.originX ?? 0, 12, accuracy: 0.01, "the room's place in the shared scan is kept")
        XCTAssertEqual(layout.originZ ?? 0, 21.5, accuracy: 0.01)
        let old = try JSONDecoder().decode(RoomLayout.self, from: Data(#"{"walls":[],"objects":[],"widthM":3,"depthM":4,"heightM":2.5}"#.utf8))
        XCTAssertNil(old.originX, "layouts saved before whole-place scans still load")
        let b = layout.objects[0]
        XCTAssertEqual(b.cx, 1, accuracy: 0.01)
        XCTAssertEqual(b.cz, 0.5, accuracy: 0.01)
        let u = layout.unit(x: b.cx, y: 0, z: b.cz)
        XCTAssertEqual(u.x, 0.75, accuracy: 0.01)
        XCTAssertEqual(RoomLayout.zoneSuggestion(forLabel: "bed")?.kind, .bed)
        XCTAssertNil(RoomLayout.zoneSuggestion(forLabel: "television"))
    }

    func testInventoryText() {
        let t = InventoryText.render([
            .init(ref: "i1", name: "Passport", category: "papers & documents", tags: ["travel"], place: "Home",
                  room: "Office", spot: "Top drawer", notPutAway: false),
        ])
        XCTAssertEqual(t, "i1 | Passport | papers & documents | travel | Home > Office > Top drawer")
    }
}
