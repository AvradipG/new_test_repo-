import Foundation
import UIKit
import ScanMath

/// One measured slice, in millimetres.
struct SectionRow: Codable, Hashable {
    var depthMM: Double
    var areaMM2: Double
    var perimeterMM: Double
    var equivalentDiameterMM: Double
}

/// A stack of cross-section images cut across one of the rock's axes.
struct SectionSeries: Codable, Hashable, Identifiable {
    var axis: Int          // 0 = a (long), 1 = b, 2 = c (short)
    var spacingMM: Double
    var rows: [SectionRow]
    var id: String { folderName }
    var axisName: String { ["a", "b", "c"][axis] }
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
        let frame = ScanMath.principalFrame(mesh.positions)
        let sections = ScanMath.crossSections(positions: mesh.positions, indices: mesh.indices, frame: frame,
                                              axis: axis, spacing: spacingMM / 1000)
        let series = SectionSeries(axis: axis, spacingMM: spacingMM, rows: sections.map {
            SectionRow(depthMM: $0.depth * 1000, areaMM2: $0.area * 1e6,
                       perimeterMM: $0.perimeter * 1000, equivalentDiameterMM: $0.equivalentDiameter * 1000)
        })
        let fm = FileManager.default
        let dir = series.folderURL(in: scan)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let layout = Layout(frame: frame, axis: axis)
        for (i, s) in sections.enumerated() {
            let png = layout.renderPNG(s, title: "\(scan.name) · \(series.axisName)-axis section \(i + 1)/\(sections.count)",
                                       row: series.rows[i])
            try png.write(to: series.imageURL(in: scan, index: i))
        }
        if !sections.isEmpty {
            try layout.contactSheet(sections, rows: series.rows, title: "\(scan.name) · \(series.axisName)-axis every \(SectionSeries.format(spacingMM)) mm")
                .write(to: dir.appendingPathComponent("\(series.folderName)_contact-sheet.png"))
        }
        var csv = "index,depth_mm,area_mm2,perimeter_mm,equivalent_diameter_mm\n"
        for (i, r) in series.rows.enumerated() {
            csv += String(format: "%d,%.2f,%.2f,%.2f,%.2f\n", i + 1, r.depthMM, r.areaMM2, r.perimeterMM, r.equivalentDiameterMM)
        }
        try csv.write(to: dir.appendingPathComponent("\(series.folderName).csv"), atomically: true, encoding: .utf8)
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

        func renderPNG(_ s: CrossSection, title: String, row: SectionRow) -> Data {
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
                let info = String(format: "depth %.1f mm · area %.1f mm² · perimeter %.1f mm · Ø eq %.1f mm",
                                  row.depthMM, row.areaMM2, row.perimeterMM, row.equivalentDiameterMM)
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
                    let label = String(format: "#%d · %.1f mm · %.0f mm²", i + 1, rows[i].depthMM, rows[i].areaMM2)
                    (label as NSString).draw(at: CGPoint(x: ox, y: oy + cellH - 34), withAttributes: small)
                }
            }
        }
    }
}
