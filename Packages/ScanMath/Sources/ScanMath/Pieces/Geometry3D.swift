import Foundation
import simd

/// Rigid motion: p ↦ R p + t.
public struct Pose: Equatable, Sendable {
    public var R: simd_double3x3
    public var t: SIMD3<Double>

    public init(R: simd_double3x3 = matrix_identity_double3x3, t: SIMD3<Double> = .zero) {
        self.R = R
        self.t = t
    }

    public static let identity = Pose()

    @inline(__always) public func apply(_ p: SIMD3<Double>) -> SIMD3<Double> { R * p + t }
    @inline(__always) public func rotate(_ n: SIMD3<Double>) -> SIMD3<Double> { R * n }

    public var inverse: Pose {
        let rt = R.transpose
        return Pose(R: rt, t: -(rt * t))
    }

    /// self ∘ other: apply `other` first.
    public func compose(_ other: Pose) -> Pose { Pose(R: R * other.R, t: R * other.t + t) }

    public static func rotation(axis: SIMD3<Double>, degrees: Double) -> simd_double3x3 {
        let l = simd_length(axis)
        guard l > 1e-12 else { return matrix_identity_double3x3 }
        return simd_double3x3(simd_quatd(angle: degrees * .pi / 180, axis: axis / l))
    }

    /// Rotation vector (axis × angle in radians) to matrix.
    public static func rotation(vector w: SIMD3<Double>) -> simd_double3x3 {
        let a = simd_length(w)
        guard a > 1e-15 else { return matrix_identity_double3x3 }
        return simd_double3x3(simd_quatd(angle: a, axis: w / a))
    }

    /// Rotation taking unit vector `a` onto unit vector `b`.
    public static func align(_ a: SIMD3<Double>, to b: SIMD3<Double>) -> simd_double3x3 {
        let v = simd_cross(a, b), c = simd_dot(a, b)
        if simd_length(v) < 1e-9 {
            if c > 0 { return matrix_identity_double3x3 }
            var p: SIMD3<Double> = abs(a.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            p -= simd_dot(p, a) * a
            return rotation(axis: p, degrees: 180)
        }
        return rotation(axis: v, degrees: atan2(simd_length(v), c) * 180 / .pi)
    }

    /// Angle of the rotation part, degrees.
    public var angleDegrees: Double {
        let tr = R[0][0] + R[1][1] + R[2][2]
        return acos(Swift.max(-1, Swift.min(1, (tr - 1) / 2))) * 180 / .pi
    }

    /// Row-major 4×4 matrix, for JSON files.
    public var matrix: [Double] {
        [R[0][0], R[1][0], R[2][0], t.x,
         R[0][1], R[1][1], R[2][1], t.y,
         R[0][2], R[1][2], R[2][2], t.z,
         0, 0, 0, 1]
    }

    public init(matrix m: [Double]) {
        precondition(m.count >= 12)
        R = simd_double3x3(columns: (SIMD3(m[0], m[4], m[8]), SIMD3(m[1], m[5], m[9]), SIMD3(m[2], m[6], m[10])))
        t = SIMD3(m[3], m[7], m[11])
    }

    /// Mean displacement of `points` between two poses.
    public static func displacement(_ a: Pose, _ b: Pose, points: [SIMD3<Double>]) -> Double {
        guard !points.isEmpty else { return 0 }
        var s = 0.0
        for p in points { s += simd_length(a.apply(p) - b.apply(p)) }
        return s / Double(points.count)
    }
}

/// Static 3-D k-d tree for nearest-neighbour and radius queries.
public final class KDTree {
    public let points: [SIMD3<Double>]
    private var perm: [Int]
    private var axes: [UInt8]

    public init(_ points: [SIMD3<Double>]) {
        self.points = points
        perm = Array(points.indices)
        axes = [UInt8](repeating: 0, count: points.count)
        build(0, points.count)
    }

    private func build(_ lo: Int, _ hi: Int) {
        guard hi - lo > 1 else { return }
        var mn = SIMD3<Double>(repeating: .infinity), mx = SIMD3<Double>(repeating: -.infinity)
        for i in lo..<hi {
            let p = points[perm[i]]
            mn = simd_min(mn, p)
            mx = simd_max(mx, p)
        }
        let e = mx - mn
        let ax = e.x >= e.y && e.x >= e.z ? 0 : (e.y >= e.z ? 1 : 2)
        let pts = points
        perm[lo..<hi].sort { pts[$0][ax] < pts[$1][ax] }
        let mid = (lo + hi) / 2
        axes[mid] = UInt8(ax)
        build(lo, mid)
        build(mid + 1, hi)
    }

