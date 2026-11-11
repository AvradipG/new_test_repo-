import Foundation
import simd

// Putting broken pieces back into a known cylinder (3.12).
//
// Matching breaks pair by pair needs both faces of every break to have been scanned. Pieces scanned lying on a
// table show only their upper side, and saw cuts or worn breaks carry little shape to match, so the pair matcher
// often places nothing. When the original was a cylinder (a core plug, a disc), the largest piece fixes where that
// cylinder lies: its curved outside gives the axis and radius, its flat ends give the ends. The cylinder then acts
// as a mould. Every other piece is fitted into the empty part of the mould so that its own original outside lies on
// the mould's wall or ends, its breaks touch the pieces already in place, it pokes out of the cylinder nowhere and
// overlaps no other piece. Several arrangements are kept alive while pieces are added (beam search), so the first
// attractive fit does not decide the result, and pieces that fit in two places about equally well are reported as
// such.

/// The part of a piece's surface that lies on a cylinder.
public struct CylinderPatch: Sendable {
    public var axis: SIMD3<Double>
    /// A point on the axis.
    public var centre: SIMD3<Double>
    public var radius: Double
    /// Samples on the cylinder.
    public var members: [Int]
    /// Share of the piece's samples on the cylinder.
    public var share: Double
    /// How far round the axis the patch reaches (degrees, in 10° steps).
    public var arcDegrees: Double
}

/// The original cylinder, in the frame of the piece it was fitted to.
public struct CoreCylinder: Sendable {
    /// Unit axis, pointing from the bottom end to the top end.
    public var axis: SIMD3<Double>
    /// The point of the axis nearest the origin, so a point's position along the axis is simply dot(p, axis).
    public var base: SIMD3<Double>
    public var radius: Double
    /// Bottom and top ends along the axis.
    public var t0: Double
    public var t1: Double
    public var radiusGiven: Bool
    public var lengthGiven: Bool
    public var topFound: Bool
    public var bottomFound: Bool
    public var note: String

    public init(axis: SIMD3<Double>, through point: SIMD3<Double>, radius: Double, t0: Double, t1: Double,
                radiusGiven: Bool = false, lengthGiven: Bool = false, topFound: Bool = false, bottomFound: Bool = false, note: String = "") {
        let a = simd_normalize(axis)
        self.axis = a
        base = point - a * simd_dot(point, a)
        self.radius = radius
        self.t0 = Swift.min(t0, t1)
        self.t1 = Swift.max(t0, t1)
        self.radiusGiven = radiusGiven
        self.lengthGiven = lengthGiven
        self.topFound = topFound
        self.bottomFound = bottomFound
        self.note = note
    }

    public var length: Double { t1 - t0 }
    public var volume: Double { Double.pi * radius * radius * length }

    /// Distance outside the cylinder (negative inside).
    @inline(__always) public func outside(_ p: SIMD3<Double>) -> Double {
        let t = simd_dot(p, axis)
        let d = p - base - axis * t
        let r = simd_length(d)
        return Swift.max(r - radius, Swift.max(t0 - t, t - t1))
    }

    /// The same cylinder as an envelope for the missing-material search.
    public var envelope: PlacedEnvelope {
        let centre = base + axis * ((t0 + t1) / 2)
        return PlacedEnvelope(kind: .cylinder, center: centre, axes: [axis], half: SIMD3(radius, length / 2, 0),
                              given: radiusGiven, note: note)
    }

