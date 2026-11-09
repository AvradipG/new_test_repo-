import Foundation

/// The AI interior designer: what it is told, the JSON it must answer with, and how its layouts are applied.
public enum DesignAI {
    public static let system = """
    You are a warm, practical interior designer and home organiser inside a private iPhone app. The owner has ADHD: \
    designs must be calm, easy to keep tidy and give every category of thing an obvious home. You also know Feng Shui \
    and Vastu Shastra well and use them when the owner asks (or lightly, as a bonus, when they fit).

    You get the room as JSON: size in metres, doors and windows, the compass direction of each wall when known, and \
    every piece with a ref (p1, p2…), kind, size, position and rotation. Coordinates: x from -width/2 (left wall) to \
    +width/2 (right wall), z from -depth/2 (far wall) to +depth/2 (near wall), metres from the middle of the floor; \
    rotation in degrees clockwise seen from above (0 = the piece's front faces the near wall). Wall pieces (art, \
    mirror, shelves, TV, curtains, hooks) go flat on a wall: give the x,z of the spot on that wall and y = height of \
    their middle.

    Answer in "reply" like a person: short paragraphs, concrete, kind, no lectures. When the owner wants a layout, a \
    theme, furniture or decor ideas, or asks where something should go, ALSO give a "proposal": moves of existing \
    pieces (by ref), additions (catalog kind, or "custom" with a name and size), and removals. Keep at least 60-90 cm \
    walkways, never block doors or windows, keep pieces fully inside the room, and don't move fixed things (sink, \
    toilet, bathtub, fireplace, stairs, stove). Give scores 0-10 for flow, light, calm, function and overall. \
    When asked which design is better, fill "ranking" (best first) using the design refs given (d1, d2…). \
    Otherwise proposal is null and ranking is empty.
    """ + "\n\n" + SpaceWisdom.principles

    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["reply","proposal","ranking"],"properties":{
     "reply":{"type":"string"},
     "proposal":{"anyOf":[{"type":"null"},{"type":"object","additionalProperties":false,
      "required":["title","style","rationale","moves","additions","removals","tips","scores"],"properties":{
       "title":{"type":"string"},"style":{"type":"string"},"rationale":{"type":"string"},
       "moves":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["piece_ref","x","z","rotation_deg"],"properties":{"piece_ref":{"type":"string"},
        "x":{"type":"number"},"z":{"type":"number"},"rotation_deg":{"type":"number"}}}},
       "additions":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["kind","name","x","z","y","rotation_deg","width","depth","height","why"],"properties":{
        "kind":{"type":"string","enum":KINDS},"name":{"type":"string"},"x":{"type":"number"},"z":{"type":"number"},
        "y":{"type":"number"},"rotation_deg":{"type":"number"},"width":{"type":"number"},"depth":{"type":"number"},
        "height":{"type":"number"},"why":{"type":"string"}}}},
       "removals":{"type":"array","items":{"type":"string"}},
       "tips":{"type":"array","items":{"type":"string"}},
       "scores":{"type":"object","additionalProperties":false,"required":["flow","light","calm","function","overall"],
        "properties":{"flow":{"type":"number"},"light":{"type":"number"},"calm":{"type":"number"},
        "function":{"type":"number"},"overall":{"type":"number"}}}}}]},
     "ranking":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["design_ref","score","why"],
      "properties":{"design_ref":{"type":"string"},"score":{"type":"number"},"why":{"type":"string"}}}}}}
    """

    public static func schemaObject() -> [String: Any] {
        let kinds = "[" + FurnitureCatalog.kinds.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let filled = schema.replacingOccurrences(of: "KINDS", with: kinds)
        return (try? JSONSerialization.jsonObject(with: Data(filled.utf8))) as? [String: Any] ?? [:]
    }

    public struct Answer: Codable, Equatable, Sendable {
        public var reply: String
        public var proposal: Proposal?
        public var ranking: [Rank]
    }

    public struct Proposal: Codable, Equatable, Sendable {
        public var title: String
        public var style: String
        public var rationale: String
        public var moves: [Move]
        public var additions: [Addition]
        public var removals: [String]
        public var tips: [String]
        public var scores: Scores
    }

    public struct Move: Codable, Equatable, Sendable {
        public var pieceRef: String
        public var x: Double
        public var z: Double
        public var rotationDeg: Double
    }

    public struct Addition: Codable, Equatable, Sendable {
        public var kind: String
        public var name: String
        public var x: Double
        public var z: Double
        public var y: Double
        public var rotationDeg: Double
        public var width: Double
        public var depth: Double
        public var height: Double
        public var why: String
    }

    public struct Scores: Codable, Equatable, Sendable {
        public var flow: Double
        public var light: Double
        public var calm: Double
        public var function: Double
        public var overall: Double
    }

    public struct Rank: Codable, Equatable, Sendable {
        public var designRef: String
        public var score: Double
        public var why: String
    }

    /// Short refs for the pieces sent to the AI ("p1", "p2"…), in order.
    public static func refs(_ pieces: [DesignPiece]) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: pieces.enumerated().map { ("p\($0.offset + 1)", $0.element.id) })
    }

    /// The room and its pieces as the JSON the designer reads.
    public static func roomContext(name: String, width: Double, depth: Double, height: Double, bearing: Double?,
                                   openings: [WorldBox], pieces: [DesignPiece]) -> [String: Any] {
        var walls: [String: Any] = [:]
        if let b = bearing {
            walls = ["far_wall": GeoMath.compassName(b), "right_wall": GeoMath.compassName(b + 90),
                     "near_wall": GeoMath.compassName(b + 180), "left_wall": GeoMath.compassName(b + 270)]
        }
        let r = (width * 100).rounded() / 100, d = (depth * 100).rounded() / 100
        func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        return [
            "room": name, "width_m": r, "depth_m": d, "height_m": round2(height),
            "walls_face": walls.isEmpty ? ("unknown" as Any) : (walls as Any),
            "doors_and_windows": openings.map { ["type": $0.label, "x": round2($0.cx), "z": round2($0.cz), "width_m": round2($0.width)] as [String: Any] },
            "pieces": pieces.enumerated().map { n, p -> [String: Any] in
                var e: [String: Any] = ["ref": "p\(n + 1)", "kind": p.kind, "name": p.name, "x": round2(p.x), "z": round2(p.z),
                                        "width_m": round2(p.width), "depth_m": round2(p.depth), "height_m": round2(p.height),
                                        "rotation_deg": round2(p.rotationDeg), "on_wall": p.onWall,
                                        "fixed": FurnitureCatalog.isFixed(p.kind)]
                if p.onWall { e["y"] = round2(p.y) }
                if let b = bearing { e["direction"] = SpaceWisdom.direction(x: p.x, z: p.z, bearing: b) }
                return e
            },
        ]
    }

    /// A new set of pieces with the proposal applied, everything kept inside the room.
    public static func apply(_ p: Proposal, to pieces: [DesignPiece], width: Double, depth: Double) -> [DesignPiece] {
        let refMap = refs(pieces)
        let removed = Set(p.removals.compactMap { refMap[$0] })
        var out = pieces.filter { !removed.contains($0.id) || FurnitureCatalog.isFixed($0.kind) }
        for m in p.moves {
            guard let id = refMap[m.pieceRef], let i = out.firstIndex(where: { $0.id == id }), !FurnitureCatalog.isFixed(out[i].kind),
                  m.x.isFinite, m.z.isFinite else { continue }
            out[i].x = m.x
            out[i].z = m.z
            out[i].rotationDeg = GeoMath.normalize(m.rotationDeg.isFinite ? m.rotationDeg : out[i].rotationDeg)
            out[i] = DesignGeometry.clamp(out[i], width: width, depth: depth)
        }
        for a in p.additions.prefix(20) {
            let cat = FurnitureCatalog.item(a.kind)
            let onWall = cat?.onWall ?? false
            let size = { (v: Double, fallback: Double?) -> Double in
                v.isFinite && v > 0.01 && v < 8 ? v : (fallback ?? 0.6)
            }
            var piece = DesignPiece(kind: a.kind, name: Clamp.text(a.name.isEmpty ? (cat?.name ?? "New piece") : a.name, 60),
                                    x: a.x.isFinite ? a.x : 0, z: a.z.isFinite ? a.z : 0,
                                    y: onWall ? (a.y.isFinite && a.y > 0.1 ? a.y : FurnitureCatalog.wallHeight(a.kind)) : 0,
                                    width: size(a.width, cat?.width), depth: size(a.depth, cat?.depth), height: size(a.height, cat?.height),
                                    rotationDeg: a.rotationDeg.isFinite ? GeoMath.normalize(a.rotationDeg) : 0,
                                    onWall: onWall, source: "ai", note: Clamp.text(a.why, 200))
            piece = DesignGeometry.clamp(piece, width: width, depth: depth)
            out.append(piece)
        }
        return out
    }
}
