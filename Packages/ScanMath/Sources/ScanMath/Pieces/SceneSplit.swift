import Foundation
import simd

/// One separate object found in a scan of several pieces lying on a table or in a dish.
public struct SceneComponent: Sendable {
    public var triangles: [SIMD3<Int>]
    public var area: Double
    public var lo: SIMD3<Double>
    public var hi: SIMD3<Double>
    public var centroid: SIMD3<Double>
    /// Enclosed volume when the surface is closed (m³), else nil.
    public var closedVolume: Double?
    public var maxExtent: Double { simd_length(hi - lo) }
    public var footprintCentre: SIMD2<Double> { SIMD2(centroid.x, centroid.z) }
}

public struct SceneSplit: Sendable {
    /// Big enough to match by shape (largest first).
    public var pieces: [SceneComponent]
    /// Measured and counted only: too small for their break surfaces to be resolved.
    public var small: [SceneComponent]
    /// Below the scan's resolution; only their number is known.
    public var specks: Int
    /// A dish or tray rim that was recognised and left out.
    public var containerRemoved: Bool
    /// Height of the table or dish floor (m, +Y up).
    public var floorY: Double
    public var resolution: Double
}

public enum SceneSplitter {
    /// Splits a scan into separate pieces: removes the table or dish floor, then takes connected parts of the mesh.
    /// - Parameters:
    ///   - matchSize: pieces at least this long (m) are matched by shape; default 6 mm or 12 mesh edges.
    ///   - minSize: smaller parts down to this are listed as small fragments; below it they are specks.
    public static func split(positions: [SIMD3<Double>], triangles: [SIMD3<Int>], matchSize: Double? = nil, minSize: Double? = nil) -> SceneSplit {
        guard !positions.isEmpty, !triangles.isEmpty else {
            return SceneSplit(pieces: [], small: [], specks: 0, containerRemoved: false, floorY: 0, resolution: 0)
        }
        // Mesh resolution: median edge length.
        var edges: [Double] = []
        for t in triangles.prefix(20_000) { edges.append(simd_length(positions[t.x] - positions[t.y])) }
        let res = Swift.max(1e-5, ScanMath.median(edges))
        let match = matchSize ?? Swift.max(0.006, 12 * res)
        let least = minSize ?? Swift.max(0.0015, 3 * res)

        // Floor: the lowest well-populated horizontal level of upward-facing surface.
        var upY: [Double] = []
        for t in triangles {
            let a = positions[t.x], b = positions[t.y], c = positions[t.z]
            let n = simd_cross(b - a, c - a)
            let l = simd_length(n)
            if l > 0 && n.y / l > 0.95 { upY.append((a.y + b.y + c.y) / 3) }
        }
        let ys = positions.map { $0.y }
        let minY = ys.min() ?? 0
        var floorY = minY
        if upY.count > 50 {
            let sorted = upY.sorted()
            let bin = Swift.max(res, 0.0005)
            // Densest bin among the lowest 40 % of up-facing triangles.
            var best = (count: 0, y: minY)
            let lowPart = sorted.prefix(Swift.max(10, sorted.count * 4 / 10))
            var j = 0
            let arr = Array(lowPart)
            for i in arr.indices {
                while arr[i] - arr[j] > bin { j += 1 }
                if i - j + 1 > best.count { best = (i - j + 1, arr[(i + j) / 2]) }
            }
            if Double(best.count) > 0.05 * Double(upY.count) { floorY = best.y }
        }
        let tol = Swift.max(2 * res, 0.001)
        // Only flat triangles at floor level go: the low sides of small grains stay.
        let kept = triangles.filter { t in
            let a = positions[t.x], b = positions[t.y], c = positions[t.z]
            guard Swift.max(a.y, Swift.max(b.y, c.y)) > floorY - tol else { return false }
            let atFloor = abs(a.y - floorY) < tol && abs(b.y - floorY) < tol && abs(c.y - floorY) < tol
            guard atFloor else { return true }
            let n = simd_cross(b - a, c - a)
            let l = simd_length(n)
            return l > 0 && abs(n.y) / l < 0.9
        }

        // Connected parts.
        var parent = Array(positions.indices)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var y = x
            while parent[y] != r { let n = parent[y]; parent[y] = r; y = n }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for t in kept {
            union(t.x, t.y)
            union(t.y, t.z)
        }
        var groups: [Int: [SIMD3<Int>]] = [:]
        for t in kept { groups[find(t.x), default: []].append(t) }

        var comps: [SceneComponent] = []
        for (_, tris) in groups {
            var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
            var area = 0.0, vol = 0.0
            var c = SIMD3<Double>.zero
            var edgeCount: [Int64: Int] = [:]
            for t in tris {
                let a = positions[t.x], b = positions[t.y], d = positions[t.z]
                lo = simd_min(lo, simd_min(a, simd_min(b, d)))
                hi = simd_max(hi, simd_max(a, simd_max(b, d)))
                let ar = simd_length(simd_cross(b - a, d - a)) / 2
                area += ar
                c += (a + b + d) / 3 * ar
                vol += simd_dot(a, simd_cross(b, d)) / 6
                for (u, v) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                    let k = Int64(Swift.min(u, v)) << 32 | Int64(Swift.max(u, v))
                    edgeCount[k, default: 0] += 1
                }
            }
            let closed = edgeCount.values.allSatisfy { $0 == 2 }
            comps.append(SceneComponent(triangles: tris, area: area, lo: lo, hi: hi, centroid: area > 0 ? c / area : (lo + hi) / 2,
                                        closedVolume: closed ? abs(vol) : nil))
        }

        // A dish or tray: a ring that surrounds other parts and is much wider than tall.
        var containerRemoved = false
        if comps.count >= 2, let big = comps.max(by: { ($0.hi.x - $0.lo.x) * ($0.hi.z - $0.lo.z) < ($1.hi.x - $1.lo.x) * ($1.hi.z - $1.lo.z) }) {
            let w = Swift.max(big.hi.x - big.lo.x, big.hi.z - big.lo.z)
            let inside = comps.filter { c in
                c.centroid.x > big.lo.x && c.centroid.x < big.hi.x && c.centroid.z > big.lo.z && c.centroid.z < big.hi.z && c.maxExtent < 0.6 * w
            }.count - 1
            let pts = big.triangles.prefix(3000).map { positions[$0.x] }
            let ctr = SIMD2((big.lo.x + big.hi.x) / 2, (big.lo.z + big.hi.z) / 2)
            let radial = pts.map { simd_length(SIMD2($0.x, $0.z) - ctr) }
            let meanR = radial.reduce(0, +) / Double(Swift.max(1, radial.count))
            let sd = (radial.map { ($0 - meanR) * ($0 - meanR) }.reduce(0, +) / Double(Swift.max(1, radial.count))).squareRoot()
            if inside >= 1 && sd < 0.12 * meanR && meanR > 0.3 * w {
                comps.removeAll { $0.triangles.count == big.triangles.count && $0.centroid == big.centroid }
                containerRemoved = true
            }
        }

        let sorted = comps.sorted { $0.area > $1.area }
        let pieces = sorted.filter { $0.maxExtent >= match }
        let small = sorted.filter { $0.maxExtent < match && $0.maxExtent >= least }
        let specks = sorted.filter { $0.maxExtent < least }.count
        return SceneSplit(pieces: pieces, small: small, specks: specks, containerRemoved: containerRemoved, floorY: floorY, resolution: res)
    }
}
