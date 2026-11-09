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
        let u = UnitPref.unit
        switch kind {
        case "cylinder":
            return "Cylinder Ø " + u.format(diameterMM * k) + " × " + u.format(lengthMM * k) + " long"
                + String(format: " (axis %.1f° from vertical, fit within ", tiltDegrees) + u.format(residualMM * k, decimals: u.decimals + 1) + ")"
        case "sphere":
            return "Sphere Ø " + u.format(diameterMM * k) + " (radius " + u.format(diameterMM * k / 2) + ", fit within "
                + u.format(residualMM * k, decimals: u.decimals + 1) + ")"
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
/// sphere sizes), the reference mark, the clean and scientific sample sheets with the unrolled side, and
/// cross-sections with rulers. Runs one scan at a time when the app is open and nothing is being built or
/// captured; results go to Google Drive like any change.
extension AppModel {
    /// 4 (3.7): the mark is looked for again with the line-versus-label check, and the sheets are made again
    /// (no bottom view when the underside wasn't scanned). Marks set by hand are kept.
    /// 5 (3.8): the mark finder looks for thin lines, red top and black bottom marks (a written label is not a
    /// mark); sheets are laid out as separate figures, each with its own ruler and scale, as ticked in
    /// "What to include". Every older scan is evaluated again.
    static let extrasVersion = 5

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
            upgradeNote = "Finding the reference mark and making sample sheets: \(next.name) (\(todo.count) left)"
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
            // Re-cut the existing stacks so their images carry rulers.
            var specs = (scan.sections ?? []).map { ($0.axis, $0.spacingMM) }
            if specs.isEmpty { specs = [(0, Self.defaultSpacingMM), (3, Self.defaultSpacingMM)] }
            scan.sections = await Self.cutStacks(scan, specs: specs)
        }
        scan.sectionsRuled = true

        if let loaded = await SampleRig.load(scan) {
            if let fit = loaded.1.shape { scan.shape = ShapeRecord(fit) }
            let rig = SampleRig(scene: loaded.0, data: loaded.1, name: scan.name)
            let unrolled = Unroller.detectMark(rig: rig, scan: &scan)
            let (ref, isMark) = SampleSheet.reference(for: scan)
            let out = SampleSheet.make(rig: rig, scan: scan, reference: ref, referenceIsMark: isMark, unrolled: unrolled)
            do {
                let files = try SampleSheet.save(out, scan: scan)
                AppLog.info("sheet", "Sheets made at \(Rotation.text(ref)) (\(isMark ? "the mark" : "no mark")): \(files.count) files, "
                            + "\(out.figures.count) figures; included: \(out.options.summary)", scan: scan)
            } catch {
                AppLog.error("sheet", "Sheets could not be saved", error, scan: scan)
            }
        } else {
            AppLog.warn("sheet", "3D model could not be loaded: no sheets made", scan: scan)
        }
        scan.extrasVersion = Self.extrasVersion
        try? ScanStore.save(scan)
        let s = scan
        _ = MeshTools.writeReport(s)
        try? MeshTools.dimensionsData(s).write(to: MeshTools.dimensionsURL(s), options: .atomic)
        reload()
    }

    /// The user turned the model until the mark faced them: that angle becomes 0° and the sheets are redone.
    func setMark(_ scan: Scan, angle: Double) {
        guard var s = scans.first(where: { $0.id == scan.id }) else { return }
        s.mark = MarkRecord(angle: Rotation.normalized(angle), kind: "manual", confidence: 1, redEnd: s.mark?.redEnd ?? "unknown",
                            source: "manual", date: Date())
        s.extrasVersion = 2
        try? ScanStore.save(s)
        reload()
        AppLog.info("mark", "Mark set by hand at " + Rotation.text(angle), scan: s)
        Task { await upgradeScans() }
    }

    /// Makes the sheets again (and looks for the mark again; marks set by hand are kept), e.g. after the
    /// "What to include" ticks changed (3.8).
    func remakeSheets(_ ids: [String]) {
        for id in ids {
            guard var s = scans.first(where: { $0.id == id }) else { continue }
            s.extrasVersion = Swift.min(s.extrasVersion ?? 0, 2)
            try? ScanStore.save(s)
        }
        reload()
        AppLog.info("sheet", "Sheets to be made again for \(ids.count) scan(s); included: \(SheetOptions.current.summary)")
        Task { await upgradeScans() }
    }

    /// Forgets the mark; the automatic search runs again.
    func clearMark(_ scan: Scan) {
        guard var s = scans.first(where: { $0.id == scan.id }) else { return }
        s.mark = nil
        s.extrasVersion = 2
        try? ScanStore.save(s)
        reload()
        AppLog.info("mark", "Mark forgotten; looking for it again", scan: s)
        Task { await upgradeScans() }
    }
}