    static func basis(_ a: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let helper: SIMD3<Double> = abs(a.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(simd_cross(a, helper))
        return (u, simd_cross(a, u))
    }

    /// The inside of the mould, sampled about `h` apart: the wall and both ends, with normals pointing into the
    /// cylinder (the way a surface touching a piece's outside faces).
    func mould(spacing h: Double) -> (points: [SIMD3<Double>], normals: [SIMD3<Double>]) {
        let (u, v) = Self.basis(axis)
        var P: [SIMD3<Double>] = [], N: [SIMD3<Double>] = []
        let around = Swift.max(12, Int(2 * Double.pi * radius / h))
        let along = Swift.max(2, Int(length / h))
        for k in 0..<around {
            let th = 2 * Double.pi * Double(k) / Double(around)
            let d = u * cos(th) + v * sin(th)
            for j in 0...along {
                let t = t0 + length * Double(j) / Double(along)
                P.append(base + axis * t + d * radius)
                N.append(-d)
            }
        }
        let rings = Swift.max(1, Int(radius / h))
        for i in 0...rings {
            let r = radius * Double(i) / Double(rings)
            let m = Swift.max(1, Int(2 * Double.pi * r / h))
            for k in 0..<m {
                let th = 2 * Double.pi * Double(k) / Double(m)
                let d = u * cos(th) + v * sin(th)
                P.append(base + axis * t0 + d * r)
                N.append(axis)
                P.append(base + axis * t1 + d * r)
                N.append(-axis)
            }
        }
        return (P, N)
    }

    /// Places the cylinder on the piece whose outside was found on it.
    /// - Parameters:
    ///   - floorY: height of the table the piece lay on (scan frame, +Y up), used as the bottom end when the axis
    ///     stands upright and the piece sits on the table with no bottom face seen.
    ///   - volumeNeeded: total volume of all pieces; with no length given, an unseen end is moved out until the
    ///     cylinder can hold them.
    public static func fit(anchor p: Piece, patch: CylinderPatch, radiusGiven: Bool, length givenL: Double?,
                           floorY: Double?, volumeNeeded: Double) -> CoreCylinder {
        var a = simd_normalize(patch.axis)
        if a.y < 0 { a = -a }
        let h = p.spacing
        let ts = p.points.map { simd_dot($0, a) }.sorted()
        let lo = ts[Swift.min(ts.count - 1, Int(Double(ts.count - 1) * 0.005))]
        let hi = ts[Swift.min(ts.count - 1, Int(Double(ts.count - 1) * 0.995))]
        var topT: [Double] = [], bottomT: [Double] = []
        for i in p.points.indices {
            let t = simd_dot(p.points[i], a), c = simd_dot(p.normals[i], a)
            if c > 0.9 && t > hi - 2 * h { topT.append(t) }
            if c < -0.9 && t < lo + 2 * h { bottomT.append(t) }
        }
        let top: Double? = topT.count >= 20 ? ScanMath.median(topT) : nil
        var bottom: Double? = bottomT.count >= 20 ? ScanMath.median(bottomT) : nil
        var onTable = false
        if bottom == nil, let fy = floorY, a.y > 0.95 {
            // Standing on its end on the table: the table is the bottom end.
            // Where the axis meets the table.
            let b0 = patch.centre - a * simd_dot(patch.centre, a)
            let tFloor = (fy - b0.y) / a.y
            if abs(tFloor - lo) < Swift.max(0.003, 3 * h) {
                bottom = Swift.min(tFloor, lo)
                onTable = true
            }
        }
        var t0: Double, t1: Double
        var note: String
        switch (top, bottom) {
        case let (tt?, tb?):
            t0 = tb
            t1 = tt
            note = onTable ? "top end found on the largest piece, bottom end on the table it stood on" : "both ends found on the largest piece"
            if let L = givenL, abs((tt - tb) - L) > 0.002 { note += " (they are \(Int(((tt - tb) * 1000).rounded())) mm apart, not the given \(Int((L * 1000).rounded())) mm)" }
        case let (tt?, nil):
            t1 = tt
            t0 = givenL.map { tt - $0 } ?? lo
            note = "top end found on the largest piece; " + (givenL != nil ? "the bottom placed at the given length" : "the bottom end is a guess")
        case let (nil, tb?):
            t0 = tb
            t1 = givenL.map { tb + $0 } ?? hi
            note = "bottom end found on the largest piece; " + (givenL != nil ? "the top placed at the given length" : "the top end is a guess")
        case (nil, nil):
            t0 = lo
            t1 = hi
            if let L = givenL {
                let m = (lo + hi) / 2
                t0 = m - L / 2
                t1 = m + L / 2
            }
            note = "no flat end found: the length position is a guess"
        }
        // With no length given, an end that wasn't seen moves out until the pieces fit in.
        if givenL == nil {
            let need = volumeNeeded / (Double.pi * patch.radius * patch.radius)
            if t1 - t0 < need {
                if top != nil && bottom == nil { t0 = t1 - need } else if bottom != nil && top == nil { t1 = t0 + need }
            }
        }
        return CoreCylinder(axis: a, through: patch.centre, radius: patch.radius, t0: t0, t1: t1, radiusGiven: radiusGiven,
                            lengthGiven: givenL != nil, topFound: top != nil, bottomFound: bottom != nil, note: note)
    }
}

public enum CylinderFinder {
    /// Circle through three 2-D points.
    static func circle3(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ r: SIMD2<Double>) -> (centre: SIMD2<Double>, radius: Double)? {
        let A = [2 * p.x, 2 * p.y, 1, 2 * q.x, 2 * q.y, 1, 2 * r.x, 2 * r.y, 1]
        let b = [simd_length_squared(p), simd_length_squared(q), simd_length_squared(r)]
        guard let s = LinearSolve.solve(A, b, n: 3) else { return nil }
        let r2 = s[2] + s[0] * s[0] + s[1] * s[1]
        guard r2 > 0, r2.isFinite else { return nil }
        return (SIMD2(s[0], s[1]), r2.squareRoot())
    }

