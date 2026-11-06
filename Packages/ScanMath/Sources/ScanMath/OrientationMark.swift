import Foundation
import simd

/// The pencil or marker line drawn on a sample to record which side faced the X-ray source (red towards the
/// top, black towards the bottom in the DigitalSCAL convention). Found in an unrolled image of the side surface.
public struct MarkDetection: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Red and black parts on one line (red part = top).
        case redBlackLine = "red_black_line"
        /// Red and black lines side by side; the angle is midway between them.
        case redBlackPair = "red_black_pair"
        case redLine = "red_line"
        case blackLine = "black_line"
        /// Short red mark (a spot or tick, not a line).
        case redSpot = "red_spot"
    }
    public enum RedEnd: String, Codable, Sendable { case top, bottom, unknown }

    /// Angle of the mark in the unrolled image's angle scale (degrees, as given by `columnAngles`).
    public var angle: Double
    public var kind: Kind
    /// 0…1. Below 0.35 the app asks the user to check the mark.
    public var confidence: Double
    /// How far the mark stands out from the rest of the circumference (robust z-score).
    public var contrast: Double
    /// Share of the sample height the mark covers.
    public var heightShare: Double
    /// Width of the mark, degrees.
    public var widthDegrees: Double
    /// Where the red part is along the sample as scanned (top = first image row).
    public var redEnd: RedEnd
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

    /// Finds the mark in an unrolled side image.
    /// - Parameters:
    ///   - rgb: row-major pixels, row 0 = top of the sample, values 0…1.
    ///   - valid: optional mask (false = background or no surface).
    ///   - columnAngles: angle of each column (degrees); default 0…360 evenly.
    ///   - circumferenceMM: the sample's circumference when known, so "narrow like a drawn line" can be judged in mm.
    public static func detect(rgb: [SIMD3<Float>], width: Int, height: Int, valid: [Bool]? = nil,
                              columnAngles: [Double]? = nil, circumferenceMM: Double? = nil) -> MarkDetection? {
        guard width >= 24, height >= 8, rgb.count == width * height else { return nil }
        var angles: [Double] = []
        if let given = columnAngles {
            angles = given
        } else {
            let w = Double(width)
            for x in 0..<width { angles.append((Double(x) + 0.5) * 360 / w) }
        }
        let degPerCol = 360.0 / Double(width)

        // Dark marker: clearly darker than this sample's own surface (works on light rock; weaker on shale).
        var lumas: [Double] = []
        lumas.reserveCapacity(rgb.count / 4 + 1)
        for i in stride(from: 0, to: rgb.count, by: 3) where valid?[i] ?? true { lumas.append(Double(luma(rgb[i]))) }
        guard lumas.count > 50 else { return nil }
        let medY = Float(ScanMath.median(lumas))
        let halfY: Float = 0.5 * medY
        let lowY: Float = medY - 0.12
        let darkLimit: Float = Swift.min(halfY, lowY)

        var red = [Double](repeating: 0, count: width), black = [Double](repeating: 0, count: width)
        var count = [Double](repeating: 0, count: width)
        var redRows = [[Int]](repeating: [], count: width), blackRows = [[Int]](repeating: [], count: width)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                if let v = valid, !v[i] { continue }
                let c = rgb[i]
                count[x] += 1
                if isRed(c) { red[x] += 1; redRows[x].append(y) }
                else {
                    let dark: Bool = luma(c) < darkLimit
                    let grey: Bool = hsv(c).s < 0.45
                    if dark && grey { black[x] += 1; blackRows[x].append(y) }
                }
            }
        }
        for x in 0..<width where count[x] > 0 { red[x] /= count[x]; black[x] /= count[x] }

        // Smooth round the circumference over about 3°.
        let half: Int = Swift.max(1, Int((1.5 / degPerCol).rounded()))
        let span: Double = Double(2 * half + 1)
        func smooth(_ a: [Double]) -> [Double] {
            var out: [Double] = []
            out.reserveCapacity(width)
            for x in 0..<width {
                var s = 0.0
                for k in -half...half { s += a[(x + k + width) % width] }
                out.append(s / span)
            }
            return out
        }
        let rs = smooth(red), bs = smooth(black)
        var score: [Double] = []
        for x in 0..<width { score.append(rs[x] + 0.8 * bs[x]) }
        let med = ScanMath.median(score)
        let dev: [Double] = score.map { abs($0 - med) }
        let mad: Double = ScanMath.median(dev) * 1.4826
        // Every stripe that stands out is a candidate (3.7). The darkest one is not always the mark: a written label
        // ("4002-2") has more ink than a thin drawn line. A drawn line is narrow and runs unbroken along the sample,
        // so each candidate is weighed by how narrow and how continuous it is.
        let minSep = Swift.max(1, Int((8 / degPerCol).rounded()))
        var candidates: [Int] = []
        for x in score.indices.sorted(by: { score[$0] > score[$1] }) {
            let r = score[x] - med
            if r < 0.02 || r / (mad + 0.004) < 4 { break }
            let apart = candidates.allSatisfy { c in
                let d = abs(c - x)
                return Swift.min(d, width - d) >= minSep
            }
            if apart { candidates.append(x) }
            if candidates.count >= 6 { break }
        }
        guard !candidates.isEmpty else { return nil }
        let maxLineDeg: Double = {
            guard let c = circumferenceMM, c > 0 else { return 12 }
            return Swift.max(4, Swift.min(14, 3.0 / (c / 360))) // about 3 mm
        }()
        let raw: [Double] = (0..<width).map { red[$0] + 0.8 * black[$0] }
        func halfWidth(_ p: Int) -> (lo: Int, hi: Int) {
            let level = med + (score[p] - med) / 2
            var lo = 0, hi = 0
            while lo < width / 4 && score[(p - lo - 1 + width) % width] >= level { lo += 1 }
            while hi < width / 4 && score[(p + hi + 1) % width] >= level { hi += 1 }
            return (lo, hi)
        }
        /// Longest stretch along the sample covered by the stripe's centre columns, short breaks bridged.
        func continuity(_ p: Int) -> Double {
            var centre = p
            for k in -half...half where raw[(p + k + width) % width] > raw[centre] { centre = (p + k + width) % width }
            let core = Swift.max(0, Int((0.75 / degPerCol).rounded()))
            var rows = Set<Int>()
            for k in -core...core {
                let x = (centre + k + width) % width
                rows.formUnion(redRows[x])
                rows.formUnion(blackRows[x])
            }
            let sorted = rows.sorted()
            guard var start = sorted.first else { return 0 }
            let bridge = Swift.max(1, height / 50)
            var prev = start, best = 1
            for y in sorted.dropFirst() {
                if y - prev > bridge + 1 { start = y }
                best = Swift.max(best, y - start + 1)
                prev = y
            }
            return Double(best) / Double(height)
        }
        var peak = candidates[0]
        var bestValue = -Double.infinity
        var peakNarrow = 1.0
        for p in candidates {
            let (l, h) = halfWidth(p)
            let widthDeg = Double(l + h + 1) * degPerCol
            let narrow = Swift.min(1, pow(maxLineDeg / widthDeg, 2))
            let value = (score[p] - med) * (0.25 + continuity(p)) * narrow
            if value > bestValue { bestValue = value; peak = p; peakNarrow = narrow }
        }
        let rise: Double = score[peak] - med
        let z: Double = rise / (mad + 0.004)

        // Width: columns round the peak above half its height.
        let (lo, hi) = halfWidth(peak)
        var band: [Int] = []
        for k in -lo...hi { band.append((peak + k + width) % width) }

        // Rows covered, and where the red and black parts sit.
        var rowsHit = Set<Int>(), redY: [Int] = [], blackY: [Int] = []
        for x in band {
            redY += redRows[x]
            blackY += blackRows[x]
        }
        rowsHit.formUnion(redY)
        rowsHit.formUnion(blackY)
        let heightShare: Double = Double(rowsHit.count) / Double(height)
        let marked: Int = Swift.max(1, redY.count + blackY.count)
        let redShare: Double = Double(redY.count) / Double(marked)

        // A second line of the other colour close by (red and black lines drawn side by side)?
        var pairAngle: Double?
        let primaryRed = redShare >= 0.5
        let other = primaryRed ? bs : rs
        let otherMed = ScanMath.median(other)
        let otherDev: [Double] = other.map { abs($0 - otherMed) }
        let otherMad: Double = ScanMath.median(otherDev) * 1.4826
        let reach: Int = Int((25 / degPerCol).rounded())
        let gapCols: Int = hi + lo + 1
        var bestOther = -1
        for k in -reach...reach where abs(k) > gapCols {
            let x = (peak + k + width) % width
            if bestOther < 0 || other[x] > other[bestOther] { bestOther = x }
        }
        let otherRise: Double = bestOther >= 0 ? other[bestOther] - otherMed : 0
        let otherZ: Double = otherRise / (otherMad + 0.004)
        if bestOther >= 0, otherRise >= 0.02, otherZ >= 4 {
            pairAngle = circularMean(angles[peak], angles[bestOther])
        }

        let kind: MarkDetection.Kind
        var redEnd: MarkDetection.RedEnd = .unknown
        if pairAngle != nil {
            kind = .redBlackPair
        } else if redY.count >= 10 && blackY.count >= 10 && redShare > 0.15 && redShare < 0.85 {
            kind = .redBlackLine
            let rMean: Double = Double(redY.reduce(0, +)) / Double(redY.count)
            let bMean: Double = Double(blackY.reduce(0, +)) / Double(blackY.count)
            let apart: Double = Double(height) * 0.1
            if abs(rMean - bMean) > apart { redEnd = rMean < bMean ? .top : .bottom }
        } else if primaryRed {
            kind = heightShare >= 0.3 ? .redLine : .redSpot
        } else {
            kind = .blackLine
            // A dark spot is too easily a natural grain or vug: only lines count. A wide dark band (a written
            // label, a dark layer) is not a drawn line either.
            guard heightShare >= 0.3, peakNarrow >= 0.4 else { return nil }
        }
        if kind == .redLine || kind == .redSpot, redY.count >= 10 {
            // Red mark at one end only: that end is the top.
            let rSum: Double = Double(redY.reduce(0, +))
            let rMean: Double = rSum / Double(redY.count) / Double(height)
            if heightShare < 0.6 { redEnd = rMean < 0.5 ? .top : .bottom }
        }

        let lineFactor: Double = kind == .redSpot ? 0.7 : Swift.min(1, 0.5 + heightShare)
        let colourFactor: Double = kind == .blackLine ? 0.75 : 1.0
        let zPart: Double = Swift.max(0, Swift.min(1, (z - 3) / 9))
        let confidence: Double = zPart * lineFactor * colourFactor
        return MarkDetection(angle: pairAngle ?? angles[peak], kind: kind, confidence: confidence, contrast: z,
                             heightShare: heightShare, widthDegrees: Double(band.count) * degPerCol, redEnd: redEnd)
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
