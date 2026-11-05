import Foundation
import UIKit
import ScanMath

/// Shape fit kept with the scan (model millimetres; multiply by the scan's scale factor for true size).
struct ShapeRecord: Codable, Hashable {
    var kind: String
    var diameterMM: Double
    var lengthMM: Double
    var tiltDegrees: Double
    var residualMM: Double
    var surfaceShare: Double

    init(_ f: ShapeFit) {
        kind = f.kind.rawValue
        diameterMM = f.diameter * 1000
        lengthMM = f.length * 1000
        tiltDegrees = f.tiltDegrees
        residualMM = f.residual * 1000
        surfaceShare = f.inlierShare
    }

    /// One line for reports and lists, true size.
    func text(scale k: Double) -> String {
        switch kind {
        case "cylinder":
            return String(format: "Cylinder Ø %.1f mm × %.1f mm long (axis %.1f° from vertical, fit within %.2f mm)",
                          diameterMM * k, lengthMM * k, tiltDegrees, residualMM * k)
        case "sphere":
            return String(format: "Sphere Ø %.1f mm (radius %.1f mm, fit within %.2f mm)", diameterMM * k, diameterMM * k / 2, residualMM * k)
        default:
            return "Irregular: no cylinder or sphere fits within 3 %"
        }
    }

    func json(scale k: Double) -> [String: Any] {
        var d: [String: Any] = ["kind": kind, "fit_residual_mm": residualMM * k, "surface_share_on_shape": surfaceShare]
        if kind == "cylinder" {
            d["diameter_mm"] = diameterMM * k
            d["radius_mm"] = diameterMM * k / 2
            d["length_mm"] = lengthMM * k
            d["axis_tilt_from_vertical_deg"] = tiltDegrees
        } else if kind == "sphere" {
            d["diameter_mm"] = diameterMM * k
            d["radius_mm"] = diameterMM * k / 2
        }
        return d
    }
}

/// Brings every finished scan, old or new, up to the current set of extras by itself: shape fit (cylinder or
/// sphere sizes), the true-scale sample sheet, and cross-sections with millimetre rulers. Runs one scan at a
/// time when the app is open and nothing is being built or captured; results go to Google Drive like any change.
extension AppModel {
    static let extrasVersion = 2

    func upgradeScans() async {
        guard !upgrading else { return }
        upgrading = true
        defer {
            upgrading = false
            upgradeNote = nil
        }
        var done = 0
        while true {
            guard phase == .home, buildingID == nil, UIApplication.shared.applicationState == .active else { return }
            reload()
            let todo = scans.filter { $0.needsExtras }
            guard let next = todo.first else { break }
            upgradeNote = "Adding sizes, shape and sample sheet to older scans: \(next.name) (\(todo.count) left)"
            await upgrade(next)
            done += 1
            await Task.yield()
        }
        if done > 0 {
            reload()
            await syncAllPending()
        }
    }

    private func upgrade(_ original: Scan) async {
        var scan = scans.first { $0.id == original.id } ?? original
        if scan.needsRepair {
            await repair(scan)
            reload()
            scan = scans.first { $0.id == original.id } ?? scan
        } else if scan.sectionsRuled != true {
            // Re-cut the existing stacks so their images carry millimetre rulers.
            var specs = (scan.sections ?? []).map { ($0.axis, $0.spacingMM) }
            if specs.isEmpty { specs = [(0, Self.defaultSpacingMM), (3, Self.defaultSpacingMM)] }
            scan.sections = await Self.cutStacks(scan, specs: specs)
        }
        scan.sectionsRuled = true

        if let loaded = await SampleRig.load(scan) {
            if let fit = loaded.1.shape { scan.shape = ShapeRecord(fit) }
            let rig = SampleRig(scene: loaded.0, data: loaded.1, name: scan.name)
            let panels = SampleSheet.render(rig: rig, scan: scan, angle: 0)
            let montage = SampleSheet.montage(panels, title: "\(scan.name) – Sample views (virtual, true scale)")
            _ = try? SampleSheet.save(panels, montage: montage, scan: scan, angle: 0)
        }
        scan.extrasVersion = Self.extrasVersion
        try? ScanStore.save(scan)
        let s = scan
        _ = MeshTools.writeReport(s)
        try? MeshTools.dimensionsData(s).write(to: MeshTools.dimensionsURL(s), options: .atomic)
        reload()
    }
}
