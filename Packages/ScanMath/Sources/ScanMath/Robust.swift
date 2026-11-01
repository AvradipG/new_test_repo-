import Foundation

/// Orientation-independent size of the rock, in millimetres. These are what a caliper measures and do not
/// depend on how the rock happened to lie or how densely the mesh is sampled, so repeat scans agree better
/// than with principal-axis extents.
public struct BoxSize: Codable, Hashable, Sendable {
    /// Sides of the smallest box around the rock, longest first.
    public var lengthMM: Double
    public var widthMM: Double
    public var thicknessMM: Double
    /// Largest distance between two points of the rock (3D maximum Feret diameter).
    public var maxFeretMM: Double
    /// Narrowest caliper width over all directions (3D minimum Feret diameter).
    public var minFeretMM: Double

    public init(lengthMM: Double, widthMM: Double, thicknessMM: Double, maxFeretMM: Double, minFeretMM: Double) {
        self.lengthMM = lengthMM; self.widthMM = widthMM; self.thicknessMM = thicknessMM
        self.maxFeretMM = maxFeretMM; self.minFeretMM = minFeretMM
    }
}

extension ScanMath {
    // MARK: Main body

    /// Keeps the rock and drops small loose pieces (floating fragments, bits of table) that would inflate
    /// the sizes. Pieces are found on the welded mesh; a piece is kept when its surface area is at least
    /// `minShare` of the largest piece. Returns the kept triangles (original indices), the kept share of the
    /// total surface area and how many pieces were dropped.
    public static func mainBody(positions: [SIMD3<Float>], indices: [UInt32], minShare: Double = 0.05)
        -> (indices: [UInt32], keptAreaShare: Double, removedPieces: Int) {
        let triCount = indices.count / 3
        guard triCount > 0 else { return (indices, 1, 0) }
        let canon = canonicalIndices(positions: positions, indices: indices)
        var parent = Array(0..<positions.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var y = x
            while parent[y] != r { let next = parent[y]; parent[y] = r; y = next }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for t in 0..<triCount {
            union(Int(canon[3 * t]), Int(canon[3 * t + 1]))
            union(Int(canon[3 * t + 1]), Int(canon[3 * t + 2]))
        }
        var area: [Int: Double] = [:]
        var triRoot = [Int](repeating: 0, count: triCount)
        var total = 0.0
        for t in 0..<triCount {
            let a = SIMD3<Double>(positions[Int(indices[3 * t])])
            let b = SIMD3<Double>(positions[Int(indices[3 * t + 1])])
            let c = SIMD3<Double>(positions[Int(indices[3 * t + 2])])
            let s = vdot(vcross(b - a, c - a), vcross(b - a, c - a)).squareRoot() / 2
            let r = find(Int(canon[3 * t]))
            triRoot[t] = r
            area[r, default: 0] += s
            total += s
        }
        guard let largest = area.values.max(), largest > 0 else { return (indices, 1, 0) }
        let keep = Set(area.filter { $0.value >= minShare * largest }.keys)
        var out: [UInt32] = []
        out.reserveCapacity(indices.count)
        var kept = 0.0
        for t in 0..<triCount where keep.contains(triRoot[t]) {
            out.append(contentsOf: indices[(3 * t)..<(3 * t + 3)])
        }
        for (r, a) in area where keep.contains(r) { kept += a }
        return (out, total > 0 ? kept / total : 1, area.count - keep.count)
    }

    /// The vertices used by a set of triangles.
    public static func usedPositions(_ positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var used = [Bool](repeating: false, count: positions.count)
        for i in indices { used[Int(i)] = true }
        return positions.indices.filter { used[$0] }.map { positions[$0] }
    }

    // MARK: Box and Feret diameters

    /// Evenly spread unit directions (Fibonacci sphere); `half` keeps one of each opposite pair.
    static func sphereDirections(_ n: Int, half: Bool) -> [SIMD3<Double>] {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<n).map { i in
            let z = half ? 1 - Double(i) / Double(n) : 1 - 2 * (Double(i) + 0.5) / Double(n)
            let r = Swift.max(0, 1 - z * z).squareRoot()
            let phi = golden * Double(i)
            return SIMD3(r * cos(phi), r * sin(phi), z)
        }
    }

