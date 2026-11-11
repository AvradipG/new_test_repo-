import Foundation
import simd

// A small rock is often scanned standing on a block (wood, cork, putty) so the phone finds it. The block is part
// of the 3D model and must come off before anything is measured (3.14): StandFinder finds where it ends on the
// unrolled side image, MeshCut cuts the model there and closes the cut.

public enum StandFinder {
    public struct Result: Sendable {
        /// First row (from the top) of the stand.
        public var boundaryRow: Int
        /// Colour difference between rock and stand (0–1 units of luma and colour).
        public var distance: Double
        public var rockLuma: Double
        public var standLuma: Double
        /// Share of the height taken by the stand.
        public var standShare: Double
    }

    /// Luma, red−green and yellow−blue of a colour (each 0–1).
    @inline(__always) static func features(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l: Double = 0.299 * c.x + 0.587 * c.y + 0.114 * c.z
        let a: Double = c.x - c.y
        let b: Double = (c.x + c.y) / 2 - c.z
        return SIMD3(l, a, b)
    }

    static func median(_ v: [SIMD3<Double>]) -> SIMD3<Double> {
        guard !v.isEmpty else { return .zero }
        func med(_ x: [Double]) -> Double {
            let s = x.sorted()
            return s[s.count / 2]
        }
        return SIMD3(med(v.map { $0.x }), med(v.map { $0.y }), med(v.map { $0.z }))
    }

    /// - Parameter rows: median colour (r, g, b in 0–1) of each row of the unrolled side, top row first; nil where
    ///   the row shows no surface.
    /// - Returns: where a stand of clearly different colour begins at the bottom, or nil when there is none: the
    ///   two parts must differ clearly, change in a sharp step (not a gradual shading), and each part must be of
    ///   one colour on the whole (rows of the lower part closer to the stand's colour, rows above to the rock's).
    public static func find(rows: [SIMD3<Double>?], minShare: Double = 0.08, maxShare: Double = 0.75,
                            minDistance: Double = 0.12) -> Result? {
        let n = rows.count
        guard n >= 12 else { return nil }
        let f: [SIMD3<Double>?] = rows.map { $0.map(features) }
        let lo = Swift.max(2, Int(Double(n) * (1 - maxShare)))
        let hi = Swift.min(n - 2, Int(Double(n) * (1 - minShare)))
        guard lo < hi else { return nil }
        // Where to split: the least squared spread within the two parts (a plain change point), on the rows
        // that show surface.
        let idx = (0..<n).filter { f[$0] != nil }
        guard idx.count >= 12 else { return nil }
        var sum = [SIMD3<Double>](repeating: .zero, count: idx.count + 1)
        var sq = [Double](repeating: 0, count: idx.count + 1)
        for (j, i) in idx.enumerated() {
            let v = f[i]!
            sum[j + 1] = sum[j] + v
            sq[j + 1] = sq[j] + simd_length_squared(v)
        }
        func spread(_ a: Int, _ b: Int) -> Double {
            let m = Double(b - a)
            guard m > 0 else { return 0 }
            let s = sum[b] - sum[a]
            return (sq[b] - sq[a]) - simd_length_squared(s) / m
        }
        var best: (k: Int, cost: Double, d: Double, up: SIMD3<Double>, dn: SIMD3<Double>)?
        for j in 3..<(idx.count - 2) {
            let k = idx[j]
            guard k >= lo && k <= hi else { continue }
            let cost = spread(0, j) + spread(j, idx.count)
            if cost < (best?.cost ?? .infinity) {
                let up = median(f[0..<k].compactMap { $0 }), dn = median(f[k..<n].compactMap { $0 })
                best = (k, cost, simd_length(up - dn), up, dn)
            }
        }
        guard let b = best, b.d >= minDistance else { return nil }
        // Each part of one colour on the whole.
        var upperOK = 0, upperAll = 0, lowerOK = 0, lowerAll = 0
        for (i, v) in f.enumerated() {
            guard let v else { continue }
            let closerToStand = simd_length(v - b.dn) < simd_length(v - b.up)
            if i < b.k {
                upperAll += 1
                if !closerToStand { upperOK += 1 }
            } else {
                lowerAll += 1
                if closerToStand { lowerOK += 1 }
            }
        }
        guard upperAll > 0, lowerAll > 0,
              Double(upperOK) / Double(upperAll) >= 0.85, Double(lowerOK) / Double(lowerAll) >= 0.85 else { return nil }
        // A sharp step: the few rows on either side of the boundary already differ by most of the distance.
        let w = Swift.max(2, n / 40)
        let above = f[Swift.max(0, b.k - w)..<b.k].compactMap { $0 }
        let below = f[b.k..<Swift.min(n, b.k + w)].compactMap { $0 }
        guard !above.isEmpty, !below.isEmpty, simd_length(median(above) - median(below)) >= 0.6 * b.d else { return nil }
        return Result(boundaryRow: b.k, distance: b.d, rockLuma: b.up.x, standLuma: b.dn.x, standShare: Double(n - b.k) / Double(n))
    }
}

