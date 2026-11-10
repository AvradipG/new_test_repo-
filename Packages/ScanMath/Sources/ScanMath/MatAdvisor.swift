import Foundation

/// Which printed scanning mat to use (3.11). The rock must stand out from the mat for Object Capture to separate it
/// and for the scale photos to read well: a dark or mid-toned rock on the light mat, a pale rock on the dark mat.
public enum MatAdvisor {
    public enum Tone: String, Sendable { case light, dark }

    /// Brightness (luma, 0–1) of each mat's work area as printed: light = pale cyan, dark = navy.
    public static let lightMat = 0.93
    public static let darkMat = 0.16
    /// Below this brightness difference the rock and the mat are too alike.
    public static let lowContrast = 0.15

    public struct Advice: Equatable, Sendable {
        public var tone: Tone
        /// Brightness difference between the rock and the recommended mat.
        public var contrast: Double
        public var reason: String
    }

    /// The mat for a rock of this brightness (median luma of the rock's surface, 0–1). The light mat is preferred
    /// (less ink, brighter scale photos) while it still separates the rock clearly.
    public static func advise(rockLuma l: Double) -> Advice {
        let onLight = abs(lightMat - l), onDark = abs(l - darkMat)
        if onLight >= 0.3 || onLight >= onDark {
            return Advice(tone: .light, contrast: onLight,
                          reason: String(format: "The rock is dark to mid-toned (brightness %.2f): it stands out on the light mat.", l))
        }
        return Advice(tone: .dark, contrast: onDark,
                      reason: String(format: "The rock is pale (brightness %.2f): on the light mat it would blend in, the dark mat sets it off.", l))
    }

    /// After a capture: the rock (middle of the photos) against what is round it (the photos' edges). Returns a
    /// tip for next time when they are too alike, else nil.
    public static func checkContrast(rockLuma: Double, surroundLuma: Double) -> String? {
        let c = abs(rockLuma - surroundLuma)
        guard c < lowContrast else { return nil }
        let better = advise(rockLuma: rockLuma)
        let matName = better.tone == .light ? "light" : "dark"
        return String(format: "The rock and what it lay on look alike (brightness %.2f against %.2f). Next time use the %@ scanning mat: the rock separates better and the 3D model is cleaner.",
                      rockLuma, surroundLuma, matName)
    }

    /// Paper by country: US Letter in the Americas that use it, else A4.
    public static func paper(region: String?) -> String {
        ["US", "CA", "MX", "PH", "CL", "CO"].contains(region ?? "") ? "Letter" : "A4"
    }

    /// Work area of each mat (mm, short × long side).
    public static func workArea(paper: String) -> (Double, Double) { paper == "Letter" ? (150, 210) : (150, 230) }

    /// Whether a rock (or a spread of pieces) of this footprint fits the work area with 1 cm to spare all round.
    public static func fits(lengthMM: Double, widthMM: Double, paper: String) -> Bool {
        let (s, l) = workArea(paper: paper)
        let a = Swift.max(lengthMM, widthMM), b = Swift.min(lengthMM, widthMM)
        return a <= l - 20 && b <= s - 20
    }
}
