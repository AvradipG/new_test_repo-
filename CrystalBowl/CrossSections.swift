import Foundation
import UIKit
import ScanMath

/// One measured slice, in millimetres.
struct SectionRow: Codable, Hashable {
    var depthMM: Double
    var areaMM2: Double
    var perimeterMM: Double
    var equivalentDiameterMM: Double
    // Optional for compatibility with scans saved before 1.6.
    var measurementStatus: String?
    var closedLoopCount: Int?
    var openChainCount: Int?
    // Outline size from the section's points (1.7+). Valid for open outlines too, since it needs no closed loop.
    var maxFeretMM: Double?
    var minWidthMM: Double?
    var extentUMM: Double?
    var extentVMM: Double?
    var sizeText: String? {
        guard let f = maxFeretMM, let w = minWidthMM else { return nil }
        return String(format: "Max Ø %.1f mm · min width %.1f mm", f, w)
    }
    var measurementsUsable: Bool {
        if let status = measurementStatus { return status == "closed_contours" }
        return areaMM2 > 0 && perimeterMM > 0 // legacy positives, not proof of closure
    }
    var measurementText: String {
        guard measurementsUsable else {
            if measurementStatus == "empty_section" { return "No rock at this plane" }
            if let size = sizeText { return size + " · outline open, so no area" }
            return "Sizes missing in this older stack. Tap Repair on the scan page."
        }
        let values = String(format: "Area %.1f mm² · perimeter %.1f mm · Ø eq %.1f mm", areaMM2, perimeterMM, equivalentDiameterMM)
        if let size = sizeText { return size + " · " + values }
        return measurementStatus == nil ? values + " · legacy; closure not recorded" : values
    }
}

/// A stack of cross-section images cut across one of the rock's axes.
struct SectionSeries: Codable, Hashable, Identifiable {
    var axis: Int          // 0 = a (long), 1 = b, 2 = c (short), 3 = h (horizontal slices up the model as it stood)
    var spacingMM: Double
    var rows: [SectionRow]
    var id: String { folderName }
    var axisName: String { ["a", "b", "c", "h"][max(0, min(3, axis))] }
    var isHeightProfile: Bool { axis == 3 }
    var title: String { isHeightProfile ? "height profile" : "\(axisName)-axis" }
    var folderName: String { "\(axisName)-axis_\(SectionSeries.format(spacingMM))mm" }

    func folderURL(in scan: Scan) -> URL { scan.sectionsURL.appendingPathComponent(folderName, isDirectory: true) }
    func imageURL(in scan: Scan, index: Int) -> URL {
        folderURL(in: scan).appendingPathComponent(String(format: "%@_%03d.png", folderName, index + 1))
    }

    static func format(_ mm: Double) -> String {
        mm == mm.rounded() ? String(Int(mm)) : String(format: "%.1f", mm)
    }
}