public enum MeshCut {
    /// The part of a closed triangle mesh at or above height `y` (+Y up), cut exactly along the plane, the cut
    /// closed by flat caps facing down so the result is closed again (volume and sections stay right).
    /// Unused vertices are dropped.
    public static func above(positions: [SIMD3<Float>], indices: [UInt32], y: Float) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        var P = positions
        var T: [UInt32] = []
        T.reserveCapacity(indices.count)
        var cutVertex: [UInt64: UInt32] = [:]
        // Directed boundary edges of the cap (from → to), so caps face down.
        var capNext: [UInt32: [UInt32]] = [:]

        func isUp(_ i: UInt32) -> Bool { P[Int(i)].y >= y }
        // The point where edge a(up)–b(down) meets the plane; an end lying on the plane is used as it is.
        func cross(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let pa = P[Int(a)], pb = P[Int(b)]
            if abs(pa.y - y) < 1e-9 { return a }
            let key = (UInt64(Swift.min(a, b)) << 32) | UInt64(Swift.max(a, b))
            if let v = cutVertex[key] { return v }
            let t = (pa.y - y) / (pa.y - pb.y)
            var q = pa + (pb - pa) * t
            q.y = y
            let v = UInt32(P.count)
            P.append(q)
            cutVertex[key] = v
            return v
        }

        var k = 0
        while k + 2 < indices.count {
            let tri = [indices[k], indices[k + 1], indices[k + 2]]
            k += 3
            let up = tri.map(isUp)
            let count = up.filter { $0 }.count
            if count == 3 {
                T += tri
                continue
            }
            if count == 0 { continue }
            // Turn the triangle (keeping its winding) so the odd vertex comes first.
            var r = 0
            if count == 1 { r = up.firstIndex(of: true)! } else { r = up.firstIndex(of: false)! }
            let v0 = tri[r], v1 = tri[(r + 1) % 3], v2 = tri[(r + 2) % 3]
            if count == 1 {
                // v0 up, v1 and v2 down.
                let p01 = cross(v0, v1), p20 = cross(v0, v2)
                if p01 != v0 && p20 != v0 && p01 != p20 { T += [v0, p01, p20] }
                if p01 != p20 { capNext[p20, default: []].append(p01) }
            } else {
                // v0 down, v1 and v2 up: the quad v1, v2, p20, p01.
                let p01 = cross(v1, v0), p20 = cross(v2, v0)
                if p20 != v2 { T += [v1, v2, p20] }
                if p20 != p01 && p01 != v1 { T += [v1, p20, p01] }
                if p01 != p20 { capNext[p01, default: []].append(p20) }
            }
        }

        // Caps: walk the cut edges into loops and fan each from its middle.
        var used = Set<UInt64>()
        func edgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 { (UInt64(a) << 32) | UInt64(b) }
        for start in capNext.keys.sorted() {
            for first in capNext[start] ?? [] where !used.contains(edgeKey(start, first)) {
                var loop: [UInt32] = [start]
                var a = start, b = first
                var steps = 0
                while steps < 1_000_000 {
                    used.insert(edgeKey(a, b))
                    if b == start { break }
                    loop.append(b)
                    guard let nexts = capNext[b], let c = nexts.first(where: { !used.contains(edgeKey(b, $0)) }) else { break }
                    a = b
                    b = c
                    steps += 1
                }
                guard loop.count >= 3 else { continue }
                var c = SIMD3<Float>.zero
                for v in loop { c += P[Int(v)] }
                c /= Float(loop.count)
                c.y = y
                // Newell normal of the loop: the cap must face down.
                var nrm = SIMD3<Float>.zero
                for i in loop.indices {
                    let p = P[Int(loop[i])], q = P[Int(loop[(i + 1) % loop.count])]
                    nrm += simd_cross(p - c, q - c)
                }
                let mid = UInt32(P.count)
                P.append(c)
                let flip = nrm.y > 0
                for i in loop.indices {
                    let p = loop[i], q = loop[(i + 1) % loop.count]
                    T += flip ? [mid, q, p] : [mid, p, q]
                }
            }
        }

        // Only the vertices still in use.
        var remap = [Int32](repeating: -1, count: P.count)
        var outP: [SIMD3<Float>] = []
        var outT: [UInt32] = []
        outT.reserveCapacity(T.count)
        for v in T {
            let i = Int(v)
            if remap[i] < 0 {
                remap[i] = Int32(outP.count)
                outP.append(P[i])
            }
            outT.append(UInt32(remap[i]))
        }
        return (outP, outT)
    }
}