    /// Points that are extreme along many directions: a small set that carries the outline of the convex hull.
    static func extremeCandidates(_ pts: [SIMD3<Double>], directions: Int = 720) -> [SIMD3<Double>] {
        guard pts.count > 64 else { return pts }
        var chosen = Set<Int>()
        for d in sphereDirections(directions, half: true) {
            var lo = Double.infinity, hi = -Double.infinity, iLo = 0, iHi = 0
            for (i, p) in pts.enumerated() {
                let t = vdot(p, d)
                if t < lo { lo = t; iLo = i }
                if t > hi { hi = t; iHi = i }
            }
            chosen.insert(iLo); chosen.insert(iHi)
        }
        return chosen.sorted().map { pts[$0] }
    }

    static func range(_ pts: [SIMD3<Double>], along d: SIMD3<Double>) -> (lo: Double, hi: Double, iLo: Int, iHi: Int) {
        var lo = Double.infinity, hi = -Double.infinity, iLo = 0, iHi = 0
        for (i, p) in pts.enumerated() {
            let t = vdot(p, d)
            if t < lo { lo = t; iLo = i }
            if t > hi { hi = t; iHi = i }
        }
        return (lo, hi, iLo, iHi)
    }

    /// Any unit vector perpendicular to `d`, and a second one completing the frame.
    static func planeBasis(_ d: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let helper = abs(d.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u = vnormalize(vcross(d, helper))
        return (u, vcross(d, u))
    }

    /// Smallest box around the points (searched over orientations, then measured exactly with every point),
    /// plus the 3D maximum and minimum Feret diameters. Units: input units times `unitToMM`.
    public static func boxSize(_ points: [SIMD3<Float>], unitToMM: Double = 1000) -> BoxSize? {
        guard points.count >= 4 else { return nil }
        let pts = points.map { SIMD3<Double>($0) }
        let cand = extremeCandidates(pts)

        // Box: for each direction of the thinnest side, the smallest rectangle around the projection.
        func box(_ d: SIMD3<Double>) -> (volume: Double, axes: [SIMD3<Double>]) {
            let (u, v) = planeBasis(d)
            let proj = cand.map { SIMD2(vdot($0, u), vdot($0, v)) }
            let c = hullCalipers(convexHull(proj))
            let r = range(cand, along: d)
            let long = vnormalize(u * c.longDir.x + v * c.longDir.y)
            return (c.rectLong * c.rectShort * (r.hi - r.lo), [d, long, vcross(d, long)])
        }
        var best = (volume: Double.infinity, axes: [SIMD3<Double>]())
        for d in sphereDirections(1500, half: true) {
            let b = box(d)
            if b.volume < best.volume { best = b }
        }
        // Refine around the best direction with ever smaller steps.
        var step = 0.05
        for _ in 0..<14 {
            let d0 = best.axes[0]
            let (u, v) = planeBasis(d0)
            for i in -3...3 { for j in -3...3 where i != 0 || j != 0 {
                let d = vnormalize(d0 + u * (Double(i) * step) + v * (Double(j) * step))
                let b = box(d)
                if b.volume < best.volume { best = b }
            } }
            step /= 3
        }
        let sides = best.axes.map { a -> Double in
            let r = range(pts, along: a)
            return (r.hi - r.lo) * unitToMM
        }.sorted(by: >)

        // Maximum Feret: farthest candidate pair, then pushed to the true extremes along its direction.
        var dMax = 0.0, pairDir = SIMD3<Double>(1, 0, 0)
        for i in 0..<cand.count {
            for j in (i + 1)..<cand.count {
                let w = cand[j] - cand[i]
                let l = vdot(w, w)
                if l > dMax { dMax = l; pairDir = w }
            }
        }
        var maxFeret = dMax.squareRoot()
        for _ in 0..<4 {
            let d = vnormalize(pairDir)
            let r = range(pts, along: d)
            let w = pts[r.iHi] - pts[r.iLo]
            maxFeret = Swift.max(maxFeret, vdot(w, w).squareRoot())
            pairDir = w
        }

        // Minimum Feret: narrowest width over directions, refined, then measured with every point.
        func width(_ d: SIMD3<Double>) -> Double { let r = range(cand, along: d); return r.hi - r.lo }
        var minDir = best.axes[0], minW = width(minDir)
        for d in sphereDirections(1500, half: true) {
            let w = width(d)
            if w < minW { minW = w; minDir = d }
        }
        step = 0.05
        for _ in 0..<14 {
            let d0 = minDir
            let (u, v) = planeBasis(d0)
            for i in -3...3 { for j in -3...3 where i != 0 || j != 0 {
                let d = vnormalize(d0 + u * (Double(i) * step) + v * (Double(j) * step))
                let w = width(d)
                if w < minW { minW = w; minDir = d }
            } }
            step /= 3
        }
        let r = range(pts, along: minDir)
        return BoxSize(lengthMM: sides[0], widthMM: sides[1], thicknessMM: sides[2],
                       maxFeretMM: maxFeret * unitToMM, minFeretMM: (r.hi - r.lo) * unitToMM)
    }

    // MARK: Enclosing circle

    /// Smallest circle containing all points (Welzl, iterative, on the convex hull).
    public static func enclosingCircle(_ points: [SIMD2<Double>]) -> (center: SIMD2<Double>, radius: Double) {
        var p = convexHull(points)
        guard !p.isEmpty else { return (SIMD2(0, 0), 0) }
        // Fixed shuffle so results are reproducible but the expected running time stays linear.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        if p.count > 1 {
            for i in stride(from: p.count - 1, to: 0, by: -1) {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                p.swapAt(i, Int((seed >> 33) % UInt64(i + 1)))
            }
        }
        var c = p[0], r = 0.0
        func outside(_ q: SIMD2<Double>) -> Bool { length2(q - c) > r * (1 + 1e-12) + 1e-15 }
        for i in 0..<p.count where outside(p[i]) {
            c = p[i]; r = 0
            for j in 0..<i where outside(p[j]) {
                c = (p[i] + p[j]) / 2; r = length2(p[i] - c)
                for k in 0..<j where outside(p[k]) {
                    (c, r) = circumcircle(p[i], p[j], p[k])
                }
            }
        }
        return (c, r)
    }

