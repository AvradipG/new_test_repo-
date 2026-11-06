import Foundation

/// Size of the all-in-one cross-section picture (3.6). The whole canvas, gaps and title band included, stays
/// within the pixel budget and the side limit (3.2 counted only the tiles and could go about 4 % over).
public struct AllInOneLayout: Equatable, Sendable {
    public var cols: Int
    public var rows: Int
    public var tileWidth: Int
    public var tileHeight: Int
    public var width: Int
    public var height: Int

    public static func plan(count n: Int, tileWidth w0: Int, tileHeight h0: Int, budget: Int = 32_000_000,
                            maxSide: Int = 10_000, header: Int = 64, gap: Int = 8) -> AllInOneLayout? {
        guard n > 0, w0 > 0, h0 > 0, budget > 0, maxSide > header + 2 * gap else { return nil }
        let cols = max(1, Int(Double(n).squareRoot().rounded(.up)))
        let rows = (n + cols - 1) / cols
        func canvas(_ tw: Int, _ th: Int) -> (Int, Int) {
            (cols * tw + (cols + 1) * gap, header + rows * th + (rows + 1) * gap)
        }
        var s = min(1, (Double(budget) / (Double(n) * Double(w0) * Double(h0))).squareRoot())
        var tw = 0, th = 0
        for _ in 0..<200 {
            tw = Int((Double(w0) * s).rounded(.down))
            th = Int((Double(h0) * s).rounded(.down))
            guard tw >= 8, th >= 8 else { return nil } // too many slices for one readable picture
            let (cw, ch) = canvas(tw, th)
            if cw * ch <= budget && cw <= maxSide && ch <= maxSide { break }
            s *= 0.98
        }
        let (cw, ch) = canvas(tw, th)
        guard cw * ch <= budget, cw <= maxSide, ch <= maxSide else { return nil }
        return AllInOneLayout(cols: cols, rows: rows, tileWidth: tw, tileHeight: th, width: cw, height: ch)
    }
}

/// Whether a stopped build was paused by iOS (phone locked, app left) or genuinely failed (3.6).
public enum BuildStop: Equatable, Sendable {
    case pause
    case failure

    /// Errors that are real failures even when the app was in the background: no space left, missing or
    /// unreadable files. Anything else while the app was off screen is taken as a pause, up to `maxPauses`.
    public static func classify(interrupted: Bool, domain: String, code: Int, pausesSoFar: Int, maxPauses: Int = 30) -> BuildStop {
        guard interrupted else { return .failure }
        let genuine: Set<String> = ["NSCocoaErrorDomain:640", "NSCocoaErrorDomain:4", "NSCocoaErrorDomain:260",
                                    "NSCocoaErrorDomain:259", "NSCocoaErrorDomain:256", "NSPOSIXErrorDomain:28"]
        if genuine.contains("\(domain):\(code)") { return .failure }
        return pausesSoFar < maxPauses ? .pause : .failure
    }
}
