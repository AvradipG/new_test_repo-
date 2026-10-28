import Foundation

/// Size and volume of a scanned rock, in lab units.
public struct MeshStats: Codable, Hashable, Sendable {
    /// Principal axes, longest first (a ≥ b ≥ c), in millimetres.
    public var axisA: Double
    public var axisB: Double
    public var axisC: Double
    /// Enclosed volume in cubic centimetres. Exact only when `isClosed` is true.
    public var volumeCM3: Double
    public var triangleCount: Int
    public var vertexCount: Int
    /// True when every edge is shared by exactly two triangles (watertight mesh).
    public var isClosed: Bool

    public init(axisA: Double, axisB: Double, axisC: Double, volumeCM3: Double, triangleCount: Int, vertexCount: Int, isClosed: Bool) {
        self.axisA = axisA; self.axisB = axisB; self.axisC = axisC
        self.volumeCM3 = volumeCM3; self.triangleCount = triangleCount; self.vertexCount = vertexCount; self.isClosed = isClosed
    }
}

public enum ScanMath {
    /// Signed volume of a triangle mesh (divergence theorem). Units: input units cubed.
    public static func signedVolume(positions: [SIMD3<Float>], indices: [UInt32]) -> Double {
        var v = 0.0
        var i = 0
        while i + 2 < indices.count {
            let a = SIMD3<Double>(positions[Int(indices[i])])
            let b = SIMD3<Double>(positions[Int(indices[i + 1])])
            let c = SIMD3<Double>(positions[Int(indices[i + 2])])
            v += vdot(a, vcross(b, c))
            i += 3
        }
        return v / 6
    }

    /// True when every undirected edge is used by exactly two triangles.
    public static func isClosed(indices: [UInt32]) -> Bool {
        guard indices.count >= 12 else { return false }
        var counts: [UInt64: Int] = [:]
        counts.reserveCapacity(indices.count)
        var i = 0
        while i + 2 < indices.count {
            for (p, q) in [(indices[i], indices[i + 1]), (indices[i + 1], indices[i + 2]), (indices[i + 2], indices[i])] {
                let key = UInt64(min(p, q)) << 32 | UInt64(max(p, q))
                counts[key, default: 0] += 1
            }
            i += 3
        }
        return counts.values.allSatisfy { $0 == 2 }
    }

    /// Lengths of the point cloud along its principal axes, longest first.
    public static func principalExtents(_ points: [SIMD3<Float>]) -> SIMD3<Double> {
        guard points.count > 1 else { return .zero }
        var mean = SIMD3<Double>.zero
        for p in points { mean += SIMD3<Double>(p) }
        mean /= Double(points.count)
        var c = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in points {
            let d = SIMD3<Double>(p) - mean
            for r in 0..<3 { for k in 0..<3 { c[r][k] += d[r] * d[k] } }
        }
        let axes = eigenvectorsSymmetric3(c)
        var out: [Double] = []
        for axis in axes {
            var lo = Double.infinity, hi = -Double.infinity
            for p in points {
                let t = vdot(SIMD3<Double>(p) - mean, axis)
                lo = Swift.min(lo, t); hi = Swift.max(hi, t)
            }
            out.append(hi - lo)
        }
        out.sort(by: >)
        return SIMD3(out[0], out[1], out[2])
    }

    /// Eigenvectors of a symmetric 3×3 matrix by cyclic Jacobi rotations.
    static func eigenvectorsSymmetric3(_ m: [[Double]]) -> [SIMD3<Double>] {
        var a = m
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<50 {
            let off = a[0][1] * a[0][1] + a[0][2] * a[0][2] + a[1][2] * a[1][2]
            if off < 1e-22 { break }
            for (p, q) in [(0, 1), (0, 2), (1, 2)] where abs(a[p][q]) > 1e-30 {
                let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                let cs = 1 / (t * t + 1).squareRoot(), sn = t * cs
                for k in 0..<3 {
                    let akp = a[k][p], akq = a[k][q]
                    a[k][p] = cs * akp - sn * akq
                    a[k][q] = sn * akp + cs * akq
                }
                for k in 0..<3 {
                    let apk = a[p][k], aqk = a[q][k]
                    a[p][k] = cs * apk - sn * aqk
                    a[q][k] = sn * apk + cs * aqk
                }
                for k in 0..<3 {
                    let vkp = v[k][p], vkq = v[k][q]
                    v[k][p] = cs * vkp - sn * vkq
                    v[k][q] = sn * vkp + cs * vkq
                }
            }
        }
        return (0..<3).map { j in vnormalize(SIMD3(v[0][j], v[1][j], v[2][j])) }
    }

    /// Full statistics. `unitToMM` converts input units to millimetres (Object Capture models are in metres).
    public static func stats(positions: [SIMD3<Float>], indices: [UInt32], unitToMM: Double = 1000) -> MeshStats {
        let ext = principalExtents(positions) * unitToMM
        let vol = abs(signedVolume(positions: positions, indices: indices)) * pow(unitToMM, 3) / 1000
        return MeshStats(axisA: ext.x, axisB: ext.y, axisC: ext.z, volumeCM3: vol,
                         triangleCount: indices.count / 3, vertexCount: positions.count,
                         isClosed: isClosed(indices: indices))
    }
}

@inline(__always) func vdot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
@inline(__always) func vcross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
@inline(__always) func vnormalize(_ a: SIMD3<Double>) -> SIMD3<Double> {
    let l = vdot(a, a).squareRoot()
    return l > 0 ? a / l : a
}
