import Foundation
import simd

/// The reference mark drawn on a sample to record which side faced the X-ray source. That side is 0°.
/// In the DigitalSCAL convention it is one of:
/// - a line drawn along the sample (black, or red towards the top and black towards the bottom);
/// - a red mark at the top and a black mark at the bottom, on the same side, with nothing between;
/// - only one of them: a red mark at the top, or a black mark at the bottom.
/// Found in an unrolled image of the side surface. Written labels (sample numbers written along the sample) are
/// not marks: their strokes are bold and crowded together, while a mark line is thin with bare rock either side.
public struct MarkDetection: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A line with a red part (red part = top).
        case redBlackLine = "red_black_line"
        /// Red and black lines side by side; the angle is midway between them.
        case redBlackPair = "red_black_pair"
        case redLine = "red_line"
        case blackLine = "black_line"
        /// Red mark at one end and black mark at the other, on the same side, without a line between (3.8).
        case redBlackEnds = "red_black_ends"
        /// Short red mark only (a spot or tick, not a line).
        case redSpot = "red_spot"
        /// Short black mark at one end only (3.8).
        case blackSpot = "black_spot"
    }
    public enum RedEnd: String, Codable, Sendable { case top, bottom, unknown }

    /// Angle of the mark in the unrolled image's angle scale (degrees, as given by `columnAngles`).
    public var angle: Double
    public var kind: Kind
    /// 0…1. Below 0.35 the app asks the user to check the mark.
    public var confidence: Double
    /// Combined evidence score (line + red end + black end).
    public var contrast: Double
    /// Share of the sample height the line covers (0 for marks at the ends only).
    public var heightShare: Double
    /// Width of the mark, degrees.
    public var widthDegrees: Double
    /// Where the red part is along the sample as scanned (top = first image row). For a black end mark alone,
    /// the opposite end of it.
    public var redEnd: RedEnd
    /// One line on what was found, for the app log.
    public var detail: String?
    /// True when the red part is at the bottom: the sample was scanned upside down.
    public var upsideDown: Bool { redEnd == .bottom }
}