enum CrossSectionMaker {
    /// Cuts the model across `axis` every `spacingMM` and writes one PNG per slice,
    /// a contact sheet and a CSV table into Sections/<axis>_<spacing>mm/.
    static func make(scan: Scan, axis: Int, spacingMM: Double) throws -> SectionSeries {
        guard let mesh = MeshTools.loadMesh(scan.modelURL) else {
            throw NSError(domain: "CrystalBowl", code: 3, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the model"])
        }
        // Axis 3 slices horizontally up the model as it stood (+Y up); depth is then height above the lowest point.
        let upright = axis == 3
        let frame = upright ? ScanMath.uprightFrame(mesh.positions) : ScanMath.principalFrame(mesh.positions)
        let cutAxis = upright ? 0 : axis
        let sections = ScanMath.crossSections(positions: mesh.positions, indices: mesh.indices, frame: frame,
                                              axis: cutAxis, spacing: spacingMM / 1000)
        let series = SectionSeries(axis: axis, spacingMM: spacingMM, rows: sections.map { section -> SectionRow in
            let size = section.outlineSize
            return SectionRow(depthMM: section.depth * 1000, areaMM2: section.area * 1e6,
                              perimeterMM: section.perimeter * 1000, equivalentDiameterMM: section.equivalentDiameter * 1000,
                              measurementStatus: section.measurementStatus, closedLoopCount: section.loops.count,
                              openChainCount: section.openChains.count,
                              maxFeretMM: size.map { $0.maxFeret * 1000 }, minWidthMM: size.map { $0.minWidth * 1000 },
                              extentUMM: size.map { $0.extentU * 1000 }, extentVMM: size.map { $0.extentV * 1000 })
        })
        let fm = FileManager.default
        let dir = series.folderURL(in: scan)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let layout = Layout(frame: frame, axis: cutAxis)
        for (i, s) in sections.enumerated() {
            let png = layout.renderPNG(s, title: "\(scan.name) · \(series.title) section \(i + 1)/\(sections.count)",
                                       row: series.rows[i], depthLabel: upright ? "height" : "depth")
            try png.write(to: series.imageURL(in: scan, index: i))
        }
        if !sections.isEmpty {
            try layout.contactSheet(sections, rows: series.rows, title: "\(scan.name) · \(series.title) every \(SectionSeries.format(spacingMM)) mm")
                .write(to: dir.appendingPathComponent("\(series.folderName)_contact-sheet.png"))
        }
        // Outline sizes come from the section points and are filled for open outlines too; area needs a closed outline.
        let depthColumn = upright ? "height_mm" : "depth_mm"
        var csv = "index,\(depthColumn),max_feret_mm,min_width_mm,extent_u_mm,extent_v_mm,area_mm2,perimeter_mm,equivalent_diameter_mm,measurement_status,closed_loop_count,open_chain_count\n"
        func num(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "" }
        for (i, r) in series.rows.enumerated() {
            let metrics = r.measurementsUsable ? String(format: "%.6f,%.6f,%.6f", r.areaMM2, r.perimeterMM, r.equivalentDiameterMM) : ",,"
            let sizes = [num(r.maxFeretMM), num(r.minWidthMM), num(r.extentUMM), num(r.extentVMM)].joined(separator: ",")
            csv += String(format: "%d,%.6f,", i + 1, r.depthMM) + sizes + "," + metrics
                + ",\(r.measurementStatus ?? "unknown"),\(r.closedLoopCount ?? 0),\(r.openChainCount ?? 0)\n"
        }
        try csv.write(to: dir.appendingPathComponent("\(series.folderName).csv"), atomically: true, encoding: .utf8)
        // Lossless contour geometry avoids having to measure screenshots later.
        func vector(_ p: SIMD3<Double>) -> [Double] { [p.x, p.y, p.z] }
        func paths(_ paths: [[SIMD2<Double>]]) -> [[[Double]]] {
            paths.map { $0.map { [$0.x * 1000, $0.y * 1000] } }
        }
        let records: [[String: Any]] = sections.enumerated().map { i, section in
            ["index": i + 1, "depth_mm": section.depth * 1000,
             "measurement_status": section.measurementStatus,
             "max_feret_mm": series.rows[i].maxFeretMM ?? NSNull(), "min_width_mm": series.rows[i].minWidthMM ?? NSNull(),
             "closed_loops_mm": paths(section.loops), "open_chains_mm": paths(section.openChains)]
        }
        let geometry: [String: Any] = [
            "schema": "crystal-bowl.sections/1", "units": "mm", "axis": axis,
            "axis_meaning": upright ? "horizontal slices; frame axis 0 is model +Y (up as scanned); depth_mm is height above the lowest point"
                                    : "PCA axis \(series.axisName); depth_mm from the minimum projection",
            "spacing_mm": spacingMM, "frame_center_mm": vector(frame.center * 1000),
            "frame_axes": frame.axes.map(vector), "frame_lo_mm": vector(frame.lo * 1000),
            "frame_hi_mm": vector(frame.hi * 1000), "sections": records,
            "app_version": AppInfo.version, "app_build": AppInfo.build, "app_commit": AppInfo.commit,
            "caliper_scale_factor": scan.scaleFactor, "caliper_scale_applied": false,
            "note": "Exterior surface sections, not CT. PCA axis sign is not mounted top/bottom. Holder and billets are not automatically excluded. Coordinates retain original model scale."
        ]
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("\(series.folderName)-geometry.json"), options: .atomic)
        // Overall dimensions travel with every section stack, so a stack shared on its own still carries them.
        try? MeshTools.dimensionsData(scan).write(to: dir.appendingPathComponent("dimensions.json"), options: .atomic)
        return series
    }

    /// Zips a series folder for sharing (uses the system's built-in folder zipping).
    static func zip(_ series: SectionSeries, in scan: Scan) -> URL? {
        let src = series.folderURL(in: scan)
        let dest = scan.exportsURL.appendingPathComponent("\(scan.fileStem)_\(series.folderName).zip")
        try? FileManager.default.createDirectory(at: scan.exportsURL, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        var result: URL?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: src, options: .forUploading, error: &err) { zipURL in
            if (try? FileManager.default.copyItem(at: zipURL, to: dest)) != nil { result = dest }
        }
        return result
    }

    /// Fixed scale for a whole series so every slice is comparable.
    struct Layout {
        let ui: Int, vi: Int
        let loU: Double, hiV: Double     // mm
        let pxPerMM: Double
        let size: CGSize
        static let margin: CGFloat = 40, header: CGFloat = 64, footer: CGFloat = 56

        init(frame: PrincipalFrame, axis: Int) {
            let pa = frame.planeAxes(axis)
            ui = pa.u
            vi = pa.v
            loU = frame.lo[ui] * 1000
            hiV = frame.hi[vi] * 1000
            let eu = frame.extents[ui] * 1000, ev = frame.extents[vi] * 1000
            let px = min(12, 1100 / max(eu, ev, 1))
            pxPerMM = px
            size = CGSize(width: CGFloat(eu * px) + 2 * Self.margin,
                          height: CGFloat(ev * px) + Self.header + Self.footer)
        }