    /// Least-squares circle; with `radius` given only the centre moves.
    static func circleLS(_ pts: [SIMD2<Double>], start: SIMD2<Double>, radius: Double?) -> (centre: SIMD2<Double>, radius: Double)? {
        guard pts.count >= 3 else { return nil }
        if let R = radius {
            var c = start
            for _ in 0..<12 {
                var step = SIMD2<Double>.zero
                for q in pts {
                    let d = q - c
                    let l = simd_length(d)
                    guard l > 0 else { continue }
                    step += d / l * (l - R)
                }
                c += step / Double(pts.count)
            }
            return (c, R)
        }
        var A = [Double](repeating: 0, count: 9), b = [Double](repeating: 0, count: 3)
        for q in pts {
            let row = [2 * q.x, 2 * q.y, 1.0]
            let rhs = simd_length_squared(q)
            for i in 0..<3 {
                b[i] += row[i] * rhs
                for j in 0..<3 { A[i * 3 + j] += row[i] * row[j] }
            }
        }
        guard let s = LinearSolve.solve(A, b, n: 3) else { return nil }
        let r2 = s[2] + s[0] * s[0] + s[1] * s[1]
        guard r2 > 0, r2.isFinite else { return nil }
        return (SIMD2(s[0], s[1]), r2.squareRoot())
    }

