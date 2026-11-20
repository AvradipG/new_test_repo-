import Foundation
import simd

/// The end a core stood on (3.20). The camera never sees the face resting on the table, so photogrammetry closes
/// the model there with a guess: often a shallow dish set a few millimetres up inside the core, which makes the
/// model look like a cup and takes volume off (Adnoc Sample 5: 2.3–3.5 mm up, about 5 % of the volume).
/// A core standing on its end has that face on the table, so the fill is flat, in the table's plane.
public struct BottomFillPlan: Codable, Equatable, Sendable {
    /// The table: the lowest point of the model (model units, metres).
    public var floorY: Double
    /// The model is cut here and the outline at this height carried straight down to the table.
    public var cutY: Double
    /// How far the guessed bottom sat above the table, in model units.
    public var recess: Double
    /// Radius of the side used to tell the end face from the side.
    public var radius: Double
    /// Share of the end face (by area) that photogrammetry put above the table.
    public var hollowShare: Double

    public init(floorY: Double, cutY: Double, recess: Double, radius: Double, hollowShare: Double) {
        self.floorY = floorY
        self.cutY = cutY
        self.recess = recess
        self.radius = radius
        self.hollowShare = hollowShare
    }
}

public enum BottomFill {
    /// Finds a hollow, guessed bottom on a model standing on +Y (the table at its lowest point). Nil when the
    /// bottom is already flat on the table, or the shape doesn't stand on a flat end.
    /// - Parameters:
    ///   - minRecess: smaller hollows are left alone (model units; 0.8 mm).
    ///   - maxShare: the cut never goes higher than this share of the height.
    public static func find(positions: [SIMD3<Float>], indices: [UInt32],
                            minRecess: Double = 0.0008, maxShare: Double = 0.2) -> BottomFillPlan? {
        guard positions.count >= 20, indices.count >= 36 else { return nil }
        var minY = Double.infinity, maxY = -Double.infinity
        for p in positions {
            minY = Swift.min(minY, Double(p.y))
            maxY = Swift.max(maxY, Double(p.y))
        }
        let height = maxY - minY
        guard height > 0 else { return nil }

        // The side between a quarter and three quarters of the height gives the axis and the radius.
        let lo = minY + 0.25 * height, hi = minY + 0.75 * height
        var cx = 0.0, cz = 0.0, n = 0.0
        for p in positions where Double(p.y) > lo && Double(p.y) < hi {
            cx += Double(p.x)
            cz += Double(p.z)
            n += 1
        }
        guard n >= 12 else { return nil }
        cx /= n
        cz /= n
        var radii: [Double] = []
        for p in positions where Double(p.y) > lo && Double(p.y) < hi {
            let dx = Double(p.x) - cx, dz = Double(p.z) - cz
            radii.append((dx * dx + dz * dz).squareRoot())
        }
        let R = ScanMath.median(radii)
        guard R > 0 else { return nil }
        func radius(_ p: SIMD3<Double>) -> Double {
            let dx = p.x - cx, dz = p.z - cz
            return (dx * dx + dz * dz).squareRoot()
        }

        // The end face: triangles in the bottom part, inside the side, facing down.
        let band = minY + maxShare * height
        var faceArea = 0.0, raisedArea = 0.0
        var raised: [(y: Double, area: Double)] = []
        var top = -Double.infinity
        var k = 0
        while k + 2 < indices.count {
            let a = SIMD3<Double>(positions[Int(indices[k])])
            let b = SIMD3<Double>(positions[Int(indices[k + 1])])
            let c = SIMD3<Double>(positions[Int(indices[k + 2])])
            k += 3
            let mid = (a + b + c) / 3
            guard mid.y < band, radius(mid) < 0.8 * R else { continue }
            let cr = simd_cross(b - a, c - a)
            let area = simd_length(cr) / 2
            guard area > 0, cr.y / (2 * area) < -0.5 else { continue }
            faceArea += area
            if mid.y - minY > minRecess / 2 {
                raisedArea += area
                raised.append((mid.y, area))
                top = Swift.max(top, a.y, b.y, c.y)
            }
        }
        guard faceArea > 0, raisedArea / faceArea >= 0.5 else { return nil }
        // Area-weighted median height of the guessed bottom above the table.
        raised.sort { $0.y < $1.y }
        var acc = 0.0
        var capY = raised.last!.y
        for r in raised {
            acc += r.area
            if acc >= raisedArea / 2 { capY = r.y; break }
        }
        let recess = capY - minY
        guard recess >= minRecess else { return nil }

        // The side has to come down to the table round the hollow (a cup); a body that is raised all over
        // (standing on something) is another matter.
        var rimLow = Double.infinity
        for p in positions {
            let q = SIMD3<Double>(p)
            let r = radius(q)
            if r > 0.9 * R && r < 1.15 * R { rimLow = Swift.min(rimLow, q.y) }
        }
        guard rimLow - minY < 0.5 * recess else { return nil }

        let cutY = Swift.min(top + 0.0002, band)
        guard cutY > minY else { return nil }
        return BottomFillPlan(floorY: minY, cutY: cutY, recess: recess, radius: R, hollowShare: raisedArea / faceArea)
    }

    /// The model with its guessed bottom replaced: cut at `cutY`, and the cut outline with its flat cap moved
    /// down to the table, so the side runs straight down to a flat end.
    public static func apply(positions: [SIMD3<Float>], indices: [UInt32], plan: BottomFillPlan)
        -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        let y = Float(plan.cutY), floor = Float(plan.floorY)
        var cut = MeshCut.above(positions: positions, indices: indices, y: y)
        guard cut.indices.count >= 12 else { return (positions, indices) }
        for i in cut.positions.indices where cut.positions[i].y == y {
            cut.positions[i].y = floor
        }
        return cut
    }
}