        func path(_ s: CrossSection, origin: CGPoint, scale: CGFloat) -> (fill: UIBezierPath, open: UIBezierPath) {
            func pt(_ p: SIMD2<Double>) -> CGPoint {
                CGPoint(x: origin.x + CGFloat((p.x * 1000 - loU) * pxPerMM) * scale,
                        y: origin.y + CGFloat((hiV - p.y * 1000) * pxPerMM) * scale)
            }
            let fill = UIBezierPath()
            fill.usesEvenOddFillRule = true
            for loop in s.loops {
                fill.move(to: pt(loop[0]))
                for p in loop.dropFirst() { fill.addLine(to: pt(p)) }
                fill.close()
            }
            let open = UIBezierPath()
            for chain in s.openChains where chain.count > 1 {
                open.move(to: pt(chain[0]))
                for p in chain.dropFirst() { open.addLine(to: pt(p)) }
            }
            return (fill, open)
        }

        func renderPNG(_ s: CrossSection, title: String, row: SectionRow, depthLabel: String) -> Data {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            fmt.opaque = true
            return UIGraphicsImageRenderer(size: size, format: fmt).pngData { ctx in
                UIColor.black.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                let (fill, open) = path(s, origin: CGPoint(x: Self.margin, y: Self.header), scale: 1)
                UIColor(white: 0.85, alpha: 1).setFill()
                fill.fill()
                UIColor.white.setStroke()
                fill.lineWidth = 1.5
                fill.stroke()
                UIColor.systemOrange.setStroke()
                open.lineWidth = 1.5
                open.stroke()
                let big: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: UIColor.white]
                let small: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular), .foregroundColor: UIColor(white: 0.8, alpha: 1)]
                (title as NSString).draw(at: CGPoint(x: Self.margin, y: 12), withAttributes: big)
                let size = row.maxFeretMM.map { String(format: " | max %.1f mm | min width %.1f mm", $0, row.minWidthMM ?? 0) } ?? ""
                let info = row.measurementsUsable
                    ? String(format: "%@ %.1f mm%@ | area %.1f mm2", depthLabel, row.depthMM, size, row.areaMM2)
                    : String(format: "%@ %.1f mm%@ | outline open: no area", depthLabel, row.depthMM, size)
                (info as NSString).draw(at: CGPoint(x: Self.margin, y: 36), withAttributes: small)
                // 10 mm scale bar
                let barLen = CGFloat(10 * pxPerMM)
                let y = size.height - Self.footer / 2
                UIColor.white.setFill()
                ctx.fill(CGRect(x: Self.margin, y: y, width: barLen, height: 4))
                ("10 mm" as NSString).draw(at: CGPoint(x: Self.margin + barLen + 8, y: y - 9), withAttributes: small)
            }
        }

        func contactSheet(_ sections: [CrossSection], rows: [SectionRow], title: String) -> Data {
            let cols = min(6, sections.count)
            let cellW: CGFloat = 220
            let scale = (cellW - 20) / max(size.width - 2 * Self.margin, size.height - Self.header - Self.footer, 1)
            let cellH = (size.height - Self.header - Self.footer) * scale + 40
            let rowsN = Int(ceil(Double(sections.count) / Double(cols)))
            let sheet = CGSize(width: CGFloat(cols) * cellW + 20, height: CGFloat(rowsN) * cellH + 60)
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            fmt.opaque = true
            return UIGraphicsImageRenderer(size: sheet, format: fmt).pngData { ctx in
                UIColor.black.setFill()
                ctx.fill(CGRect(origin: .zero, size: sheet))
                let big: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: UIColor.white]
                let small: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: UIColor(white: 0.8, alpha: 1)]
                (title as NSString).draw(at: CGPoint(x: 20, y: 16), withAttributes: big)
                for (i, s) in sections.enumerated() {
                    let ox = 20 + CGFloat(i % cols) * cellW, oy = 60 + CGFloat(i / cols) * cellH
                    let (fill, open) = path(s, origin: CGPoint(x: ox, y: oy), scale: scale)
                    UIColor(white: 0.85, alpha: 1).setFill()
                    fill.fill()
                    UIColor.systemOrange.setStroke()
                    open.stroke()
                    let label = rows[i].maxFeretMM.map { String(format: "#%d | %.1f mm | max %.1f mm", i + 1, rows[i].depthMM, $0) }
                        ?? String(format: "#%d | %.1f mm | no outline", i + 1, rows[i].depthMM)
                    (label as NSString).draw(at: CGPoint(x: ox, y: oy + cellH - 34), withAttributes: small)
                }
            }
        }
    }
}