    /// Eigenvector of the smallest eigenvalue of a symmetric 3×3 matrix (Jacobi rotations).
    static func smallestEigenvector(_ m: [[Double]]) -> SIMD3<Double> {
        var a = m
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<60 {
            var p = 0, q = 1
            var big = abs(a[0][1])
            if abs(a[0][2]) > big { p = 0; q = 2; big = abs(a[0][2]) }
            if abs(a[1][2]) > big { p = 1; q = 2; big = abs(a[1][2]) }
            let scale = abs(a[0][0]) + abs(a[1][1]) + abs(a[2][2])
            if big <= 1e-14 * scale || big == 0 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let sign: Double = theta >= 0 ? 1 : -1
            let t = sign / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        var best = 0
        for i in 1..<3 where a[i][i] < a[best][best] { best = i }
        return simd_normalize(SIMD3(v[0][best], v[1][best], v[2][best]))
    }

    /// Finds the largest patch of the piece's surface lying on a cylinder (of the given radius, if any): random
    /// axes from pairs of normals, circles through three side samples, best by count of samples on the circle
    /// with outward normals; then the axis and circle are refined on those samples.
    public static func fit(_ p: Piece, radius givenR: Double?, attempts: Int = 160, seed: UInt64 = 3) -> CylinderPatch? {
        let n = p.points.count
        guard n >= 40 else { return nil }
        var rng = SplitMix64(seed: seed &+ UInt64(p.id) &* 977)
        let tol = Swift.max(0.35 * p.spacing, 0.0004)
        let size = p.maxExtent
        var bestCount = 0
        var best: (axis: SIMD3<Double>, centre: SIMD2<Double>, radius: Double)?

        func members(axis a: SIMD3<Double>, centre c: SIMD2<Double>, radius r: Double) -> [Int] {
            let (u, v) = CoreCylinder.basis(a)
            var out: [Int] = []
            for i in 0..<n where abs(simd_dot(p.normals[i], a)) < 0.25 {
                let f = SIMD2(simd_dot(p.points[i], u), simd_dot(p.points[i], v))
                let d = f - c
                let l = simd_length(d)
                guard l > 0, abs(l - r) < tol else { continue }
                let radial = u * (d.x / l) + v * (d.y / l)
                if simd_dot(p.normals[i], radial) > 0.8 { out.append(i) }
            }
            return out
        }

        for _ in 0..<attempts {
            let i = Int(rng.next() % UInt64(n)), j = Int(rng.next() % UInt64(n))
            let cr = simd_cross(p.normals[i], p.normals[j])
            guard simd_length(cr) > 0.3 else { continue }
            let a = simd_normalize(cr)
            let (u, v) = CoreCylinder.basis(a)
            var side: [Int] = []
            for k in 0..<n where abs(simd_dot(p.normals[k], a)) < 0.25 { side.append(k) }
            guard side.count >= 30 else { continue }
            let flat = side.map { SIMD2(simd_dot(p.points[$0], u), simd_dot(p.points[$0], v)) }
            for _ in 0..<20 {
                let k0 = Int(rng.next() % UInt64(side.count))
                let k1 = Int(rng.next() % UInt64(side.count))
                let k2 = Int(rng.next() % UInt64(side.count))
                guard k0 != k1, k1 != k2, k0 != k2, let c = circle3(flat[k0], flat[k1], flat[k2]) else { continue }
                if let R = givenR {
                    guard abs(c.radius - R) < 0.12 * R else { continue }
                } else {
                    guard c.radius > 3 * p.spacing, c.radius < 2 * size else { continue }
                }
                var count = 0
                for (k, idx) in side.enumerated() {
                    let d = flat[k] - c.centre
                    let l = simd_length(d)
                    guard l > 0, abs(l - c.radius) < tol else { continue }
                    let radial = u * (d.x / l) + v * (d.y / l)
                    if simd_dot(p.normals[idx], radial) > 0.8 { count += 1 }
                }
                if count > bestCount {
                    bestCount = count
                    best = (a, c.centre, givenR ?? c.radius)
                }
            }
        }
        guard var fit = best, bestCount >= 20 else { return nil }
        var inl = members(axis: fit.axis, centre: fit.centre, radius: fit.radius)
        for _ in 0..<3 {
            guard inl.count >= 20 else { break }
            var m: [[Double]] = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
            for i in inl {
                let q = p.normals[i]
                let c: [Double] = [q.x, q.y, q.z]
                for r in 0..<3 { for s in 0..<3 { m[r][s] += c[r] * c[s] } }
            }
            var a = smallestEigenvector(m)
            if simd_dot(a, fit.axis) < 0 { a = -a }
            let (u, v) = CoreCylinder.basis(a)
            // The old centre, expressed in the new plane.
            let (u0, v0) = CoreCylinder.basis(fit.axis)
            let c3 = u0 * fit.centre.x + v0 * fit.centre.y
            let start = SIMD2(simd_dot(c3, u), simd_dot(c3, v))
            let flat = inl.map { SIMD2(simd_dot(p.points[$0], u), simd_dot(p.points[$0], v)) }
            guard let c = circleLS(flat, start: start, radius: givenR) else { break }
            if givenR == nil && !(c.radius > 3 * p.spacing && c.radius < 2 * size) { break }
            fit = (a, c.centre, c.radius)
            let next = members(axis: a, centre: c.centre, radius: c.radius)
            if next.count < inl.count / 2 { break }
            inl = next
        }
        guard inl.count >= 20 else { return nil }
        let (u, v) = CoreCylinder.basis(fit.axis)
        var bins = Set<Int>()
        for i in inl {
            let f = SIMD2(simd_dot(p.points[i], u), simd_dot(p.points[i], v)) - fit.centre
            let ang = atan2(f.y, f.x) * 180 / Double.pi
            bins.insert(Int(((ang + 180) / 10).rounded(.down)) % 36)
        }
        let centre3 = u * fit.centre.x + v * fit.centre.y
        return CylinderPatch(axis: fit.axis, centre: centre3, radius: fit.radius, members: inl,
                             share: Double(inl.count) / Double(n), arcDegrees: Double(bins.count) * 10)
    }
}

// MARK: - Fitting pieces into the cylinder

public struct MouldParams: Sendable {
    /// Arrangements kept alive.
    public var beam = 3
    /// Places tried for each piece in each arrangement.
    public var branch = 2
    /// A piece is put in only with at least this fit (share of its surface touching the mould or other pieces,
    /// lowered by any overlap or poking out).
    public var acceptScore = 0.12
    public var wallSpins = 24
    public var wallHeights = 3
    public var endSpins = 12
    public var faceSpins = 12
    public var directions = 20
    public var spins = 6
    public var voidCentres = 3
    public var preIterations = 8
    public var preSamples = 250
    public var keepAfterPre = 6
    public var iterations = 18
    /// After this, arrangements are no longer branched (the phone must not work for minutes).
    public var maxSeconds = 90.0
    public init() {}
}

public enum MouldAssembler {
    public struct Fit: Sendable {
        public var pose: Pose
        public var score: Double
        public var contact: Double
        public var outside: Double
        public var overlap: Double
    }

    struct State {
        var poses: [Int: Pose]
        var order: [Int]
        var total: Double
        var fits: [Int: Fit]
        var ambiguity: [Int: Double]
    }

    final class Context {
        let F: [Int: Piece]
        let cyl: CoreCylinder
        let h: Double
        let mouldP: [SIMD3<Double>]
        let mouldN: [SIMD3<Double>]
        let params: MouldParams
        let pairs: [String: PairMatch]
        var flats: [Int: [Piece.Facet]] = [:]
        var patches: [Int: CylinderPatch?] = [:]

        init(F: [Int: Piece], cyl: CoreCylinder, h: Double, params: MouldParams, pairs: [String: PairMatch]) {
            self.F = F
            self.cyl = cyl
            self.h = h
            self.params = params
            self.pairs = pairs
            let m = cyl.mould(spacing: h)
            mouldP = m.points
            mouldN = m.normals
        }

