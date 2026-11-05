import SwiftUI
import ScanMath

/// The length unit chosen in Settings. Everything is measured and stored in millimetres; this changes only what
/// is shown on screen, on rulers and in the images. Lab files (JSON, CSV) stay in millimetres.
enum UnitPref {
    static let key = "units.length"
    static var unit: LengthUnit {
        LengthUnit(rawValue: UserDefaults.standard.string(forKey: key) ?? "mm") ?? .mm
    }
}

/// A length in the chosen unit, e.g. "12.3 mm" or "0.484 in".
func L(_ mm: Double) -> String { UnitPref.unit.format(mm) }
/// Several lengths with one unit: "50.8 × 25.4 mm".
func LL(_ mm: [Double]) -> String { UnitPref.unit.formatList(mm) }
func LV(cm3: Double) -> String { UnitPref.unit.formatVolume(cm3: cm3) }

struct UnitPicker: View {
    @AppStorage(UnitPref.key) private var raw = "mm"
    var title = "Units"
    var body: some View {
        Picker(title, selection: $raw) {
            ForEach(LengthUnit.allCases) { u in
                Text("\(u.name) (\(u.symbol))").tag(u.rawValue)
            }
        }
    }
}

/// Segmented version for tool bars and the 3D views.
struct UnitSegments: View {
    @AppStorage(UnitPref.key) private var raw = "mm"
    var body: some View {
        Picker("Units", selection: $raw) {
            ForEach(LengthUnit.allCases) { u in Text(u.symbol).tag(u.rawValue) }
        }
        .pickerStyle(.segmented)
    }
}
