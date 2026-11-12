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
    /// 6 (3.9): side views on graph paper (origin at the rock's corner, height and width read off the axes);
    /// no ruler laid beside the rock and no scale bar in the figures.
    /// 7 (3.14): a stand under the rock is looked for and cut off; sheets made again without it.
    /// 8 (3.16): stand cuts need an outline change too (3.14 cut straight cores at their end marks); how to stand
    /// a core straight for the micro-CT (paper under the low side).
    static let extrasVersion = 8

    func upgradeScans() async {
        // Piece sets put together before 3.12 are put together again, one at a time: 2 = the 3.10 floor fix (the flat
        // tops of pieces were taken for the table), 3 = 3.12, pieces fitted into the original cylinder.
        if buildingID == nil, phase == .home,
           var p = scans.first(where: { $0.isPieces && $0.hasModel && ($0.piecesSplit ?? 0) < 3 && $0.buildRequested != true }) {
            p.piecesSplit = 3
            try? ScanStore.save(p)
            reload() // reassemble reads the stored scan
            AppLog.info("pieces", "Putting the pieces together again with the 3.12 cylinder fit", scan: p)
            reassemble(p)
        }
        // Rock brightness for the mat advice (3.11), read from the saved unrolled side of older scans.
        for s in scans where !s.isPieces && s.rockLuma == nil {
            let dir = s.exportsURL.appendingPathComponent("sheet", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if let u = files.first(where: { $0.lastPathComponent.contains("_unrolled_") }), let img = UIImage(contentsOfFile: u.path),
               let l = RockTone.surface(img), var t = scans.first(where: { $0.id == s.id }) {
                t.rockLuma = l
                try? ScanStore.save(t)
            }
        }
        reload()
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
        // 3.14: a stand under the rock (a block that lifts a small rock for the scan), looked for once on the model
        // as it is; when one is found the model is measured and sliced again without it.
        // 3.16: cuts made by colour alone in 3.14/3.15 are looked at again with the outline check (four straight
        // cores had their bottoms cut where their black end marks are). A cut that doesn't hold is undone.
        var undoneCut: Double?
        if (scan.extrasVersion ?? 0) < 8 && (scan.standCheck == "auto" || scan.standCheck == "ai") {
            undoneCut = scan.standCutY
            scan.standCutY = nil
            scan.standCheck = nil
            scan.standAI = nil
            try? ScanStore.save(scan)
        }
        if scan.standCheck == nil && !scan.isPieces {
            upgradeNote = "Looking for a stand under the rock: \(scan.name)"
            let found = await StandStrip.examine(scan)
            var cutY: Double? = (found?.outlineChanges ?? false) ? found?.cutY : nil
            var how: String = cutY == nil ? "not_found" : "auto"
            if let f = found {
                let detail: String = " (" + f.outlineText + ")"
                if f.outlineChanges {
                    scan.standNote = "Found by its colour, and the outline changes there" + detail + "."
                } else {
                    scan.standNote = "A change of colour near the bottom was not taken for a stand: the outline runs on unchanged" + detail + ". If there is a stand, set the cut here."
                }
            } else {
                scan.standNote = nil
            }
            // 3.15: the AI second opinion, when switched on.
            if AIAssist.isReady, let strip = StandStrip.load(scan),
               let a = try? await AIAssist.askStand(strip: strip.image, heightMM: strip.heightMM) {
                let why: String = " (" + a.reason + ")"
                if let c = cutY {
                    let apart: Double = abs(strip.share(atY: c) - a.boundaryFromTop)
                    if !a.hasStand {
                        scan.standAI = "The AI sees no stand here" + why + ": check the cut."
                    } else if apart < 0.06 {
                        scan.standAI = "The AI agrees with the cut."
                    } else {
                        scan.standAI = "The AI puts the top of the stand elsewhere" + why + ": check the cut."
                    }
                } else if let f = found, a.hasStand, a.confidence >= 0.7, abs(strip.share(atY: f.cutY) - a.boundaryFromTop) < 0.06 {
                    // Colour and the AI agree although the outline runs on: take it, for the user to check.
                    cutY = f.cutY
                    how = "auto"
                    scan.standAI = "The AI sees a stand where the colour changes" + why + ": cut there; check it."
                    StandStrip.writeInfo(strip, scan: scan, cutY: f.cutY, how: "auto")
                } else if a.hasStand && a.confidence >= 0.75 && a.boundaryFromTop > 0.2 && a.boundaryFromTop < 0.95 {
                    let y: Double = strip.y(atShare: a.boundaryFromTop)
                    cutY = y
                    how = "ai"
                    scan.standAI = "Found by the AI" + why + ": check the cut."
                    StandStrip.writeInfo(strip, scan: scan, cutY: y, how: "ai")
                } else if a.hasStand {
                    scan.standAI = "The AI suspects a stand, but isn't sure" + why + ": have a look."
                }
            }
            if let y = cutY {
                scan.standCutY = y
                scan.standCheck = how
                let above: String = StandStrip.load(scan).map { String(format: "%.1f mm above the bottom", (y - $0.bottomY) * 1000 * $0.scaleFactor) } ?? "?"
                let detail: String = found.map { String(format: " (%.0f%% of the height; rock luma %.2f, stand %.2f; ", $0.result.standShare * 100, $0.result.rockLuma, $0.result.standLuma) + $0.outlineText + ")" } ?? ""
                AppLog.info("stand", "Stand found under the rock by " + (how == "ai" ? "the AI" : "its colour") + ": cut " + above + detail + "; measured again without it", scan: scan)
                try? ScanStore.save(scan)
                reload()
                await repair(scan)
                reload()
                scan = scans.first { $0.id == original.id } ?? scan
            } else {
                scan.standCheck = "not_found"
                if let f = found {
                    AppLog.info("stand", String(format: "Colour change at %.0f%% of the height not taken for a stand: ", f.result.standShare * 100) + f.outlineText, scan: scan)
                }
                try? ScanStore.save(scan)
                if let old = undoneCut {
                    AppLog.info("stand", String(format: "Stand cut of 3.14 undone (it was at model height %.4f m): measured again in full", old), scan: scan)
                    reload()
                    await repair(scan)
                    reload()
                    scan = scans.first { $0.id == original.id } ?? scan
                }
            }
        }
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
            if let u = unrolled, let l = RockTone.surface(u.image) { scan.rockLuma = l }
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
        // 3.16: how to stand it straight in the micro-CT.
        if !scan.isPieces {
            let measured = scan
            let level = await Task.detached { () -> LevelReport? in
                guard let mesh = MeshTools.loadMesh(measured) else { return nil }
                return CoreLeveller.plan(positions: mesh.positions, indices: mesh.indices, unitToMM: 1000 * measured.scaleFactor)
            }.value
            scan.level = level
            if let l = level {
                AppLog.info("level", String(format: "Core Ø %.1f × %.1f mm leans %.2f° (± %.2f°) as it stood; lift at azimuth %.0f°, rim gap %.2f mm; turned over: %@",
                                            l.diameterMM, l.lengthMM, l.asScanned.tiltDeg, l.asScanned.spreadDeg, l.asScanned.liftAzimuthDeg, l.asScanned.rimGapMM,
                                            l.turnedOver.map { String(format: "%.2f°", $0.tiltDeg) } ?? "unknown"), scan: scan)
            }
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