        func flatFaces(_ p: Piece) -> [Piece.Facet] {
            if let f = flats[p.id] { return f }
            let all = Piece.regionGrow(p, members: Array(p.points.indices), maxAngle: 12, planeTolerance: 0.6 * p.spacing)
                .filter { $0.area > 0.06 * p.surfaceArea }
                .sorted { $0.area > $1.area }
            let f = Array(all.prefix(4))
            flats[p.id] = f
            return f
        }

        func patch(_ p: Piece) -> CylinderPatch? {
            if let c = patches[p.id] { return c }
            var c = CylinderFinder.fit(p, radius: cyl.radius, attempts: 100)
            if let x = c, x.share < 0.08 { c = nil }
            patches[p.id] = c
            return c
        }

        func near(_ a: Piece, _ Wa: Pose, _ b: Piece, _ Wb: Pose) -> Bool {
            simd_length(Wa.apply(a.centroid) - Wb.apply(b.centroid)) < a.radius + b.radius + 3 * Swift.max(a.spacing, b.spacing)
        }

        /// The surface a new piece may touch: the mould and every piece already in place.
        func target(_ st: State) -> (tree: KDTree, normals: [SIMD3<Double>]) {
            var P = mouldP, N = mouldN
            for (id, W) in st.poses {
                guard let q = F[id] else { continue }
                P += q.points.map { W.apply($0) }
                N += q.normals.map { W.rotate($0) }
            }
            return (KDTree(P), N)
        }

        func evaluate(_ p: Piece, _ W: Pose, _ st: State, tree: KDTree, normals: [SIMD3<Double>], step: Int) -> Fit {
            let hh = Swift.max(p.spacing, h)
            let sigma = 0.3 * hh
            var sum = 0.0
            var count = 0
            var outS = 0
            var i = 0
            while i < p.points.count {
                let q = W.apply(p.points[i])
                count += 1
                if cyl.outside(q) > 2.5 * hh { outS += 1 }
                if let nn = tree.nearest(q, maxDistance: 2 * hh) {
                    let m = normals[nn.index]
                    if simd_dot(W.rotate(p.normals[i]), m) < -0.5 {
                        let d = abs(simd_dot(q - tree.points[nn.index], m)) / sigma
                        sum += exp(-0.5 * d * d)
                    }
                }
                i += step
            }
            let contact = sum / Double(Swift.max(1, count))
            var outI = 0
            for q in p.interior where cyl.outside(W.apply(q)) > 1.5 * hh { outI += 1 }
            let shareI = p.interior.isEmpty ? 0 : Double(outI) / Double(p.interior.count)
            let shareS = Double(outS) / Double(Swift.max(1, count))
            // Scan debris (table remnants, a few stray triangles) may stick out a little.
            let out = Swift.max(0, Swift.max(shareI, shareS) - 0.02)
            var pen = 0.0
            for (id, Wq) in st.poses where id != p.id {
                guard let q = F[id], near(p, W, q, Wq) else { continue }
                let rel = Wq.inverse.compose(W)
                let tol = 1.5 * Swift.max(p.spacing, q.spacing)
                pen = Swift.max(pen, Self.penetration(p, rel, q, tol: tol, step: step), Self.penetration(q, rel.inverse, p, tol: tol, step: step))
            }
            pen = Swift.max(0, pen - 0.01)
            let score = contact * exp(-(out + pen) / 0.03)
            return Fit(pose: W, score: score, contact: contact, outside: out, overlap: pen)
        }

        /// Share of `src`'s interior samples (every `step`-th) lying deeper than `tol` inside `tgt`.
        static func penetration(_ src: Piece, _ T: Pose, _ tgt: Piece, tol: Double, step: Int) -> Double {
            guard !src.interior.isEmpty else { return 0 }
            let lo = tgt.lo - SIMD3(repeating: tol), hi = tgt.hi + SIMD3(repeating: tol)
            var inside = 0, count = 0
            var i = 0
            while i < src.interior.count {
                let q = T.apply(src.interior[i])
                count += 1
                i += step
                if q.x < lo.x || q.y < lo.y || q.z < lo.z || q.x > hi.x || q.y > hi.y || q.z > hi.z { continue }
                if tgt.signedDistance(q) < -tol { inside += 1 }
            }
            return Double(inside) / Double(Swift.max(1, count))
        }

