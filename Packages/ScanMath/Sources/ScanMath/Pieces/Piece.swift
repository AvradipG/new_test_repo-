import Foundation
import simd

/// One broken piece as the matcher sees it: evenly spaced surface samples with outward normals, how likely each
/// sample is to lie on a break (rather than on the original outside of the sample), facets of break surface, and
/// interior samples for the "no overlap" test. Coordinates are metres in the frame of the first scan.
public final class Piece {
    public struct Facet: Sendable {
        public var members: [Int]
        public var area: Double
        public var centroid: SIMD3<Double>
        public var normal: SIMD3<Double>
        /// A whole break surface (grown loosely) rather than one facet of it.
        public var coarse: Bool = false
    }

    public let id: Int
    public let points: [SIMD3<Double>]
    public let normals: [SIMD3<Double>]
    /// Sample spacing (metres): the resolution everything else is measured against.
    public let spacing: Double
    public let areaPerPoint: Double
    public let tree: KDTree
    public internal(set) var fracture: [Double]
    public internal(set) var facets: [Facet] = []
    public internal(set) var interior: [SIMD3<Double>] = []
    public let lo: SIMD3<Double>
    public let hi: SIMD3<Double>
    public let centroid: SIMD3<Double>
    public let radius: Double
    /// Enclosed volume (m³), from the closed mesh when there is one, else from a voxel estimate.
    public var volume: Double

    public var surfaceArea: Double { areaPerPoint * Double(points.count) }
    public var maxExtent: Double { simd_length(hi - lo) }

    public init(id: Int, points: [SIMD3<Double>], normals: [SIMD3<Double>], spacing: Double, area: Double? = nil, volume: Double? = nil) {
        self.id = id
        self.points = points
        self.normals = normals.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
        self.spacing = spacing
        areaPerPoint = (area ?? spacing * spacing * Double(points.count)) / Double(Swift.max(1, points.count))
        tree = KDTree(points)
        fracture = [Double](repeating: 0.5, count: points.count)
        var mn = SIMD3<Double>(repeating: .infinity), mx = SIMD3<Double>(repeating: -.infinity)
        for p in points {
            mn = simd_min(mn, p)
            mx = simd_max(mx, p)
        }
        lo = mn
        hi = mx
        let c = points.centroid
        centroid = c
        radius = points.map { simd_length($0 - c) }.max() ?? 0
        self.volume = volume ?? 0
        buildInterior()
        if volume == nil || volume! <= 0 { self.volume = voxelVolume() }
    }

    // MARK: Sampling a mesh

    /// Evenly spread samples on triangles (area-weighted, deterministic), with face normals.
    public static func sample(positions: [SIMD3<Double>], triangles: [SIMD3<Int>], spacing: Double,
                              maxPoints: Int = 3000, seed: UInt64 = 1) -> (points: [SIMD3<Double>], normals: [SIMD3<Double>], area: Double) {
        var areas: [Double] = []
        var normals: [SIMD3<Double>] = []
        areas.reserveCapacity(triangles.count)
        for t in triangles {
            let a = positions[t.x], b = positions[t.y], c = positions[t.z]
            let n = simd_cross(b - a, c - a)
            let l = simd_length(n)
            areas.append(l / 2)
            normals.append(l > 0 ? n / l : SIMD3(0, 1, 0))
        }
        let total = areas.reduce(0, +)
        guard total > 0 else { return ([], [], 0) }
        let want = Swift.max(50, Swift.min(maxPoints, Int(total / (spacing * spacing))))
        var rng = SplitMix64(seed: seed)
        var pts: [SIMD3<Double>] = [], nrm: [SIMD3<Double>] = []
        pts.reserveCapacity(want + triangles.count / 10)
        // Systematic sampling along the cumulative area: even coverage with no clumps.
        let step = total / Double(want)
        var next = rng.unit() * step
        var acc = 0.0
        for (k, t) in triangles.enumerated() {
            let a = areas[k]
            while next < acc + a {
                var u = rng.unit(), v = rng.unit()
                if u + v > 1 { u = 1 - u; v = 1 - v }
                let p0 = positions[t.x], p1 = positions[t.y], p2 = positions[t.z]
                let e1: SIMD3<Double> = (p1 - p0) * u
                let e2: SIMD3<Double> = (p2 - p0) * v
                pts.append(p0 + e1 + e2)
                nrm.append(normals[k])
                next += step
            }
            acc += a
        }
        return (pts, nrm, total)
    }

    // MARK: Inside test and volume

    /// Signed distance to the sampled surface (negative inside), using the nearest sample's normal.
    public func signedDistance(_ q: SIMD3<Double>) -> Double {
        guard let n = tree.nearest(q) else { return .infinity }
        return simd_dot(q - points[n.index], normals[n.index])
    }

