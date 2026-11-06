import Foundation

// Optional lab tools (3.4). All maths here is unit-tested and also run by the app's self-test on a demo rock.

/// A closed, outward-facing cylinder standing on +Y, the size of a lab plug: the app's demo rock.
public enum DemoRock {
    /// Positions in the units given (the app uses metres, like Object Capture models).
    public static func cylinder(radius: Double, height: Double, segments: Int = 96, rings: Int = 24) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        var p: [SIMD3<Float>] = []
        var t: [UInt32] = []
        p.append(SIMD3(0, 0, 0))                 // 0: bottom centre
        p.append(SIMD3(0, Float(height), 0))     // 1: top centre
        func v(_ k: Int, _ i: Int) -> UInt32 { UInt32(2 + k * segments + (i % segments)) }
        for k in 0...rings {
            let y = height * Double(k) / Double(rings)
            for i in 0..<segments {
                let a = 2 * Double.pi * Double(i) / Double(segments)
                p.append(SIMD3(Float(radius * cos(a)), Float(y), Float(radius * sin(a))))
            }
        }
        for k in 0..<rings {
            for i in 0..<segments {
                t += [v(k, i), v(k + 1, i), v(k + 1, i + 1)]
                t += [v(k, i), v(k + 1, i + 1), v(k, i + 1)]
            }
        }
        for i in 0..<segments {
            t += [0, v(0, i), v(0, i + 1)]
            t += [1, v(rings, i + 1), v(rings, i)]
        }
        return (p, t)
    }
}

/// Bulk density and porosity from a weighed mass.
public enum Density {
    /// g/cm³, or nil when either value is missing or not positive.
    public static func bulk(massG: Double, volumeCM3: Double) -> Double? {
        guard massG > 0, volumeCM3 > 0, massG.isFinite, volumeCM3.isFinite else { return nil }
        return massG / volumeCM3
    }

    /// Total porosity (0…1) from bulk and grain density; nil when the grain density is not above the bulk density.
    public static func porosity(bulk: Double, grain: Double) -> Double? {
        guard bulk > 0, grain > bulk else { return nil }
        return 1 - bulk / grain
    }
}

/// Where the longest plug of a given diameter fits inside the rock (3.4).
public struct CoringResult: Equatable, Sendable {
    /// Longest plug, in model units, along the chosen axis.
    public var length: Double
    /// Centre of the plug in the plane across the axis, model units, relative to the rock's mean point.
    public var center: SIMD2<Double>
    /// Distance from the rock's end (frame `lo`) to where the plug starts.
    public var from: Double
}

public enum VirtualCoring {
    /// Slices the model across the axis every `step` and finds the centre line where a circle of `diameter`
    /// stays inside the rock for the most consecutive slices. `vertical` = up as scanned (+Y), else the long axis a.
    /// Coarse search on a `gridStep` grid, then a finer one round the best centre.
    public static func longestPlug(positions: [SIMD3<Float>], indices: [UInt32], diameter: Double, vertical: Bool,
                                   step: Double, gridStep: Double) -> CoringResult? {
        guard diameter > 0, step > 0, gridStep > 0, !positions.isEmpty else { return nil }
        let frame = vertical ? ScanMath.uprightFrame(positions) : ScanMath.principalFrame(positions)
        let sections = ScanMath.crossSections(positions: positions, indices: indices, frame: frame, axis: 0, spacing: step)
        guard !sections.isEmpty else { return nil }
        let polys: [[[SIMD2<Double>]]] = sections.map { s in
            let closed = s.loops.filter { $0.count >= 3 }
            return closed.isEmpty ? s.openChains.filter { $0.count >= 3 } : closed
        }
        let r = diameter / 2
        let (ui, vi) = frame.planeAxes(0)

        func score(_ c: SIMD2<Double>) -> (run: Int, start: Int) {
            var best = 0, bestStart = 0, run = 0, runStart = 0
            for (k, loops) in polys.enumerated() {
                if fits(c, r, loops) {
                    if run == 0 { runStart = k }
                    run += 1
                    if run > best { best = run; bestStart = runStart }
                } else {
                    run = 0
                }
            }
            return (best, bestStart)
        }

        var bestC = SIMD2<Double>(0, 0)
        var best = (run: 0, start: 0)
        func search(around c0: SIMD2<Double>, halfU: Double, halfV: Double, grid: Double) {
            let nu = Int(halfU / grid), nv = Int(halfV / grid)
            guard nu >= 0, nv >= 0 else { return }
            for i in -nu...nu {
                for j in -nv...nv {
                    let c = c0 + SIMD2(Double(i) * grid, Double(j) * grid)
                    let s = score(c)
                    let closer = (c.x * c.x + c.y * c.y) < (bestC.x * bestC.x + bestC.y * bestC.y)
                    if s.run > best.run || (s.run == best.run && s.run > 0 && closer) {
                        best = s
                        bestC = c
                    }
                }
            }
        }
        let halfU = max(0, max(-frame.lo[ui], frame.hi[ui]) - r)
        let halfV = max(0, max(-frame.lo[vi], frame.hi[vi]) - r)
        search(around: .zero, halfU: halfU, halfV: halfV, grid: gridStep)
        if best.run > 0 {
            search(around: bestC, halfU: gridStep, halfV: gridStep, grid: gridStep / 4)
        }
        guard best.run > 0 else { return CoringResult(length: 0, center: .zero, from: 0) }
        return CoringResult(length: Double(best.run) * step, center: bestC, from: sections[best.start].depth - step / 2)
    }