        /// Centres of the empty part of the cylinder: the middle of all of it, then up to `k` clusters.
        func voidCentres(_ st: State, k: Int) -> [SIMD3<Double>] {
            let (u, v) = CoreCylinder.basis(cyl.axis)
            let cell = Swift.max(h, 2 * cyl.radius / 24)
            var empty: [SIMD3<Double>] = []
            var t = cyl.t0 + cell / 2
            let placed = st.poses.compactMap { id, W -> (Piece, Pose, Pose)? in F[id].map { ($0, W, W.inverse) } }
            while t < cyl.t1 {
                var x = -cyl.radius + cell / 2
                while x < cyl.radius {
                    var y = -cyl.radius + cell / 2
                    while y < cyl.radius {
                        if x * x + y * y <= cyl.radius * cyl.radius {
                            let c = cyl.base + cyl.axis * t + u * x + v * y
                            var inside = false
                            for (q, W, Wi) in placed where simd_length(c - W.apply(q.centroid)) < q.radius + cell {
                                if q.signedDistance(Wi.apply(c)) < 0 { inside = true; break }
                            }
                            if !inside { empty.append(c) }
                        }
                        y += cell
                    }
                    x += cell
                }
                t += cell
            }
            guard !empty.isEmpty else { return [cyl.base + cyl.axis * ((cyl.t0 + cyl.t1) / 2)] }
            var out = [empty.centroid]
            let kk = Swift.min(k, empty.count)
            guard kk > 0 else { return out }
            var C = (0..<kk).map { empty[($0 * empty.count) / kk + (empty.count / kk) / 2] }
            for _ in 0..<8 {
                var sums = [SIMD3<Double>](repeating: .zero, count: kk), counts = [Int](repeating: 0, count: kk)
                for e in empty {
                    var b = 0
                    var bd = Double.infinity
                    for (j, c) in C.enumerated() {
                        let d = simd_length_squared(e - c)
                        if d < bd { bd = d; b = j }
                    }
                    sums[b] += e
                    counts[b] += 1
                }
                for j in 0..<kk where counts[j] > 0 { C[j] = sums[j] / Double(counts[j]) }
            }
            for c in C where !out.contains(where: { simd_length($0 - c) < 2 * h }) { out.append(c) }
            return out
        }

        /// Starting poses for piece p (from its scan frame into the cylinder's frame).
        func starts(_ p: Piece, _ st: State, centres: [SIMD3<Double>]) -> [Pose] {
            var S: [Pose] = []
            let A = cyl.axis
            // 1. Its own piece of the cylinder's outside onto the wall, turned round the axis and slid along it.
            if let pt = patch(p) {
                for sgn in [1.0, -1.0] {
                    let R0 = Pose.align(simd_normalize(pt.axis) * sgn, to: A)
                    for k in 0..<params.wallSpins {
                        let Rs = Pose.rotation(axis: A, degrees: 360 * Double(k) / Double(params.wallSpins)) * R0
                        let c2 = Rs * pt.centre
                        let perp = c2 - A * simd_dot(c2, A)
                        var lo = Double.infinity, hi = -Double.infinity
                        for q in p.points {
                            let t = simd_dot(Rs * q, A)
                            lo = Swift.min(lo, t)
                            hi = Swift.max(hi, t)
                        }
                        let free = Swift.max(0, cyl.length - (hi - lo))
                        for f in 0..<params.wallHeights {
                            let share = params.wallHeights > 1 ? Double(f) / Double(params.wallHeights - 1) : 0.5
                            let at = cyl.t0 + share * free
                            S.append(Pose(R: Rs, t: cyl.base - perp + A * (at - lo)))
                        }
                    }
                }
            }
            let flats = flatFaces(p)
            // 2. A flat face onto either end of the cylinder.
            for f in flats {
                for (dir, tEnd) in [(A, cyl.t1), (-A, cyl.t0)] {
                    let R0 = Pose.align(f.normal, to: dir)
                    for k in 0..<params.endSpins {
                        let Rs = Pose.rotation(axis: A, degrees: 360 * Double(k) / Double(params.endSpins)) * R0
                        for c in centres.prefix(params.voidCentres) {
                            var t = c - Rs * p.centroid
                            t += A * (tEnd - simd_dot(Rs * f.centroid + t, A))
                            S.append(Pose(R: Rs, t: t))
                        }
                    }
                }
            }
            // 3. A flat face against a flat face of a piece already in place, and the pair matches with it.
            for (id, Wq) in st.poses {
                guard let q = F[id] else { continue }
                for fq in flatFaces(q) {
                    let nq = Wq.rotate(fq.normal), cq = Wq.apply(fq.centroid)
                    for f in flats {
                        let r = f.area / fq.area
                        guard r > 0.25 && r < 4 else { continue }
                        let R0 = Pose.align(f.normal, to: -nq)
                        for k in 0..<params.faceSpins {
                            let Rs = Pose.rotation(axis: nq, degrees: 360 * Double(k) / Double(params.faceSpins)) * R0
                            S.append(Pose(R: Rs, t: cq - Rs * f.centroid))
                        }
                    }
                }
                for c in PieceAssembler.candidates(pairs, p.id, id) where c.score > 0 { S.append(Wq.compose(c.pose)) }
            }
            // 4. Any way round, in the middle of the empty space.
            let n = params.directions
            for i in 0..<n {
                let z = 1 - 2 * (Double(i) + 0.5) / Double(n)
                let r = (1 - z * z).squareRoot()
                let th = Double.pi * (1 + 5.0.squareRoot()) * Double(i)
                let d = SIMD3(cos(th) * r, sin(th) * r, z)
                let R0 = Pose.align(SIMD3(0, 0, 1), to: d)
                for k in 0..<params.spins {
                    let Rs = Pose.rotation(axis: d, degrees: 360 * Double(k) / Double(params.spins)) * R0
                    for c in centres.prefix(params.voidCentres) { S.append(Pose(R: Rs, t: c - Rs * p.centroid)) }
                }
            }
            return S
        }

