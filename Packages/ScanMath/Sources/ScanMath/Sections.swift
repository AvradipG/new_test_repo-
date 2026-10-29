import Foundation

/// Principal axes of a mesh: `axes[0]` is a (longest), `axes[1]` b, `axes[2]` c (shortest).
/// `lo`/`hi` are the extremes of the points measured along each axis from `center`.
public struct PrincipalFrame: Sendable {
    public var center: SIMD3<Double>
    public var axes: [SIMD3<Double>]
    public var lo: SIMD3<Double>
    public var hi: SIMD3<Double>
    public var extents: SIMD3<Double> { hi - lo }

    /// In-plane axes for a section cut across `axis`: (u, v) = the next two axes in a-b-c order.
    public func planeAxes(_ axis: Int) -> (u: Int, v: Int) {
        switch axis {
        case 0: return (1, 2)
        case 1: return (0, 2)
        default: return (0, 1)
        }
    }
}

/// One planar cross-section through the mesh. Coordinates are in mesh units, measured
/// in the plane from the frame centre along the frame's other two axes.
public struct CrossSection: Sendable {
    public var axis: Int
    /// Position of the plane along the axis, measured from the rock's end (frame `lo`).
    public var depth: Double
    public var loops: [[SIMD2<Double>]]
    public var openChains: [[SIMD2<Double>]]
    /// Enclosed area with holes subtracted (even-odd nesting).
    public var area: Double
    public var perimeter: Double
    public var equivalentDiameter: Double { (4 * area / Double.pi).squareRoot() }
}

extension ScanMath {
    /// Cuts the mesh with planes across `axis` every `spacing` units, starting half a step in from the end.
    public static func crossSections(positions: [SIMD3<Float>], indices: [UInt32], frame: PrincipalFrame,
                                     axis: Int, spacing: Double) -> [CrossSection] {
        guard spacing > 0, axis >= 0, axis < 3 else { return [] }
        let lo = frame.lo[axis], hi = frame.hi[axis]
        var out: [CrossSection] = []
        var t = lo + spacing / 2
        while t < hi {
            out.append(crossSection(positions: positions, indices: indices, frame: frame, axis: axis, at: t))
            t += spacing
        }
        return out
    }

    /// Single section through the plane at signed distance `t` from the frame centre along `axis`.
    public static func crossSection(positions: [SIMD3<Float>], indices: [UInt32], frame: PrincipalFrame,
                                    axis: Int, at t: Double) -> CrossSection {
        let n = frame.axes[axis]
        let (ui, vi) = frame.planeAxes(axis)
        let u = frame.axes[ui], v = frame.axes[vi]
        let origin = frame.center + n * t
        let eps = 1e-12

        var dist = [Double](repeating: 0, count: positions.count)
        for (i, p) in positions.enumerated() {
            var d = vdot(SIMD3<Double>(p) - origin, n)
            if abs(d) < eps { d = eps } // vertices on the plane count as above it
            dist[i] = d
        }

        // Each crossing edge becomes a node keyed by its vertex pair, so shared edges join exactly.
        var point: [UInt64: SIMD2<Double>] = [:]
        var adj: [UInt64: [UInt64]] = [:]
        func node(_ a: UInt32, _ b: UInt32) -> UInt64 {
            let (i, j) = a < b ? (a, b) : (b, a)
            let key = UInt64(i) << 32 | UInt64(j)
            if point[key] == nil {
                let pa = SIMD3<Double>(positions[Int(i)]), pb = SIMD3<Double>(positions[Int(j)])
                let da = dist[Int(i)], db = dist[Int(j)]
                let x = pa + (pb - pa) * (da / (da - db)) - origin
                point[key] = SIMD2(vdot(x, u), vdot(x, v))
            }
            return key
        }
        var k = 0
        while k + 2 < indices.count {
            let tri = [indices[k], indices[k + 1], indices[k + 2]]
            k += 3
            var crossing: [UInt64] = []
            for e in 0..<3 {
                let a = tri[e], b = tri[(e + 1) % 3]
                if (dist[Int(a)] > 0) != (dist[Int(b)] > 0) { crossing.append(node(a, b)) }
            }
            if crossing.count == 2 {
                adj[crossing[0], default: []].append(crossing[1])
                adj[crossing[1], default: []].append(crossing[0])
            }
        }

        // Walk the segment graph into chains: open ends first, then closed loops.
        var visited = Set<UInt64>()
        var loops: [[SIMD2<Double>]] = [], open: [[SIMD2<Double>]] = []
        let starts = adj.keys.filter { adj[$0]!.count == 1 } + adj.keys.filter { adj[$0]!.count != 1 }
        for s in starts where !visited.contains(s) {
            var chain = [s]
            visited.insert(s)
            var cur = s
            while let next = adj[cur]!.first(where: { !visited.contains($0) }) {
                chain.append(next); visited.insert(next); cur = next
            }
            let pts = chain.map { point[$0]! }
            if chain.count > 2 && adj[cur]!.contains(s) { loops.append(pts) } else { open.append(pts) }
        }

        // Even-odd area: a loop inside an odd number of other loops is a hole.
        var area = 0.0, perimeter = 0.0
        for (i, loop) in loops.enumerated() {
            let a = abs(polygonArea(loop))
            let depth = loops.indices.filter { $0 != i && contains(loops[$0], loop[0]) }.count
            area += depth % 2 == 0 ? a : -a
            perimeter += polylineLength(loop, closed: true)
        }
        return CrossSection(axis: axis, depth: t - frame.lo[axis], loops: loops, openChains: open,
                            area: Swift.max(0, area), perimeter: perimeter)
    }

    static func polygonArea(_ p: [SIMD2<Double>]) -> Double {
        var s = 0.0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    static func polylineLength(_ p: [SIMD2<Double>], closed: Bool) -> Double {
        guard p.count > 1 else { return 0 }
        var s = 0.0
        for i in 1..<p.count { s += ((p[i] - p[i - 1]) * (p[i] - p[i - 1])).sum().squareRoot() }
        if closed { s += ((p[0] - p[p.count - 1]) * (p[0] - p[p.count - 1])).sum().squareRoot() }
        return s
    }

    static func contains(_ poly: [SIMD2<Double>], _ q: SIMD2<Double>) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > q.y) != (b.y > q.y) && q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