    static func circumcircle(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> (SIMD2<Double>, Double) {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        if abs(d) < 1e-30 {
            // Collinear: the circle on the farthest pair.
            let pairs = [(a, b), (b, c), (a, c)]
            let far = pairs.max { length2($0.0 - $0.1) < length2($1.0 - $1.1) }!
            let m = (far.0 + far.1) / 2
            return (m, length2(far.0 - m))
        }
        let a2 = a.x * a.x + a.y * a.y, b2 = b.x * b.x + b.y * b.y, c2 = c.x * c.x + c.y * c.y
        let u = SIMD2((a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
                      (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
        return (u, length2(a - u))
    }

    // MARK: Photo sharpness

    /// Focus measure of a grey image (values 0…1, row-major): variance of the 4-neighbour Laplacian.
    /// Higher is sharper; compare photos of the same scene, not across scenes.
    public static func sharpness(gray: [Float], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, gray.count >= width * height else { return 0 }
        var sum = 0.0, sumSq = 0.0
        var n = 0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                let l = Double(4 * gray[i] - gray[i - 1] - gray[i + 1] - gray[i - width] - gray[i + width])
                sum += l; sumSq += l * l; n += 1
            }
        }
        let mean = sum / Double(n)
        return Swift.max(0, sumSq / Double(n) - mean * mean)
    }

    public static func median(_ values: [Double]) -> Double {
        let v = values.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return .nan }
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    /// Photos much less sharp than the typical photo of the same scan, worst first, at most `maxFraction` of them.
    /// Needs at least `minCount` scored photos; unscored (non-finite) entries are never flagged.
    public static func blurryIndices(_ scores: [Double], relative: Double = 0.45, maxFraction: Double = 0.15, minCount: Int = 8) -> [Int] {
        let finite = scores.filter { $0.isFinite }
        guard finite.count >= minCount else { return [] }
        let m = median(finite)
        guard m > 0 else { return [] }
        let flagged = scores.indices.filter { scores[$0].isFinite && scores[$0] < relative * m }
            .sorted { scores[$0] < scores[$1] }
        return Array(flagged.prefix(Int(Double(scores.count) * maxFraction)))
    }
}