        func distinct(_ list: [Fit], piece p: Piece, limit: Int) -> [Fit] {
            let probe = spreadIndices(p.points.count, want: 150).map { p.points[$0] }
            var keep: [Fit] = []
            for c in list {
                if keep.contains(where: { Pose.displacement($0.pose, c.pose, points: probe) < 2.5 * p.spacing }) { continue }
                keep.append(c)
                if keep.count >= limit { break }
            }
            return keep
        }

        /// The best distinct places for piece p in arrangement st, best first.
        func place(_ p: Piece, _ st: State) -> [Fit] {
            let (tree, normals) = target(st)
            let centres = voidCentres(st, k: params.voidCentres)
            let hh = Swift.max(p.spacing, h)
            let sub = spreadIndices(p.points.count, want: params.preSamples)
            let sp = sub.map { p.points[$0] }, sn = sub.map { p.normals[$0] }
            let sw = [Double](repeating: 1, count: sub.count)
            var pre: [Fit] = []
            for s in starts(p, st, centres: centres) {
                let T = PieceMatcher.contactICP(src: sp, srcN: sn, srcW: sw, tree: tree, tgtN: normals, start: s, h: hh,
                                                iterations: params.preIterations, sigma: 0.3 * hh)
                pre.append(evaluate(p, T, st, tree: tree, normals: normals, step: 3))
            }
            pre.sort { $0.score > $1.score }
            let seeds = distinct(pre, piece: p, limit: params.keepAfterPre)
            let all = [Double](repeating: 1, count: p.points.count)
            var refined: [Fit] = []
            for s in seeds {
                let T = PieceMatcher.contactICP(src: p.points, srcN: p.normals, srcW: all, tree: tree, tgtN: normals, start: s.pose, h: hh,
                                                iterations: params.iterations, dStart: 3, dEnd: 1.2, sigma: 0.3 * hh)
                let e = evaluate(p, T, st, tree: tree, normals: normals, step: 1)
                refined.append(e.score >= s.score ? e : evaluate(p, s.pose, st, tree: tree, normals: normals, step: 1))
            }
            refined.sort { $0.score > $1.score }
            return distinct(refined, piece: p, limit: 4)
        }

        func samePose(_ id: Int, _ a: Pose, _ b: Pose) -> Bool {
            guard let p = F[id] else { return false }
            return PieceAssembler.samePose(p, a, b)
        }
    }

