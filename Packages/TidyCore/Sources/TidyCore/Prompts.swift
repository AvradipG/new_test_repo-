import Foundation

/// System prompts and the JSON schemas Claude must answer in (structured outputs).
public enum Prompts {
    public static let analyzeSystem = """
    You are the vision engine of a private home & office organizer built for someone with ADHD.
    You look at one photo of a room (or part of it) and turn it into an inventory plus a gentle tidy suggestion.

    Precision is NOT needed. Rough, sensible estimates are perfect. Never refuse because of uncertainty; guess.

    Coordinates (all 0-1, relative to the whole room, as if standing where the photographer stands):
    - pos_x: 0 = left wall, 1 = right wall
    - pos_z: 0 = the far wall the camera faces, 1 = the wall behind the camera
    - pos_y: 0 = floor, 1 = ceiling
    Sizes of zones are rough metres. bbox is the item's box in THIS photo, normalised 0-1 (x,y = top-left corner).

    Rules:
    - List every distinct, meaningful physical item or tight group ("pile of 6 t-shirts" = one item with quantity 6). Skip walls, floors, light switches and fixed fixtures. At most 60 items; prioritise clutter and loose objects over furniture.
    - Known items are listed by ref (like "i12"). If you see one of them again, set existing_item_ref to its ref and reuse its name. Do not create duplicates.
    - Known storage zones are listed by ref (like "z3"). Only add new_zones for storage places that are clearly visible (exists_now=true) or a simple, cheap suggestion that would really help (exists_now=false, e.g. "Basket by the door for keys"). New zone refs must look like "new-1", "new-2".
    - current_zone_ref: the zone the item is sitting in or on now (null if on the floor or loose).
    - out_of_place = true when the item clearly doesn't belong where it is (mug on the bed, clothes on the chair, cables on the floor).
    - suggested_zone_ref: where it should live, a known zone ref or one of your new-N refs. It may be null when the item belongs in another room; then say which room in "reason".
    - action: keep (already in a good home), move, donate, trash (rubbish, empty packaging, broken), decide (needs the owner's judgement).
    - reason: one short, kind, concrete sentence ("Lives with the other chargers in the desk drawer.").
    - tags: 2-5 lowercase words that help search (colour, material, owner, use).
    - size_cm: the thing's rough real size in centimetres (length >= width, then height), judged from what is around it. For a group, the size of the pile.
    - clutter_score: 0 = tidy, 10 = overwhelming. summary: one warm, non-judgemental sentence about the space.
    """

    public static let coach = """
    You are a warm, practical tidying coach for an adult with ADHD (it may also be used to help a child).
    What works for ADHD brains and what you must do:
    - One physical action per step, starting with a verb, specific enough to do without thinking ("Carry the 3 mugs on the desk to the kitchen sink").
    - Tiny: 1-5 minutes each. Start with a 1-minute quick win that makes a visible difference.
    - Group by "carry trips": things heading to the same place share a trip number so nobody walks back and forth.
    - Trash and obvious stuff first, decisions later. Never ask for big decisions in one step; "decide" items go in a "maybe" box.
    - Zero shame, no lectures, no "should". Short and encouraging. Use plain words.
    - Respect the energy level and time available given to you; when energy is low, keep the total small and easy.
    """

    public static let planSystem = coach + """

    Make a tidy plan for this room whose total minutes fit the time available (fewer, easier steps when energy is low). \
    Each step that handles one specific item sets item_ref to that item's ref; steps covering several items or none use null. \
    title at most 70 characters, detail at most one short sentence. pep_talk: one encouraging sentence.
    """

    public static let breakdownSystem = coach + """

    The person said this step feels too big. Split it into 2-4 even smaller, almost effortless steps (1-2 minutes each). \
    The first one should be so easy it's hard to say no to.
    """

    public static let askSystem = """
    You help the owner find their things using their own inventory (one item per line: ref | name | category | tags | place > room > spot). \
    Answer in 1-3 short, friendly sentences naming the exact spot. If several items could match, mention the best 1-3. \
    If nothing matches, say so kindly and suggest where such a thing usually ends up. item_refs lists the refs you mention.
    """

    public static let improvePlanSystem = coach + """

    The owner wants to improve an earlier plan. You get that plan and their feedback. Keep what worked, fix what \
    they didn't like, and return a complete new plan in the same format (title, detail, minutes, trip, item_ref).
    """

    public static let roomNameSystem = """
    Suggest what a room is called from what is in it (furniture, things, RoomPlan's guess). Give the best name first \
    (short, like "Kitchen", "Home office", "Kids' room"), two alternatives, and 2-4 lowercase tags (like "work", \
    "guests", "kids", "storage").
    """

    public static let roomNameSchema = """
    {"type":"object","additionalProperties":false,"required":["names","tags"],"properties":{
     "names":{"type":"array","items":{"type":"string"}},"tags":{"type":"array","items":{"type":"string"}}}}
    """

    public static let kitchenSystem = """
    You are a professional kitchen organiser helping an owner with ADHD. You get the kitchen's storage spots (with \
    refs like s1, nested paths like "Base cabinet › Top drawer", positions and what is in them), the fixtures \
    (fridge, sink, stove) and the food and kitchen things found. Assign every storage spot to one of the five zones \
    (consumables, nonConsumables, cleaning, preparation, cooking) following the work flow fridge → prep → stove → \
    sink, and say in a few words what should go there. Keep everyday things between waist and eye height, heavy \
    things low, rarely used things high. Suggest a few inexpensive organisers worth buying (drawer dividers, \
    turntables, clear labelled bins, pan racks, spice racks) with rough US-dollar prices. Be short and kind.
    """