public enum MarkFinder {
    /// Colour classes of one pixel (values 0…1).
    @inline(__always) static func hsv(_ c: SIMD3<Float>) -> (h: Float, s: Float, v: Float) {
        let mx = Swift.max(c.x, Swift.max(c.y, c.z)), mn = Swift.min(c.x, Swift.min(c.y, c.z))
        let d = mx - mn
        var h: Float = 0
        if d > 1e-6 {
            if mx == c.x { h = 60 * ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.y { h = 60 * ((c.z - c.x) / d + 2) }
            else { h = 60 * ((c.x - c.y) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx > 1e-6 ? d / mx : 0, mx)
    }

    @inline(__always) static func isRed(_ c: SIMD3<Float>) -> Bool {
        let (h, s, v) = hsv(c)
        let hueRed: Bool = h <= 22 || h >= 335
        let strong: Bool = s >= 0.38 && v >= 0.18
        let other: Float = Swift.max(c.y, c.z)
        let lead: Float = c.x - other
        return hueRed && strong && lead >= 0.12
    }

    @inline(__always) static func luma(_ c: SIMD3<Float>) -> Float {
        let w = SIMD3<Float>(0.299, 0.587, 0.114)
        return (c * w).sum()
    }

    /// Robust spread (1.4826 × median absolute deviation).
    static func mad(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let m = ScanMath.median(a)
        return ScanMath.median(a.map { abs($0 - m) }) * 1.4826
    }

    /// A line candidate: the best near-vertical path ending at one column.
    struct LinePath {
        var x: Int
        var cover: Double
        var run: Double
        var clutter: Double
        var ink: Double
        var redShare: Double
        var strength: Double = 0
    }

    struct EndMark {
        var x: Int
        var px: Double
        /// 0 = top of the sample, 1 = bottom.
        var pos: Double
        var top: Bool
        /// Share of the sample height it covers.
        var span: Double = 0
    }

    /// Finds the mark in an unrolled side image.
    /// - Parameters:
    ///   - rgb: row-major pixels, row 0 = top of the sample, values 0…1.
    ///   - valid: optional mask (false = background or no surface).
    ///   - columnAngles: angle of each column (degrees); default 0…360 evenly.
    ///   - circumferenceMM: the sample's circumference when known, so sizes can be judged in millimetres.
    public static func detect(rgb: [SIMD3<Float>], width: Int, height: Int, valid: [Bool]? = nil,
                              columnAngles: [Double]? = nil, circumferenceMM: Double? = nil) -> MarkDetection? {
        let W = width, H = height
        guard W >= 24, H >= 8, rgb.count == W * H else { return nil }
        var angles: [Double] = []
        if let given = columnAngles, given.count == W {
            angles = given
        } else {
            for x in 0..<W { angles.append((Double(x) + 0.5) * 360 / Double(W)) }
        }
        let degPerCol = 360.0 / Double(W)
        let ppm: Double = {
            if let c = circumferenceMM, c > 1 { return Double(W) / c }
            return Double(W) / 80
        }()
        func ok(_ i: Int) -> Bool { valid?[i] ?? true }
        func wrap(_ x: Int) -> Int { ((x % W) + W) % W }

        // Rows of the sample, end caps left out.
        var rowValid = [Bool](repeating: false, count: H)
        for y in 0..<H {
            var n = 0
            for x in 0..<W where ok(y * W + x) { n += 1 }
            rowValid[y] = n * 2 > W
        }
        guard let y0 = rowValid.firstIndex(of: true), let y1 = rowValid.lastIndex(of: true), y1 - y0 >= 8 else { return nil }
        let trim = Int(0.03 * Double(y1 - y0))
        var use = [Bool](repeating: false, count: H)
        for y in (y0 + trim)...(y1 - trim) where rowValid[y] { use[y] = true }
        let useRows: [Int] = (0..<H).filter { use[$0] }
        guard useRows.count >= 8 else { return nil }
        let nRows = Double(useRows.count)

        var L = [Float](repeating: 0, count: W * H)
        for i in 0..<(W * H) { L[i] = luma(rgb[i]) }

        // Per row: sums of valid luma over a circular window, from prefix sums.
        var D = [Float](repeating: 0, count: W * H)  // darker than the rock round it (± 3 mm)
        var R = [Float](repeating: 0, count: W * H)  // darker than both sides 0.6–1.6 mm away: a thin line
        let bh = Swift.max(3, Int((3 * ppm).rounded()))
        let i0 = Swift.max(1, Int((0.6 * ppm).rounded()))
        let i1 = Swift.max(i0 + 1, Int((1.6 * ppm).rounded()))
        var ps = [Double](repeating: 0, count: 3 * W + 1), pc = [Double](repeating: 0, count: 3 * W + 1)
        for y in 0..<H where rowValid[y] {
            // Prefix sums over the row repeated three times (x − W … x + 2W).
            for k in 0..<(3 * W) {
                let i = y * W + (k % W)
                let v = ok(i)
                ps[k + 1] = ps[k] + (v ? Double(L[i]) : 0)
                pc[k + 1] = pc[k] + (v ? 1 : 0)
            }
            func mean(_ a: Int, _ b: Int) -> Double? {
                // Columns a…b inclusive, may be negative or past W (a ≥ −W, b < 2W).
                let s = ps[b + W + 1] - ps[a + W], c = pc[b + W + 1] - pc[a + W]
                return c > 0 ? s / c : nil
            }
            for x in 0..<W {
                let i = y * W + x
                guard ok(i) else { continue }
                let l = Double(L[i])
                if let bg = mean(x - bh, x + bh) { D[i] = Float(bg - l) }
                if let left = mean(x - i1, x - i0), let right = mean(x + i0, x + i1) {
                    R[i] = Float(Swift.min(left, right) - l)
                }
            }
        }
        var dSample: [Double] = [], rSample: [Double] = []
        for y in useRows {
            for x in stride(from: 0, to: W, by: 3) where ok(y * W + x) {
                dSample.append(Double(D[y * W + x]))
                rSample.append(Double(R[y * W + x]))
            }
        }
        guard dSample.count > 50 else { return nil }
        let t: Float = Float(Swift.max(0.045, 4 * mad(dSample)))
        let tr: Float = Float(Swift.max(0.05, 2.5 * mad(rSample)))
        var hit = [Bool](repeating: false, count: W * H), dark = [Bool](repeating: false, count: W * H)
        var strong = [Bool](repeating: false, count: W * H), red = [Bool](repeating: false, count: W * H)
        for y in useRows {
            for x in 0..<W {
                let i = y * W + x
                guard ok(i) else { continue }
                hit[i] = R[i] > tr
                dark[i] = D[i] > t
                strong[i] = D[i] > 2 * t
                red[i] = isRed(rgb[i])
            }
        }

        // 1. Lines: best near-vertical path to each column (a sideways step costs a little), then the best
        // distinct paths.
        var score = [Double](repeating: 0, count: W)
        var back = [Int8](repeating: 0, count: W * H)
        let pen = 0.35
        for y in useRows {
            var next = [Double](repeating: 0, count: W)
            for x in 0..<W {
                let l: Double = score[wrap(x - 1)] - pen, c: Double = score[x], r: Double = score[wrap(x + 1)] - pen
                var best: Double = c
                var step: Int8 = 0
                if l > best { best = l; step = -1 }
                if r > best { best = r; step = 1 }
                back[y * W + x] = step
                next[x] = best + (hit[y * W + x] ? 1 : 0)
            }
            score = next
        }
        let sep = Swift.max(1, Int((8 / degPerCol).rounded()))
        func apart(_ a: Int, _ b: Int) -> Int { let d = abs(a - b); return Swift.min(d, W - d) }
        let ends = score.indices.sorted { score[$0] > score[$1] }.prefix(Swift.max(40, W / 10))
        var paths: [[Int]] = []   // x per use-row
        var lines: [LinePath] = []
        for e in ends {
            if lines.count >= 6 { break }
            var xs = [Int](repeating: 0, count: H)
            var x = e
            for y in stride(from: H - 1, through: 0, by: -1) {
                xs[y] = x
                if use[y] { x = wrap(x + Int(back[y * W + x])) }
            }
            // Median column of the path, counted from the end column so a path across the seam stays whole.
            let offs = useRows.map { Double(wrap(xs[$0] - e + W / 2) - W / 2) }
            let mx = wrap(e + Int(ScanMath.median(offs).rounded()))
            if lines.contains(where: { apart($0.x, mx) < sep }) { continue }
            var hits = 0, reds = 0, best = 0, runStart = 0, last = -1_000_000
            let bridge = Swift.max(2, Int(0.04 * nRows))
            for (k, y) in useRows.enumerated() {
                let i = y * W + xs[y]
                if hit[i] {
                    hits += 1
                    if red[i] { reds += 1 }
                    if k - last > bridge + 1 { runStart = k }
                    best = Swift.max(best, k - runStart + 1)
                    last = k
                }
            }
            lines.append(LinePath(x: mx, cover: Double(hits) / nRows, run: Double(best) / nRows, clutter: 0, ink: 0,
                                  redShare: hits > 0 ? Double(reds) / Double(hits) : 0))
            paths.append(xs)
        }
        // Clutter: thin dark strokes and dark ink 1–4 mm either side. A drawn line has bare rock there; a written
        // label does not. A red line beside a black one (a red/black pair) doesn't count against the other.
        let ca = Swift.max(2, Int((1 * ppm).rounded())), cb = Swift.max(ca + 2, Int((4 * ppm).rounded()))
        for j in lines.indices {
            let isRedLine = lines[j].redShare >= 0.5
            let partners = lines.indices.filter { $0 != j && (lines[$0].redShare >= 0.5) != isRedLine && lines[$0].run >= 0.5 }
            var n = 0, h = 0, d = 0
            for y in stride(from: 0, to: useRows.count, by: 2).map({ useRows[$0] }) {
                let cx = paths[j][y]
                for off in ca...cb {
                    for x in [wrap(cx - off), wrap(cx + off)] {
                        if partners.contains(where: { apart(paths[$0][y], x) <= i0 }) { continue }
                        let i = y * W + x
                        guard ok(i) else { continue }
                        n += 1
                        if hit[i] { h += 1 }
                        if dark[i] { d += 1 }
                    }
                }
            }
            lines[j].clutter = n > 0 ? Double(h) / Double(n) : 0
            lines[j].ink = n > 0 ? Double(d) / Double(n) : 0
            let iso = Swift.max(0, 1 - Swift.max(lines[j].clutter / 0.035, lines[j].ink / 0.06))
            let s = (0.5 * lines[j].cover + 0.5 * lines[j].run) * iso
            lines[j].strength = s >= 0.15 ? s : 0
        }

        // 2. Red marks: clusters of red pixels across about 3 mm.
        let rr = Swift.max(1, Int((1.5 * ppm).rounded()))
        let minPx = Swift.max(12, 0.4 * ppm * ppm)          // about 0.4 mm² of ink
        func smoothed(_ col: [Double]) -> [Double] {
            var out = [Double](repeating: 0, count: W)
            var s = 0.0
            for k in -rr...rr { s += col[wrap(k)] }
            for x in 0..<W {
                out[x] = s
                s += col[wrap(x + rr + 1)] - col[wrap(x - rr)]
            }
            return out
        }
        /// Centre of the ink round a peak of the smoothed counts (the peak itself sits anywhere on a plateau).
        func centre(_ col: [Double], _ x: Int) -> Int {
            var s = 0.0, w = 0.0
            for k in -rr...rr { let v = col[wrap(x + k)]; s += Double(k) * v; w += v }
            return w > 0 ? wrap(x + Int((s / w).rounded())) : x
        }
        var redCol = [Double](repeating: 0, count: W)
        for y in useRows { for x in 0..<W where red[y * W + x] { redCol[x] += 1 } }
        var redMarks: [EndMark] = []
        var rs = smoothed(redCol)
        for _ in 0..<3 {
            guard let peak = rs.indices.max(by: { rs[$0] < rs[$1] }), rs[peak] >= minPx else { break }
            let x = centre(redCol, peak)
            var sumY = 0.0, nY = 0.0, rowsWithRed = 0.0
            for y in useRows {
                var any = false
                for k in -rr...rr where red[y * W + wrap(x + k)] { sumY += Double(y); nY += 1; any = true }
                if any { rowsWithRed += 1 }
            }
            let pos = nY > 0 ? (sumY / nY - Double(y0)) / Double(Swift.max(1, y1 - y0)) : 0.5
            redMarks.append(EndMark(x: x, px: rs[peak], pos: pos, top: pos < 0.5, span: rowsWithRed / nRows))
            for k in -sep...sep { rs[wrap(peak + k)] = 0 }
        }

        // 3. Black end marks: a small, very dark mark in the top or bottom 22 % of the sample, at most 3.5 mm wide,
        // with no other ink round it.
        let zone = Swift.max(2, Int(0.22 * Double(y1 - y0)))
        var blackMarks: [EndMark] = []
        for (isTop, lo, hi) in [(true, y0, y0 + zone), (false, y1 - zone, y1 + 1)] {
            var col = [Double](repeating: 0, count: W)
            for y in lo..<Swift.min(H, hi) where use[y] { for x in 0..<W where strong[y * W + x] { col[x] += 1 } }
            var cs = smoothed(col)
            for _ in 0..<3 {
                guard let p = cs.indices.max(by: { cs[$0] < cs[$1] }), cs[p] >= minPx else { break }
                let peak = cs[p]
                for k in -sep...sep { cs[wrap(p + k)] = 0 }
                let x = centre(col, p)
                var wide = 0.0
                for k in -(4 * rr)...(4 * rr) { wide += col[wrap(x + k)] }
                // Width of the inked columns round the peak.
                var c0 = x
                if col[x] == 0, let k = (-rr...rr).first(where: { col[wrap(x + $0)] > 0 }) { c0 = wrap(x + k) }
                var lo2 = 0, hi2 = 0
                while lo2 < W / 4 && col[wrap(c0 - lo2 - 1)] > 0 { lo2 += 1 }
                while hi2 < W / 4 && col[wrap(c0 + hi2 + 1)] > 0 { hi2 += 1 }
                let widthMM = Double(lo2 + hi2 + 1) / ppm
                guard wide / Swift.max(peak, 1) <= 1.5, peak <= 8 * ppm * ppm, widthMM <= 3.5 else { continue }
                blackMarks.append(EndMark(x: x, px: peak, pos: isTop ? 0 : 1, top: isTop))
            }
        }

        // 4. Weigh the evidence at each candidate angle.
        let near = Swift.max(2, Int((4 / degPerCol).rounded()))
        struct Pick { var total: Double; var line: LinePath?; var red: [EndMark]; var black: [EndMark]; var anchor: Int }
        var chosen: Pick?
        let anchors = lines.filter { $0.strength > 0 }.map(\.x) + redMarks.map(\.x) + blackMarks.map(\.x)
        for a in anchors {
            let line = lines.filter { $0.strength > 0 && apart($0.x, a) <= near }.max { $0.strength < $1.strength }
            let reds = redMarks.filter { apart($0.x, a) <= near }
            let blacks = blackMarks.filter { apart($0.x, a) <= near }
            let rScore = reds.map { Swift.min(1, $0.px / (3 * minPx)) }.max() ?? 0
            let bScore = blacks.map { Swift.min(1, $0.px / (3 * minPx)) }.max() ?? 0
            let opposite = reds.contains { r in blacks.contains { $0.top != r.top } }
            let total = (line?.strength ?? 0) + 0.5 * rScore + 0.35 * bScore + (opposite ? 0.25 : 0)
            if chosen == nil || total > chosen!.total { chosen = Pick(total: total, line: line, red: reds, black: blacks, anchor: a) }
        }

        // A red line and a black line side by side, both full length: a deliberate pair, the angle is midway.
        var pairAngle: Double?
        let full = lines.filter { $0.strength > 0 && $0.run >= 0.5 }
        for a in full where a.redShare >= 0.5 {
            for b in full where b.redShare < 0.5 && apart(a.x, b.x) <= Int((25 / degPerCol).rounded()) {
                let total = Swift.max(Swift.min(a.strength, b.strength) + 0.5, chosen?.total ?? 0)
                if pairAngle == nil {
                    chosen = Pick(total: total, line: a, red: [], black: [], anchor: a.x)
                    pairAngle = circularMean(angles[a.x], angles[b.x])
                }
            }
        }

        guard let pick = chosen, pick.total >= 0.2 else { return nil }
        let kind: MarkDetection.Kind
        var redEnd: MarkDetection.RedEnd = .unknown
        let topRed = pick.red.max { $0.px < $1.px }
        // Which end the red is at, when it is at one end (a red line along the whole sample says nothing).
        if let r = topRed, r.span < 0.6, abs(r.pos - 0.5) > 0.1 { redEnd = r.top ? .top : .bottom }
        let angle: Double
        if let p = pairAngle {
            kind = .redBlackPair
            angle = p
        } else if let l = pick.line {
            angle = angles[l.x]
            if l.redShare >= 0.85 { kind = .redLine } else if l.redShare >= 0.1 || topRed != nil { kind = .redBlackLine } else { kind = .blackLine }
        } else if let r = topRed {
            if let b = pick.black.first(where: { $0.top != r.top }) {
                kind = .redBlackEnds
                angle = circularMean(angles[r.x], angles[b.x])
            } else {
                kind = .redSpot
                angle = angles[r.x]
            }
        } else if let b = pick.black.max(by: { $0.px < $1.px }) {
            kind = .blackSpot
            angle = angles[b.x]
            // Black marks the bottom: one at the top means the sample stood upside down.
            if Set(pick.black.map(\.top)).count == 1 { redEnd = b.top ? .bottom : .top }
        } else {
            return nil
        }
        var confidence = Swift.min(0.97, pick.total / 1.2)
        // A black mark alone is the weakest sign (a dark grain looks the same): usable, but the app asks to check.
        if kind == .blackSpot { confidence = 0.4 * Swift.min(1, pick.total / 0.35) }
        let lineText = pick.line.map { String(format: "line %.0f%% of the height (isolation clutter %.3f, ink %.3f)", $0.run * 100, $0.clutter, $0.ink) } ?? "no line"
        let detail = String(format: "%@; red mark %@; black end mark %@; score %.2f; %d line candidates",
                            lineText, topRed.map { $0.top ? "at the top" : "at the bottom" } ?? "none",
                            pick.black.first.map { $0.top ? "at the top" : "at the bottom" } ?? "none", pick.total, lines.count)
        return MarkDetection(angle: angle, kind: kind, confidence: confidence, contrast: pick.total,
                             heightShare: pick.line?.run ?? 0, widthDegrees: Double(2 * i0 + 1) * degPerCol,
                             redEnd: redEnd, detail: detail)
    }

    static func circularMean(_ a: Double, _ b: Double) -> Double {
        let ra: Double = a * .pi / 180, rb: Double = b * .pi / 180
        let x: Double = cos(ra) + cos(rb)
        let y: Double = sin(ra) + sin(rb)
        var m: Double = atan2(y, x) * 180 / .pi
        if m < 0 { m += 360 }
        return m
    }
}