    /// Fits the pieces into the cylinder, starting from the anchor (the piece the cylinder was fitted to, kept where
    /// it lay). Poses move each piece from the scan frame into the anchor's (scan) frame.
    public static func assemble(_ pieces: [Piece], anchor: Int, cylinder: CoreCylinder, pairs: [String: PairMatch] = [:],
                                params: MouldParams = MouldParams(), progress: ((Double, String) -> Void)? = nil) -> AssemblyResult {
        let F = Dictionary(uniqueKeysWithValues: pieces.map { ($0.id, $0) })
        let spacings = pieces.map { $0.spacing }.sorted()
        let h = spacings.isEmpty ? 0.001 : spacings[spacings.count / 2]
        let ctx = Context(F: F, cyl: cylinder, h: h, params: params, pairs: pairs)
        let others = pieces.filter { $0.id != anchor }.sorted { $0.volume > $1.volume }
        let started = Date()
        var beam = [State(poses: [anchor: .identity], order: [anchor], total: 0, fits: [:], ambiguity: [:])]
        var finished: [State] = []
        var bestSeen: [Int: Double] = [:]
        var branch = params.branch
        var width = params.beam

        for depth in 0..<others.count {
            var kids: [State] = []
            for (b, st) in beam.enumerated() {
                var grew = false
                let left = others.filter { st.poses[$0.id] == nil }
                for (k, p) in left.enumerated() {
                    let f = (Double(depth) + (Double(b) + Double(k + 1) / Double(left.count)) / Double(beam.count)) / Double(others.count)
                    progress?(Swift.min(1, f), "Fitting the pieces into the cylinder (P\(p.id))…")
                    let cands = ctx.place(p, st)
                    guard let top = cands.first else { continue }
                    bestSeen[p.id] = Swift.max(bestSeen[p.id] ?? 0, top.score)
                    let amb = cands.count > 1 && top.score > 0 ? cands[1].score / top.score : 0
                    for c in cands.prefix(branch) where c.score >= params.acceptScore {
                        var s = st
                        s.poses[p.id] = c.pose
                        s.order.append(p.id)
                        s.total += c.score
                        s.fits[p.id] = c
                        s.ambiguity[p.id] = c.pose == top.pose ? amb : 1
                        kids.append(s)
                        grew = true
                    }
                }
                if !grew { finished.append(st) }
            }
            if kids.isEmpty { break }
            kids.sort { $0.total > $1.total }
            var next: [State] = []
            for s in kids {
                let dup = next.contains { t in
                    Set(t.poses.keys) == Set(s.poses.keys) && t.poses.allSatisfy { k, W in ctx.samePose(k, W, s.poses[k]!) }
                }
                if !dup { next.append(s) }
                if next.count >= width { break }
            }
            beam = next
            if Date().timeIntervalSince(started) > params.maxSeconds {
                branch = 1
                width = 1
                beam = Array(beam.prefix(1))
            }
        }
        finished += beam
        guard var best = finished.max(by: { ($0.poses.count, $0.total) < ($1.poses.count, $1.total) }) else {
            return AssemblyResult(placed: [:], unplaced: [:], clusters: [], score: 0, method: "cylinder", cylinder: cylinder)
        }

        // Each piece once more against the mould and all the others.
        progress?(1, "Checking the fit of each piece…")
        for k in best.order where k != anchor {
            guard let p = F[k], let W = best.poses[k] else { continue }
            var rest = best
            rest.poses[k] = nil
            let (tree, normals) = ctx.target(rest)
            let hh = Swift.max(p.spacing, h)
            let all = [Double](repeating: 1, count: p.points.count)
            let T = PieceMatcher.contactICP(src: p.points, srcN: p.normals, srcW: all, tree: tree, tgtN: normals, start: W, h: hh,
                                            iterations: 10, dStart: 2, dEnd: 1.2, sigma: 0.3 * hh)
            let e0 = ctx.evaluate(p, W, rest, tree: tree, normals: normals, step: 1)
            let e1 = ctx.evaluate(p, T, rest, tree: tree, normals: normals, step: 1)
            let e = e1.score > e0.score ? e1 : e0
            best.poses[k] = e.pose
            best.fits[k] = e
        }

        // Which pieces touch, and which pair matches agree with the arrangement.
        var placed: [Int: PlacedPiece] = [:]
        for k in best.order {
            guard let p = F[k], let W = best.poses[k] else { continue }
            var touches: [Int] = []
            var confirmed: [Int] = []
            for (j, Wj) in best.poses where j != k {
                guard let q = F[j], ctx.near(p, W, q, Wj) else { continue }
                let rel = Wj.inverse.compose(W)
                let c = PieceMatcher.contact(p, rel, q, sigma: PieceMatcher.sigma(p, q))
                if c.area > 0.02 * Swift.min(p.surfaceArea, q.surfaceArea) { touches.append(j) }
                if PieceAssembler.candidates(pairs, k, j).contains(where: { $0.score >= 0.02 && PieceAssembler.samePose(p, $0.pose, rel) }) {
                    confirmed.append(j)
                }
            }
            let fit = best.fits[k]
            placed[k] = PlacedPiece(id: k, pose: W, cluster: 0, role: k == anchor ? "anchor" : "placed", via: nil,
                                    gain: fit?.score ?? 0, penetration: fit?.overlap ?? 0, ambiguity: best.ambiguity[k] ?? 0,
                                    neighbours: touches.sorted(), confirmedBy: confirmed.sorted(), method: "cylinder",
                                    contact: fit?.contact, outside: fit?.outside)
        }
        var unplaced: [Int: String] = [:]
        for p in others where placed[p.id] == nil {
            let s = bestSeen[p.id] ?? 0
            unplaced[p.id] = s > 0
                ? String(format: "doesn't fit in the empty part of the cylinder without poking out or overlapping another piece (best fit %.2f); it may belong to another sample, or be scan debris", s)
                : "no place found for it in the cylinder"
        }
        return AssemblyResult(placed: placed, unplaced: unplaced, clusters: [best.order], score: best.total, method: "cylinder", cylinder: cylinder)
    }
}
