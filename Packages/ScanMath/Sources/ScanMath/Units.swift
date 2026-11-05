import Foundation

/// Length unit the user reads sizes in. Everything is stored in millimetres; this only changes what is shown
/// (labels, rulers, reports). Lab files keep millimetres so software never has to guess.
public enum LengthUnit: String, CaseIterable, Codable, Sendable, Identifiable {
    case mm, cm, m
    case inch = "in"

    public var id: String { rawValue }
    public var symbol: String { rawValue }
    public var name: String {
        switch self {
        case .mm: return "Millimetres"
        case .cm: return "Centimetres"
        case .m: return "Metres"
        case .inch: return "Inches"
        }
    }
    public var mmPerUnit: Double {
        switch self {
        case .mm: return 1
        case .cm: return 10
        case .m: return 1000
        case .inch: return 25.4
        }
    }
    /// Decimals that keep about 0.1 mm of detail.
    public var decimals: Int {
        switch self {
        case .mm: return 1
        case .cm: return 2
        case .m: return 4
        case .inch: return 3
        }
    }

    public func value(mm: Double) -> Double { mm / mmPerUnit }
    public func mm(_ value: Double) -> Double { value * mmPerUnit }

    /// "12.3 mm", "1.23 cm", "0.0123 m", "0.484 in".
    public func format(_ mm: Double, decimals d: Int? = nil, symbol withSymbol: Bool = true) -> String {
        let s = String(format: "%.\(d ?? decimals)f", value(mm: mm))
        return withSymbol ? s + " " + symbol : s
    }

    /// Several lengths with one unit at the end: "50.8 × 25.4 × 10.0 mm".
    public func formatList(_ mm: [Double], separator: String = " × ") -> String {
        mm.map { format($0, symbol: false) }.joined(separator: separator) + " " + symbol
    }

    public func formatArea(_ mm2: Double) -> String {
        let v = mm2 / (mmPerUnit * mmPerUnit)
        return String(format: "%.\(decimals)f %@²", v, symbol)
    }

    /// Volumes: cm³ for millimetres and centimetres (the lab habit), m³ or in³ otherwise.
    public func formatVolume(cm3: Double) -> String {
        switch self {
        case .mm, .cm: return String(format: "%.2f cm³", cm3)
        case .m: return String(format: "%.3e m³", cm3 * 1e-6)
        case .inch: return String(format: "%.3f in³", cm3 / 16.387064)
        }
    }

    /// Ruler: distance between numbered marks (mm) and how the numbers are written.
    var majorMM: Double { self == .inch ? 25.4 : 10 }
    func majorLabel(_ k: Int) -> String {
        switch self {
        case .mm: return "\(k * 10)"
        case .cm: return "\(k)"
        case .m: return String(format: "%.2f", Double(k) * 0.01)
        case .inch: return "\(k)"
        }
    }
    /// The word written at the end of a ruler.
    public var rulerCaption: String {
        switch self {
        case .mm: return "mm"
        case .cm, .m: return self == .m ? "m" : "cm"
        case .inch: return "in"
        }
    }
}

public extension RulerTicks {
    /// Ruler at least `lengthMM` long in the given unit. Metric rulers: mm marks, 5 mm marks, numbered every
    /// centimetre (written in the unit). Inch rulers: 0.1 in marks, 0.5 in marks, numbered every inch.
    static func ticks(coveringMM lengthMM: Double, unit: LengthUnit) -> [Tick] {
        let major = unit.majorMM
        let n = Swift.max(1, Int((lengthMM / major).rounded(.up)))
        return (0...(n * 10)).map { i in
            let level = i % 10 == 0 ? 2 : (i % 5 == 0 ? 1 : 0)
            return Tick(mm: Double(i) * major / 10, level: level, label: level == 2 ? unit.majorLabel(i / 10) : nil)
        }
    }
}