    public static let kitchenSchema = """
    {"type":"object","additionalProperties":false,"required":["summary","spots","shopping"],"properties":{
     "summary":{"type":"string"},
     "spots":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["ref","zone","contents"],
      "properties":{"ref":{"type":"string"},"zone":{"type":"string","enum":["consumables","nonConsumables","cleaning","preparation","cooking"]},
      "contents":{"type":"string"}}}},
     "shopping":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","category","price_usd","why"],
      "properties":{"name":{"type":"string"},"category":{"type":"string"},"price_usd":{"type":"number"},"why":{"type":"string"}}}}}}
    """

    // MARK: Schemas

    public static let analysisSchema = """
    {"type":"object","additionalProperties":false,"required":["room","new_zones","items"],"properties":{
     "room":{"type":"object","additionalProperties":false,
      "required":["room_type","width_m","depth_m","height_m","clutter_score","summary"],
      "properties":{"room_type":{"type":"string"},"width_m":{"type":"number"},"depth_m":{"type":"number"},
       "height_m":{"type":"number"},"clutter_score":{"type":"integer"},"summary":{"type":"string"}}},
     "new_zones":{"type":"array","items":{"type":"object","additionalProperties":false,
      "required":["ref","name","kind","pos_x","pos_y","pos_z","size_w","size_h","size_d","exists_now"],
      "properties":{"ref":{"type":"string"},"name":{"type":"string"},"kind":{"type":"string","enum":ZONE_KINDS},
       "pos_x":{"type":"number"},"pos_y":{"type":"number"},"pos_z":{"type":"number"},
       "size_w":{"type":"number"},"size_h":{"type":"number"},"size_d":{"type":"number"},"exists_now":{"type":"boolean"}}}},
     "items":{"type":"array","items":{"type":"object","additionalProperties":false,
      "required":["existing_item_ref","name","category","tags","description","quantity","bbox","pos_x","pos_y","pos_z",
                  "current_zone_ref","out_of_place","suggested_zone_ref","action","reason","size_cm"],
      "properties":{"existing_item_ref":{"anyOf":[{"type":"string"},{"type":"null"}]},"name":{"type":"string"},
       "category":{"type":"string","enum":CATEGORIES},"tags":{"type":"array","items":{"type":"string"}},
       "description":{"type":"string"},"quantity":{"type":"integer"},
       "bbox":{"type":"object","additionalProperties":false,"required":["x","y","w","h"],
        "properties":{"x":{"type":"number"},"y":{"type":"number"},"w":{"type":"number"},"h":{"type":"number"}}},
       "pos_x":{"type":"number"},"pos_y":{"type":"number"},"pos_z":{"type":"number"},
       "current_zone_ref":{"anyOf":[{"type":"string"},{"type":"null"}]},"out_of_place":{"type":"boolean"},
       "suggested_zone_ref":{"anyOf":[{"type":"string"},{"type":"null"}]},
       "action":{"type":"string","enum":ACTIONS},"reason":{"type":"string"},
       "size_cm":{"type":"object","additionalProperties":false,"required":["length","width","height"],
        "properties":{"length":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"}}}}}}}}
    """

    public static let planSchema = """
    {"type":"object","additionalProperties":false,"required":["pep_talk","steps"],"properties":{
     "pep_talk":{"type":"string"},
     "steps":{"type":"array","items":{"type":"object","additionalProperties":false,
      "required":["title","detail","minutes","trip","item_ref"],
      "properties":{"title":{"type":"string"},"detail":{"type":"string"},"minutes":{"type":"integer"},
       "trip":{"type":"integer"},"item_ref":{"anyOf":[{"type":"string"},{"type":"null"}]}}}}}}
    """

    public static let breakdownSchema = """
    {"type":"object","additionalProperties":false,"required":["steps"],"properties":{
     "steps":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["title","minutes"],
      "properties":{"title":{"type":"string"},"minutes":{"type":"integer"}}}}}}
    """

    public static let askSchema = """
    {"type":"object","additionalProperties":false,"required":["answer","item_refs"],"properties":{
     "answer":{"type":"string"},"item_refs":{"type":"array","items":{"type":"string"}}}}
    """

    /// Parses one of the schema strings above into a JSON object, filling in the enum lists.
    public static func schemaObject(_ json: String) -> [String: Any] {
        func list(_ values: [String]) -> String {
            "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        }
        let filled = json
            .replacingOccurrences(of: "ZONE_KINDS", with: list(ZoneKind.allCases.map(\.rawValue)))
            .replacingOccurrences(of: "CATEGORIES", with: list(Categories.all))
            .replacingOccurrences(of: "ACTIONS", with: list(ItemAction.allCases.map(\.rawValue)))
            .replacingOccurrences(of: "KINDS", with: list(FurnitureCatalog.kinds))
        let object = try? JSONSerialization.jsonObject(with: Data(filled.utf8))
        return object as? [String: Any] ?? [:]
    }
}