    private func buildInterior() {
        var out: [SIMD3<Double>] = []
        for i in spreadIndices(points.count, want: 500) {
            for depth in [2.0, 4.0] {
                let q = points[i] - normals[i] * spacing * depth
                guard let n = tree.nearest(q), n.distance > spacing * depth * 0.6 else { continue }
                if simd_dot(q - points[n.index], normals[n.index]) < 0 { out.append(q) }
            }
        }
        interior = out
    }

    private func voxelVolume() -> Double {
        let ext = hi - lo
        let cell = Swift.max(spacing, Swift.max(ext.x, Swift.max(ext.y, ext.z)) / 40)
        guard cell > 0 else { return 0 }
        let nx = Int(ext.x / cell) + 1, ny = Int(ext.y / cell) + 1, nz = Int(ext.z / cell) + 1
        var inside = 0
        for i in 0..<nx { for j in 0..<ny { for k in 0..<nz {
            let idx = SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5)
            let q: SIMD3<Double> = lo + idx * cell
            if signedDistance(q) < 0 { inside += 1 }
        } } }
        return Double(inside) * cell * cell * cell
    }

    // MARK: Break or outside?

    /// Local roughness: 1 − |mean normal| over neighbours within `r` (0 on a flat or gently curved face).
    func roughness(radius r: Double) -> [Double] {
        points.indices.map { i in
            let nb = tree.within(points[i], radius: r)
            guard nb.count >= 4 else { return 0 }
            var s = SIMD3<Double>.zero
            for j in nb { s += normals[j] }
            return 1 - simd_length(s) / Double(nb.count)
        }
    }

    /// Sets `fracture` from local roughness and large flat faces (saw cuts are smooth and flat, breaks are not).
    /// `exterior` marks samples known to lie on the original outside (from the target shape); they get 0.05.
    func classify(roughness rough: [Double], lowQuantile: Double, highQuantile: Double, exterior: [Bool]?) {
        var f = rough.map { r -> Double in
            let span: Double = Swift.max(1e-9, highQuantile - lowQuantile)
            let x: Double = (r - lowQuantile) / span
            let c: Double = Swift.max(0, Swift.min(1, x))
            return 0.3 + 0.7 * c
        }
        // Large flat faces: almost certainly cut or polished surfaces, not breaks.
        for facet in Self.regionGrow(self, members: Array(points.indices), maxAngle: 8, planeTolerance: 0.4 * spacing)
            where facet.area > 0.12 * surfaceArea {
            for i in facet.members { f[i] = Swift.min(f[i], 0.1) }
        }
        if let e = exterior {
            for i in f.indices where e[i] { f[i] = 0.05 }
        }
        fracture = f
    }

    /// Whole break surfaces first (each break of a core is one), then facets of them, largest first.
    func buildFacets(limit: Int = 6) {
        var members = points.indices.filter { fracture[$0] > 0.5 }
        if members.count < 40 { members = Array(points.indices) }
        var whole = Self.regionGrow(self, members: members, maxAngle: 70, planeTolerance: nil)
            .filter { $0.members.count >= 30 }
            .sorted { $0.area > $1.area }
        for k in whole.indices { whole[k].coarse = true }
        let found = Self.regionGrow(self, members: members, maxAngle: 28, planeTolerance: nil)
            .filter { $0.members.count >= 12 }
            .sorted { $0.area > $1.area }
        facets = Array(whole.prefix(3)) + Array(found.prefix(limit))
    }

    /// Groups neighbouring samples with similar normals.
    static func regionGrow(_ p: Piece, members: [Int], maxAngle: Double, planeTolerance: Double?) -> [Facet] {
        let allowed = Set(members)
        var done = Set<Int>()
        let cosMax = cos(maxAngle * .pi / 180)
        var out: [Facet] = []
        let r = 2.2 * p.spacing
        for seed in members where !done.contains(seed) {
            var region = [seed]
            done.insert(seed)
            var sumN = p.normals[seed], sumP = p.points[seed]
            var head = 0
            while head < region.count {
                let i = region[head]
                head += 1
                let mean = simd_normalize(sumN)
                let c = sumP / Double(region.count)
                for j in p.tree.within(p.points[i], radius: r) where allowed.contains(j) && !done.contains(j) {
                    guard simd_dot(p.normals[j], mean) >= cosMax else { continue }
                    if let tol = planeTolerance, region.count > 8, abs(simd_dot(p.points[j] - c, mean)) > tol { continue }
                    done.insert(j)
                    region.append(j)
                    sumN += p.normals[j]
                    sumP += p.points[j]
                }
            }
            let l = simd_length(sumN)
            out.append(Facet(members: region, area: Double(region.count) * p.areaPerPoint,
                             centroid: sumP / Double(region.count), normal: l > 0 ? sumN / l : p.normals[seed]))
        }
        return out
    }
}