    /// True when the circle (centre `c`, radius `r`) lies inside the outline: centre inside (even-odd) and
    /// every edge at least `r` away.
    static func fits(_ c: SIMD2<Double>, _ r: Double, _ loops: [[SIMD2<Double>]]) -> Bool {
        guard !loops.isEmpty else { return false }
        var inside = false
        let r2 = r * r
        for loop in loops {
            var j = loop.count - 1
            for i in 0..<loop.count {
                let a = loop[j], b = loop[i]
                if (b.y > c.y) != (a.y > c.y) {
                    let x = a.x + (c.y - a.y) * (b.x - a.x) / (b.y - a.y)
                    if c.x < x { inside.toggle() }
                }
                if segmentDistance2(c, a, b) < r2 { return false }
                j = i
            }
        }
        return inside
    }

    static func segmentDistance2(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a, ap = p - a
        let len2 = ab.x * ab.x + ab.y * ab.y
        let t = len2 > 0 ? max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / len2)) : 0
        let d = ap - ab * t
        return d.x * d.x + d.y * d.y
    }
}

/// The micro-CT frame: z up as the rock stood in the scan (as it stands in the CT holder), origin on the axis of
/// the smallest circle round the footprint at the lowest point, x along the model's horizontal x axis.
public struct CTFrame: Equatable, Sendable {
    public var origin: SIMD3<Double>
    public var x: SIMD3<Double>
    public var y: SIMD3<Double>
    public var z: SIMD3<Double>

    public static func make(_ points: [SIMD3<Float>], up: Int = 1) -> CTFrame {
        let (h1, h2) = ScanMath.horizontalAxes(up)
        var zAxis = SIMD3<Double>(0, 0, 0); zAxis[up] = 1
        var xAxis = SIMD3<Double>(0, 0, 0); xAxis[h1] = 1
        let yAxis = vcross(zAxis, xAxis)
        let footprint = points.map { SIMD2(Double($0[h1]), Double($0[h2])) }
        let circle = ScanMath.enclosingCircle(footprint)
        let low = points.map { Double($0[up]) }.min() ?? 0
        var o = SIMD3<Double>(0, 0, 0)
        o[h1] = circle.center.x; o[h2] = circle.center.y; o[up] = low
        return CTFrame(origin: o, x: xAxis, y: yAxis, z: zAxis)
    }

    /// A model point in the CT frame, multiplied by `scale` (for example 1000 × caliper factor for millimetres).
    public func apply(_ p: SIMD3<Float>, scale: Double) -> SIMD3<Double> {
        let d = SIMD3<Double>(p) - origin
        return SIMD3(vdot(d, x), vdot(d, y), vdot(d, z)) * scale
    }

    /// Row-major 4×4 matrix taking model coordinates to CT coordinates at `scale`.
    public func matrix(scale: Double) -> [[Double]] {
        let t = SIMD3(vdot(origin, x), vdot(origin, y), vdot(origin, z))
        return [
            [x.x * scale, x.y * scale, x.z * scale, -t.x * scale],
            [y.x * scale, y.y * scale, y.z * scale, -t.y * scale],
            [z.x * scale, z.y * scale, z.z * scale, -t.z * scale],
            [0, 0, 0, 1],
        ]
    }
}

/// A bedding plane (or fracture) from points tapped on the unrolled side of a cylindrical sample: on the
/// unrolled image a plane is a sine curve, height = c + a·cos θ + b·sin θ (3.4).
public struct BeddingFit: Equatable, Sendable {
    /// Angle between the plane and the plane square to the sample axis (0 = square across, 90 = along the axis).
    public var dipDegrees: Double
    /// Protractor angle (from the reference, + counter-clockwise seen from above) where the plane is highest.
    public var highAngleDegrees: Double
    /// Height of the plane on the axis, mm from the bottom.
    public var centreHeightMM: Double
    /// Root-mean-square misfit of the tapped points, mm.
    public var rmsMM: Double
    public var points: Int

    /// `angles`: protractor degrees of each tapped point; `heights`: mm above the bottom; `radiusMM`: sample radius.
    public static func fit(angles: [Double], heights: [Double], radiusMM: Double) -> BeddingFit? {
        let n = min(angles.count, heights.count)
        guard n >= 3, radiusMM > 0 else { return nil }
        // Normal equations for [c, a, b].
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var rhs = [0.0, 0, 0]
        for k in 0..<n {
            let t = angles[k] * .pi / 180
            let row = [1, cos(t), sin(t)]
            for i in 0..<3 {
                rhs[i] += row[i] * heights[k]
                for j in 0..<3 { m[i][j] += row[i] * row[j] }
            }
        }
        guard let s = solve3(m, rhs) else { return nil }
        let (c, a, b) = (s[0], s[1], s[2])
        var ss = 0.0
        for k in 0..<n {
            let t = angles[k] * .pi / 180
            let e = heights[k] - (c + a * cos(t) + b * sin(t))
            ss += e * e
        }
        var high = atan2(b, a) * 180 / .pi
        if high < 0 { high += 360 }
        return BeddingFit(dipDegrees: atan(hypot(a, b) / radiusMM) * 180 / .pi, highAngleDegrees: high,
                          centreHeightMM: c, rmsMM: (ss / Double(n)).squareRoot(), points: n)
    }

    static func solve3(_ m: [[Double]], _ r: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-9 else { return nil } // points too close together in angle
        return (0..<3).map { col in
            var a = m
            for row in 0..<3 { a[row][col] = r[row] }
            return det(a) / d
        }
    }
}

/// The phone's own scale correction, from scanning an object of known size once (3.5).
public enum ScaleReference {
    /// true / scanned length, or nil when the lengths are missing or differ by more than 20 % (a typo or the wrong axis).
    public static func factor(trueMM: Double, scannedMM: Double) -> Double? {
        guard trueMM > 0, scannedMM > 0 else { return nil }
        let f = trueMM / scannedMM
        return (0.8...1.25).contains(f) ? f : nil
    }
}