    /// Nearest point within `maxDistance`.
    public func nearest(_ q: SIMD3<Double>, maxDistance: Double = .infinity) -> (index: Int, distance: Double)? {
        var best = -1
        var bestD2 = maxDistance.isFinite ? maxDistance * maxDistance : Double.infinity
        search(0, points.count, q, &best, &bestD2)
        return best < 0 ? nil : (best, bestD2.squareRoot())
    }

    private func search(_ lo: Int, _ hi: Int, _ q: SIMD3<Double>, _ best: inout Int, _ bestD2: inout Double) {
        guard lo < hi else { return }
        let mid = (lo + hi) / 2
        let i = perm[mid]
        let p = points[i]
        let d2 = simd_length_squared(p - q)
        if d2 < bestD2 {
            bestD2 = d2
            best = i
        }
        if hi - lo == 1 { return }
        let ax = Int(axes[mid])
        let diff = q[ax] - p[ax]
        if diff < 0 {
            search(lo, mid, q, &best, &bestD2)
            if diff * diff < bestD2 { search(mid + 1, hi, q, &best, &bestD2) }
        } else {
            search(mid + 1, hi, q, &best, &bestD2)
            if diff * diff < bestD2 { search(lo, mid, q, &best, &bestD2) }
        }
    }

    /// Indices of all points within `radius`.
    public func within(_ q: SIMD3<Double>, radius: Double) -> [Int] {
        var out: [Int] = []
        collect(0, points.count, q, radius * radius, radius, &out)
        return out
    }

    private func collect(_ lo: Int, _ hi: Int, _ q: SIMD3<Double>, _ r2: Double, _ r: Double, _ out: inout [Int]) {
        guard lo < hi else { return }
        let mid = (lo + hi) / 2
        let i = perm[mid]
        let p = points[i]
        if simd_length_squared(p - q) <= r2 { out.append(i) }
        if hi - lo == 1 { return }
        let ax = Int(axes[mid])
        let diff = q[ax] - p[ax]
        if diff - r <= 0 { collect(lo, mid, q, r2, r, &out) }
        if diff + r >= 0 { collect(mid + 1, hi, q, r2, r, &out) }
    }
}

enum LinearSolve {
    /// Solves A x = b (n×n, row-major) by Gaussian elimination with partial pivoting.
    static func solve(_ A: [Double], _ b: [Double], n: Int) -> [Double]? {
        var m = A, v = b
        for c in 0..<n {
            var piv = c
            var best = abs(m[c * n + c])
            for r in (c + 1)..<n where abs(m[r * n + c]) > best {
                best = abs(m[r * n + c])
                piv = r
            }
            guard best > 1e-300 else { return nil }
            if piv != c {
                for k in 0..<n { m.swapAt(c * n + k, piv * n + k) }
                v.swapAt(c, piv)
            }
            let d = m[c * n + c]
            for r in (c + 1)..<n {
                let f = m[r * n + c] / d
                if f == 0 { continue }
                for k in c..<n { m[r * n + k] -= f * m[c * n + k] }
                v[r] -= f * v[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = v[r]
            for k in (r + 1)..<n { s -= m[r * n + k] * x[k] }
            x[r] = s / m[r * n + r]
        }
        return x
    }
}

/// Small deterministic random generator (tests and sampling must give the same answer every run).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// About `want` indices out of `count`, spread without following any order in the data (a plain every-n-th
/// subset can pick only one kind of surface when the samples were listed in a regular pattern).
func spreadIndices(_ count: Int, want: Int) -> [Int] {
    guard count > want, want > 0 else { return Array(0..<Swift.max(0, count)) }
    let step = UInt64(Swift.max(1, count / want))
    return (0..<count).filter { (((UInt64($0) &* 2654435761) >> 9) % step) == 0 }
}

extension Array where Element == SIMD3<Double> {
    var centroid: SIMD3<Double> {
        guard !isEmpty else { return .zero }
        return reduce(SIMD3<Double>.zero, +) / Double(count)
    }
}
