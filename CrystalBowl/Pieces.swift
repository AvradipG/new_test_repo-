import SwiftUI
import SceneKit
import ScanMath

/// Short result of a reconstruction, kept with the scan.
struct PiecesSummary: Codable, Hashable {
    var pieces: Int
    var placed: Int
    var groups: Int
    var missing: Int
    var small: Int
    var bothSides: Bool
    var recoveredShare: Double?
    var missingCM3: Double?
    var date: Date
    var headline: String

    func json(scan: Scan) -> [String: Any] {
        let stem = scan.fileStem
        return ["pieces_matched": pieces, "placed": placed, "groups": groups, "missing_regions": missing, "small_fragments": small,
                "both_sides_scanned": bothSides, "recovered_share": recoveredShare ?? NSNull(), "missing_cm3": missingCM3 ?? NSNull(),
                "headline": headline, "date_utc": ISO8601DateFormatter().string(from: date),
                "report": "model/pieces/\(stem)_pieces.json", "table": "model/pieces/\(stem)_pieces.csv",
                "assembled_model": "model/pieces/\(stem)_assembled.obj", "missing_model": "model/pieces/\(stem)_missing.obj",
                "images": "model/pieces/*.png"]
    }
}

/// Runs the reconstruction on a pieces scan and writes everything into model/pieces (so it goes to Drive).
enum PiecesWorker {
    static let palette: [UIColor] = [
        UIColor(red: 0.90, green: 0.33, blue: 0.20, alpha: 1), UIColor(red: 0.20, green: 0.55, blue: 0.90, alpha: 1),
        UIColor(red: 0.30, green: 0.75, blue: 0.35, alpha: 1), UIColor(red: 0.95, green: 0.75, blue: 0.15, alpha: 1),
        UIColor(red: 0.60, green: 0.35, blue: 0.85, alpha: 1), UIColor(red: 0.10, green: 0.75, blue: 0.75, alpha: 1),
        UIColor(red: 0.90, green: 0.40, blue: 0.65, alpha: 1), UIColor(red: 0.55, green: 0.45, blue: 0.25, alpha: 1),
        UIColor(red: 0.45, green: 0.60, blue: 0.20, alpha: 1), UIColor(red: 0.25, green: 0.30, blue: 0.70, alpha: 1),
        UIColor(red: 0.85, green: 0.55, blue: 0.40, alpha: 1), UIColor(red: 0.40, green: 0.40, blue: 0.40, alpha: 1),
    ]
    static func color(_ id: Int) -> UIColor { palette[(Swift.max(1, id) - 1) % palette.count] }

    static func run(_ scan: Scan, progress: @escaping @Sendable (Double, String) -> Void) throws -> PiecesSummary {
        guard let m1 = MeshTools.loadMesh(scan.modelURL) else {
            throw NSError(domain: "CrystalBowl", code: 10, userInfo: [NSLocalizedDescriptionKey: "The model of side 1 couldn't be read"])
        }
        let first = SceneMesh.welded(positions: m1.positions, indices: m1.indices)
        var second: SceneMesh?
        if scan.hasModel2, let m2 = MeshTools.loadMesh(scan.model2URL) {
            second = SceneMesh.welded(positions: m2.positions, indices: m2.indices)
        }
        var options = ReconstructionOptions()
        options.target = scan.pieceTarget ?? .auto
        let rec = PieceReconstructor.run(first: first, second: second, options: options) { f, note in progress(f * 0.9, note) }
        progress(0.92, "Writing the results…")
        try write(rec, scan: scan, first: first, second: second)
        let r = rec.report
        let placed = r.pieces.filter { $0.status == "anchor" || $0.status == "placed" }.count
        let missing = r.missing.filter { $0.kind == "missing_piece" }
        var headline = "\(r.pieces.count) piece\(r.pieces.count == 1 ? "" : "s") found"
        if r.pieces.count >= 2 { headline += ", \(placed) put together" }
        if !missing.isEmpty { headline += ", \(missing.count) missing" }
        return PiecesSummary(pieces: r.pieces.count, placed: placed, groups: r.groups.count, missing: missing.count, small: r.small.count,
                             bothSides: second != nil, recoveredShare: r.volumes.recoveredShare, missingCM3: r.volumes.missingCM3,
                             date: Date(), headline: headline)
    }

    // MARK: Geometry of the result

    struct Tri {
        var a: SIMD3<Double>
        var b: SIMD3<Double>
        var c: SIMD3<Double>
        var piece: Int
    }

    /// Every piece's triangles where the reconstruction put it (unplaced pieces in a row beside the assembly).
    static func assembledTriangles(_ rec: Reconstruction, first: SceneMesh, second: SceneMesh?) -> [Tri] {
        var out: [Tri] = []
        let placed = rec.assembly?.placed ?? [:]
        var maxX = -Double.infinity, minZ = Double.infinity
        var poses: [Int: Pose] = [:]
        for it in rec.items {
            if let p = placed[it.id] {
                poses[it.id] = p.pose
                for q in it.piece.points.map({ p.pose.apply($0) }) {
                    maxX = Swift.max(maxX, q.x)
                    minZ = Swift.min(minZ, q.z)
                }
            }
        }
        if !maxX.isFinite { maxX = 0 }
        if !minZ.isFinite { minZ = 0 }
        var cursor = maxX + 0.01
        for it in rec.items where poses[it.id] == nil {
            // Lay it down where it is, moved to the side.
            let c = it.first.centroid
            let r = it.piece.radius
            poses[it.id] = Pose(R: matrix_identity_double3x3, t: SIMD3(cursor + r - c.x, -it.piece.lo.y, minZ - c.z))
            cursor += 2 * r + 0.008
        }
        for it in rec.items {
            guard let W = poses[it.id] else { continue }
            for t in it.first.triangles {
                out.append(Tri(a: W.apply(first.positions[t.x]), b: W.apply(first.positions[t.y]), c: W.apply(first.positions[t.z]), piece: it.id))
            }
            if let c2 = it.second, let S = it.secondPose, let m2 = second {
                let T = W.compose(S)
                for t in c2.triangles {
                    out.append(Tri(a: T.apply(m2.positions[t.x]), b: T.apply(m2.positions[t.y]), c: T.apply(m2.positions[t.z]), piece: it.id))
                }
            }
        }
        return out
    }

    // MARK: Files

    static func write(_ rec: Reconstruction, scan: Scan, first: SceneMesh, second: SceneMesh?) throws {
        let fm = FileManager.default
        let dir = scan.piecesURL
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = scan.fileStem
        let unit = UnitPref.unit

        // Report.
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        let reportData = try enc.encode(rec.report)
        var dict = (try JSONSerialization.jsonObject(with: reportData)) as? [String: Any] ?? [:]
        dict["scan_id"] = scan.id
        dict["sample"] = scan.name
        dict["created_utc"] = ISO8601DateFormatter().string(from: Date())
        dict["app"] = ["name": "Crystal Bowl Scanner (iPhone)", "version": AppInfo.version, "build": AppInfo.build]
        dict["files"] = ["assembled_model": "\(stem)_assembled.obj", "missing_model": "\(stem)_missing.obj",
                         "table": "\(stem)_pieces.csv", "images": ["\(stem)_assembled.png", "\(stem)_as-found.png"],
                         "side1_model": "../\(scan.modelURL.lastPathComponent)",
                         "side2_model": scan.hasModel2 ? "../\(scan.model2URL.lastPathComponent)" : NSNull()] as [String: Any]
        try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("\(stem)_pieces.json"), options: .atomic)

        // Table.
        var csv = "label,status,confidence,sides,size_a_mm,size_b_mm,size_c_mm,volume_cm3,surface_cm2,as_found_x_mm,as_found_y_mm,as_found_z_mm,placed_via,touches,confirmed_by,note\n"
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" }
        for p in rec.report.pieces {
            let size = p.sizeMM + [0, 0, 0]
            let c = p.asFoundCentreMM + [0, 0, 0]
            csv += [p.label, p.status, p.confidence, p.sides, String(size[0]), String(size[1]), String(size[2]), String(p.volumeCM3),
                    String(p.surfaceCM2), String(c[0]), String(c[1]), String(c[2]), p.placedVia ?? "",
                    q(p.touches.joined(separator: " ")), q(p.confirmedBy.joined(separator: " ")), q(p.note ?? "")].joined(separator: ",") + "\n"
        }
        for m in rec.report.missing {
            let size = m.sizeMM + [0, 0, 0]
            let c = m.centreMM + [0, 0, 0]
            csv += [m.label, m.kind, "", "", String(size[0]), String(size[1]), String(size[2]), String(m.volumeCM3), "",
                    String(c[0]), String(c[1]), String(c[2]), "", q(m.between.joined(separator: " ")), "", q(m.description)].joined(separator: ",") + "\n"
        }
        try csv.write(to: dir.appendingPathComponent("\(stem)_pieces.csv"), atomically: true, encoding: .utf8)

        // Models.
        let tris = assembledTriangles(rec, first: first, second: second)
        try writeOBJ(tris, rec: rec, dir: dir, stem: stem)
        try writeMissingOBJ(rec, dir: dir, stem: stem)

        // Images.
        if let img = assembledImage(tris, rec: rec, scan: scan, unit: unit) {
            try img.pngData()?.write(to: dir.appendingPathComponent("\(stem)_assembled.png"), options: .atomic)
        }
        if let img = asFoundImage(rec, first: first, scan: scan, unit: unit) {
            try img.pngData()?.write(to: dir.appendingPathComponent("\(stem)_as-found.png"), options: .atomic)
        }
    }

    static func writeOBJ(_ tris: [Tri], rec: Reconstruction, dir: URL, stem: String) throws {
        var mtl = ""
        for it in rec.items {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color(it.id).getRed(&r, green: &g, blue: &b, alpha: &a)
            mtl += "newmtl P\(it.id)\nKd \(r) \(g) \(b)\nKa 0.1 0.1 0.1\nd 1\n\n"
        }
        try mtl.write(to: dir.appendingPathComponent("\(stem)_assembled.mtl"), atomically: true, encoding: .utf8)
        var s = "# Crystal Bowl: pieces put back together (metres, +Y up). One group per piece.\nmtllib \(stem)_assembled.mtl\n"
        s.reserveCapacity(tris.count * 120)
        var n = 0
        var current = -1
        for t in tris {
            if t.piece != current {
                current = t.piece
                s += "o P\(t.piece)\ng P\(t.piece)\nusemtl P\(t.piece)\n"
            }
            for p in [t.a, t.b, t.c] { s += String(format: "v %.6f %.6f %.6f\n", p.x, p.y, p.z) }
            s += "f \(n + 1) \(n + 2) \(n + 3)\n"
            n += 3
        }
        try s.write(to: dir.appendingPathComponent("\(stem)_assembled.obj"), atomically: true, encoding: .utf8)
    }

    static func writeMissingOBJ(_ rec: Reconstruction, dir: URL, stem: String) throws {
        var s = "# Crystal Bowl: where material is missing (cells of the target shape no piece fills), metres.\n"
        var n = 0
        for (k, m) in rec.missing.enumerated() where m.kind == "missing_piece" {
            s += "o M\(k + 1)\ng M\(k + 1)\n"
            let h = m.cellSize * 0.46
            let step = Swift.max(1, m.cells.count / 1500)
            for i in stride(from: 0, to: m.cells.count, by: step) {
                let c = m.cells[i]
                for z in [-h, h] { for y in [-h, h] { for x in [-h, h] {
                    s += String(format: "v %.6f %.6f %.6f\n", c.x + x, c.y + y, c.z + z)
                } } }
                let faces = [(1, 3, 4, 2), (5, 6, 8, 7), (1, 2, 6, 5), (3, 7, 8, 4), (1, 5, 7, 3), (2, 4, 8, 6)]
                for (a, b, cc, d) in faces { s += "f \(n + a) \(n + b) \(n + cc) \(n + d)\n" }
                n += 8
            }
        }
        try s.write(to: dir.appendingPathComponent("\(stem)_missing.obj"), atomically: true, encoding: .utf8)
    }

    // MARK: Pictures

    enum ViewDir { case front, side, top }

    /// Flat-shaded orthographic drawing of triangles (painter's order), with labels at piece centres.
    static func draw(_ tris: [Tri], view: ViewDir, in rect: CGRect, g: CGContext, cells: [(SIMD3<Double>, Double)],
                     bounds: (lo: SIMD3<Double>, hi: SIMD3<Double>), labels: [Int: SIMD3<Double>]) -> Double {
        func proj(_ p: SIMD3<Double>) -> (Double, Double, Double) {
            switch view {
            case .front: return (p.x, -p.y, p.z)
            case .side: return (-p.z, -p.y, p.x)
            case .top: return (p.x, p.z, p.y)
            }
        }
        let light: SIMD3<Double> = view == .front ? SIMD3(0.3, 0.4, 1) : (view == .side ? SIMD3(1, 0.4, -0.3) : SIMD3(0.3, 1, 0.4))
        let l = simd_normalize(light)
        var lo2 = (Double.infinity, Double.infinity), hi2 = (-Double.infinity, -Double.infinity)
        for corner in [bounds.lo, bounds.hi, SIMD3(bounds.lo.x, bounds.hi.y, bounds.lo.z), SIMD3(bounds.hi.x, bounds.lo.y, bounds.hi.z),
                       SIMD3(bounds.lo.x, bounds.lo.y, bounds.hi.z), SIMD3(bounds.hi.x, bounds.hi.y, bounds.lo.z)] {
            let p = proj(corner)
            lo2 = (Swift.min(lo2.0, p.0), Swift.min(lo2.1, p.1))
            hi2 = (Swift.max(hi2.0, p.0), Swift.max(hi2.1, p.1))
        }
        let w = Swift.max(1e-6, hi2.0 - lo2.0), h = Swift.max(1e-6, hi2.1 - lo2.1)
        let k = Swift.min(Double(rect.width) * 0.86 / w, Double(rect.height) * 0.86 / h)
        let ox = Double(rect.midX) - (lo2.0 + w / 2) * k, oy = Double(rect.midY) - (lo2.1 + h / 2) * k
        func pt(_ p: SIMD3<Double>) -> CGPoint {
            let q = proj(p)
            return CGPoint(x: q.0 * k + ox, y: q.1 * k + oy)
        }
        let depth: [Double] = tris.map { proj($0.a).2 + proj($0.b).2 + proj($0.c).2 }
        let order = tris.indices.sorted { depth[$0] < depth[$1] }
        var rgb: [Int: (CGFloat, CGFloat, CGFloat)] = [:]
        for t in order {
            let tri = tris[t]
            let n = simd_cross(tri.b - tri.a, tri.c - tri.a)
            let len = simd_length(n)
            guard len > 0 else { continue }
            let shade = CGFloat(0.35 + 0.65 * abs(simd_dot(n / len, l)))
            if rgb[tri.piece] == nil {
                var r: CGFloat = 0, gg: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color(tri.piece).getRed(&r, green: &gg, blue: &b, alpha: &a)
                rgb[tri.piece] = (r, gg, b)
            }
            let c = rgb[tri.piece]!
            g.setFillColor(red: c.0 * shade, green: c.1 * shade, blue: c.2 * shade, alpha: 1)
            g.move(to: pt(tri.a))
            g.addLine(to: pt(tri.b))
            g.addLine(to: pt(tri.c))
            g.closePath()
            g.fillPath()
        }
        // Missing material, see-through red.
        g.setFillColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 0.28)
        for (c, size) in cells {
            let p = pt(c)
            let s = CGFloat(size * k)
            g.fill(CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
        }
        for (id, c) in labels {
            let p = pt(c)
            let text = "P\(id)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: UIColor.white]
            let sz = text.size(withAttributes: attrs)
            let box = CGRect(x: p.x - sz.width / 2 - 6, y: p.y - sz.height / 2 - 2, width: sz.width + 12, height: sz.height + 4)
            g.setFillColor(UIColor(white: 0.1, alpha: 0.75).cgColor)
            g.addPath(UIBezierPath(roundedRect: box, cornerRadius: 8).cgPath)
            g.fillPath()
            text.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attrs)
        }
        return k / 1000 // pixels per mm
    }

    static func assembledImage(_ tris: [Tri], rec: Reconstruction, scan: Scan, unit: LengthUnit) -> UIImage? {
        guard !tris.isEmpty else { return nil }
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        var sums: [Int: (SIMD3<Double>, Int)] = [:]
        for t in tris {
            for p in [t.a, t.b, t.c] {
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
            let c = (t.a + t.b + t.c) / 3
            let e = sums[t.piece] ?? (.zero, 0)
            sums[t.piece] = (e.0 + c, e.1 + 1)
        }
        let labels = sums.mapValues { $0.0 / Double($0.1) }
        let cells: [(SIMD3<Double>, Double)] = rec.missing.filter { $0.kind == "missing_piece" }.flatMap { m in m.cells.map { ($0, m.cellSize) } }
        for (c, _) in cells {
            lo = simd_min(lo, c)
            hi = simd_max(hi, c)
        }
        let panel: CGFloat = 820, gap: CGFloat = 30, head: CGFloat = 150
        let tableW: CGFloat = 1100
        let rows = rec.report.pieces.count + rec.report.missing.count + rec.report.guidance.count + 8
        let height = Swift.max(head + panel + 120, head + CGFloat(rows) * 40 + 80)
        let size = CGSize(width: 3 * panel + 4 * gap + tableW, height: height)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let g = ctx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            SampleSheet.text(scan.name + " – pieces put back together", at: CGPoint(x: gap, y: 30), size: 54, weight: .bold)
            let env = rec.report.envelope
            var sub = "Target: "
            if let e = env {
                if e.kind == "cylinder" { sub += "cylinder Ø " + unit.format(e.diameterMM ?? 0) + " × " + unit.format(e.lengthMM ?? 0) }
                else { sub += "box " + unit.formatList(e.sidesMM ?? []) }
                sub += e.given ? " (given)" : " (fitted to the pieces)"
            } else {
                sub += "none"
            }
            sub += " · red = missing material · geometry only, colours mark the pieces"
            SampleSheet.text(sub, at: CGPoint(x: gap, y: 96), size: 24, color: .darkGray)
            var ppm = 0.0
            for (i, (v, name)) in [(ViewDir.front, "Front"), (ViewDir.side, "Side"), (ViewDir.top, "Top")].enumerated() {
                let r = CGRect(x: gap + CGFloat(i) * (panel + gap), y: head, width: panel, height: panel)
                g.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
                g.setLineWidth(1.5)
                g.stroke(r)
                ppm = draw(tris, view: v, in: r, g: g, cells: cells, bounds: (lo, hi), labels: labels)
                SampleSheet.text(name, at: CGPoint(x: r.minX + 14, y: r.minY + 10), size: 28, weight: .bold)
            }
            SampleSheet.scaleBar(g, at: CGPoint(x: gap + 20, y: head + panel + 40), pxPerMM: CGFloat(ppm), unit: unit, maxWidth: 400)

            // Table.
            let tx = 3 * (panel + gap) + gap
            var y = head
            SampleSheet.text("Pieces", at: CGPoint(x: tx, y: y), size: 30, weight: .bold, color: SampleSheet.accent)
            y += 46
            for p in rec.report.pieces {
                g.setFillColor(color(p.id).cgColor)
                g.fill(CGRect(x: tx, y: y + 6, width: 22, height: 22))
                let line = "\(p.label)  " + unit.formatList(p.sizeMM) + String(format: "  %.2f cm³  ", p.volumeCM3) + statusText(p)
                SampleSheet.text(line, at: CGPoint(x: tx + 32, y: y), size: 22, mono: true)
                y += 36
            }
            if !rec.report.missing.isEmpty {
                y += 14
                SampleSheet.text("Missing", at: CGPoint(x: tx, y: y), size: 30, weight: .bold, color: UIColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
                y += 46
                for m in rec.report.missing {
                    SampleSheet.text(m.label + "  " + m.description, at: CGPoint(x: tx, y: y), size: 20)
                    y += 34
                }
            }
            if let share = rec.report.volumes.recoveredShare {
                y += 10
                SampleSheet.text(String(format: "Pieces fill %.0f%% of the target shape", share * 100), at: CGPoint(x: tx, y: y), size: 22, weight: .semibold)
                y += 36
            }
            if !rec.report.guidance.isEmpty {
                y += 14
                SampleSheet.text("Next", at: CGPoint(x: tx, y: y), size: 30, weight: .bold, color: SampleSheet.accent)
                y += 46
                for line in rec.report.guidance.prefix(10) {
                    SampleSheet.text("• " + String(line.prefix(95)), at: CGPoint(x: tx, y: y), size: 20)
                    y += 32
                }
            }
        }
    }

    static func statusText(_ p: PiecesReport.PieceEntry) -> String {
        switch p.status {
        case "anchor": return "reference"
        case "placed": return "placed (\(p.confidence))"
        case "unplaced": return "not placed"
        default: return p.status
        }
    }

    /// Top view of the first scan with each piece numbered where it lay, so it can be found on the table.
    static func asFoundImage(_ rec: Reconstruction, first: SceneMesh, scan: Scan, unit: LengthUnit) -> UIImage? {
        var tris: [Tri] = []
        var labels: [Int: SIMD3<Double>] = [:]
        for it in rec.items {
            labels[it.id] = it.first.centroid + SIMD3(0, it.first.hi.y, 0)
            for t in it.first.triangles {
                tris.append(Tri(a: first.positions[t.x], b: first.positions[t.y], c: first.positions[t.z], piece: it.id))
            }
        }
        for c in rec.split1.small {
            for t in c.triangles {
                tris.append(Tri(a: first.positions[t.x], b: first.positions[t.y], c: first.positions[t.z], piece: 12))
            }
        }
        guard !tris.isEmpty else { return nil }
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for t in tris { for p in [t.a, t.b, t.c] { lo = simd_min(lo, p); hi = simd_max(hi, p) } }
        let size = CGSize(width: 1600, height: 1400)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let g = ctx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            SampleSheet.text(scan.name + " – pieces as they lay (side 1, seen from above)", at: CGPoint(x: 30, y: 26), size: 40, weight: .bold)
            SampleSheet.text("\(rec.items.count) matched pieces numbered · \(rec.split1.small.count) small fragments in grey · \(rec.split1.specks) specks too small to measure",
                             at: CGPoint(x: 30, y: 80), size: 22, color: .darkGray)
            let r = CGRect(x: 30, y: 130, width: size.width - 60, height: size.height - 220)
            let ppm = draw(tris, view: .top, in: r, g: g, cells: [], bounds: (lo, hi), labels: labels)
            SampleSheet.scaleBar(g, at: CGPoint(x: 40, y: size.height - 70), pxPerMM: CGFloat(ppm), unit: unit, maxWidth: 360)
        }
    }
}

// MARK: - Building a pieces scan

extension AppModel {
    func runPiecesBuild(_ original: Scan) async {
        var scan = original
        scan.buildAttempts = (scan.buildAttempts ?? 0) + 1
        try? ScanStore.save(scan)
        let twoSides = scan.hasPhotos2 || scan.hasModel2
        do {
            if !scan.hasModel {
                try await photogrammetry(input: scan.imagesURL, checkpoint: scan.checkpointURL, output: scan.modelURL,
                                         from: 0, to: twoSides ? 0.38 : 0.7, label: "Building side 1")
            }
            if scan.hasPhotos2 && !scan.hasModel2 {
                try await photogrammetry(input: scan.images2URL, checkpoint: scan.checkpoint2URL, output: scan.model2URL,
                                         from: 0.38, to: 0.7, label: "Building side 2")
            }
            setProgress(0.72, "Finding the pieces…")
            let s = scan
            let summary = try await Task.detached(priority: .userInitiated) { () throws -> PiecesSummary in
                try PiecesWorker.run(s) { f, note in
                    Task { @MainActor in AppModel.current?.setProgress(0.72 + 0.27 * f, note) }
                }
            }.value
            scan.piecesResult = summary
            scan.buildRequested = nil
            if scan.photoCount == nil { scan.photoCount = ScanStore.countPhotos(in: scan.imagesURL) }
            let photosGoToDrive = uploadPhotos && (driveSignedIn || folderLinked)
            if !UserDefaults.standard.bool(forKey: AppModel.keepPhotosKey) && !photosGoToDrive {
                try? FileManager.default.removeItem(at: scan.imagesURL)
                try? FileManager.default.removeItem(at: scan.checkpointURL)
                if scan.hasModel2 {
                    try? FileManager.default.removeItem(at: scan.images2URL)
                    try? FileManager.default.removeItem(at: scan.checkpoint2URL)
                }
            }
            try? ScanStore.save(scan)
            reload()
            setProgress(1, "Done")
            BackgroundBuild.shared.end(success: true)
            Notifier.post(id: "pieces-\(scan.id)", title: "\(scan.name): \(summary.headline)",
                          body: scan.hasModel2 ? "Open the Pieces tab for the result and what is missing."
                              : "Side 1 is done. Turn every piece over where it lies and scan side 2, so the breaks underneath can be matched.")
            Task { await syncAllPending() }
        } catch {
            BackgroundBuild.shared.end(success: false)
            let interrupted = backgroundedDuringBuild || BackgroundBuild.shared.expired || UIApplication.shared.applicationState != .active
            if interrupted && (scan.buildAttempts ?? 0) < 8 {
                try? ScanStore.save(scan)
                Notifier.post(id: "paused-\(scan.id)", title: "\(scan.name): paused",
                              body: "iOS paused the work while the phone was busy. Open Crystal Bowl and it carries on.")
                if UIApplication.shared.applicationState == .active { buildQueue.append(scan.id) }
            } else {
                scan.buildRequested = nil
                try? ScanStore.save(scan)
                errorMessage = "Putting \"\(scan.name)\" together failed: \(error.localizedDescription). The photos and models are kept; tap Put together again to retry."
            }
            reload()
        }
    }

    /// Runs the matching again (after a change of target shape, or a newer app version).
    func reassemble(_ scan: Scan, target: TargetShape? = nil) {
        guard var s = scans.first(where: { $0.id == scan.id }) else { return }
        if let target { s.pieceTarget = target }
        s.buildRequested = true
        s.buildAttempts = 0
        try? ScanStore.save(s)
        reload()
        enqueueBuild(s.id)
    }
}

// MARK: - Screens

/// Target shape fields, in the user's unit.
struct TargetEditor: View {
    @Binding var kind: TargetShape.Kind
    @Binding var a: String
    @Binding var b: String
    @Binding var c: String
    @AppStorage(UnitPref.key) private var unitRaw = "mm"

    var body: some View {
        let u = UnitPref.unit.symbol
        Picker("Original shape", selection: $kind) {
            Text("Let the app work it out").tag(TargetShape.Kind.auto)
            Text("Cylinder (core plug)").tag(TargetShape.Kind.cylinder)
            Text("Cuboid (slab, block)").tag(TargetShape.Kind.cuboid)
            Text("Unknown, no target").tag(TargetShape.Kind.none)
        }
        if kind == .cylinder {
            LabeledContent("Diameter (\(u))") { TextField("e.g. 25.4", text: $a).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            LabeledContent("Length (\(u))") { TextField("optional", text: $b).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
        } else if kind == .cuboid {
            LabeledContent("Side a (\(u))") { TextField("longest", text: $a).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            LabeledContent("Side b (\(u))") { TextField("middle", text: $b).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            LabeledContent("Side c (\(u))") { TextField("shortest", text: $c).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
        }
    }

    static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? UnitPref.unit.mm($0) : nil }
    }

    static func target(_ kind: TargetShape.Kind, _ a: String, _ b: String, _ c: String) -> TargetShape {
        switch kind {
        case .cylinder:
            guard let d = number(a) else { return .auto }
            return TargetShape(kind: .cylinder, aMM: d, bMM: number(b))
        case .cuboid:
            return TargetShape(kind: .cuboid, aMM: number(a), bMM: number(b), cMM: number(c))
        default:
            return TargetShape(kind: kind)
        }
    }

    static func describe(_ t: TargetShape?) -> String {
        guard let t else { return "worked out by the app" }
        switch t.kind {
        case .auto: return "worked out by the app"
        case .none: return "none"
        case .cylinder: return "cylinder Ø " + (t.aMM.map(L) ?? "?") + (t.bMM.map { " × " + L($0) } ?? "")
        case .cuboid: return "cuboid " + [t.aMM, t.bMM, t.cMM].map { $0.map(L) ?? "?" }.joined(separator: " × ")
        }
    }
}

struct PiecesHome: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(UnitPref.key) private var unitRaw = "mm"
    @State private var name = ""
    @State private var kind: TargetShape.Kind = .auto
    @State private var a = ""
    @State private var b = ""
    @State private var c = ""

    private var sets: [Scan] { model.scans.filter { $0.isPieces } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Put broken pieces back together", systemImage: "puzzlepiece.extension.fill").font(.headline)
                        Text("Scan all the pieces at once, turn each one over, scan again. The app finds every piece, matches the breaks like a palaeontologist fitting a fossil, shows how they go together and what is missing, and sends it all to Google Drive.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Sample ID, e.g. Plug 7 broken", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TargetEditor(kind: $kind, a: $a, b: $b, c: $c)
                    Button {
                        model.startPiecesScan(name: name, target: TargetEditor.target(kind, a, b, c))
                        name = ""
                    } label: {
                        Label("Scan side 1 of the pieces", systemImage: "viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.isCaptureSupported)
                } header: {
                    Text("New set of pieces")
                } footer: {
                    Text("Giving the original shape (for a broken core plug, its diameter) helps the app tell the old outside from the breaks and size what is missing.")
                }
                Section {
                    if sets.isEmpty {
                        Text("No piece sets yet.").foregroundStyle(.secondary)
                    }
                    ForEach(sets) { s in
                        NavigationLink(value: s) { PiecesRow(scan: s, building: model.buildingID == s.id, progress: model.progress) }
                    }
                } header: {
                    Text("Piece sets")
                }
                Section("How to scan pieces") {
                    TipRow(icon: "square.grid.3x3.fill", color: Theme.teal,
                           text: "Spread the pieces on a matte, textured sheet (newspaper works), a finger-width apart. Breaks facing up where you can.")
                    TipRow(icon: "viewfinder", color: Theme.violet, text: "Fit the box round all of them, then walk round slowly, twice: low and higher.")
                    TipRow(icon: "arrow.uturn.down", color: .orange,
                           text: "Then turn every piece over where it lies, without moving it far, and scan side 2 from the piece set's page.")
                    TipRow(icon: "ruler", color: .green,
                           text: "Pieces from about 6 mm are matched. Smaller fragments down to about 1.5 mm are measured and counted; grains smaller than that are below what the phone can see: weigh those separately.")
                }
            }
            .navigationTitle("Pieces")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Scan.self) { s in PiecesDetailView(scanID: s.id) }
        }
    }
}

struct PiecesRow: View {
    let scan: Scan
    var building = false
    var progress = 0.0
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill").font(.title2).foregroundStyle(Theme.violet)
            VStack(alignment: .leading, spacing: 3) {
                Text(scan.name).font(.headline)
                if building {
                    Text("Working… \(Int(progress * 100))%").font(.caption).foregroundStyle(Theme.violet).monospacedDigit()
                } else if let r = scan.piecesResult {
                    Text(r.headline + (r.bothSides ? "" : " · side 2 not scanned yet")).font(.caption).foregroundStyle(.secondary)
                } else if scan.buildRequested == true {
                    Text("Waiting to build").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(scan.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PiecesDetailView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(UnitPref.key) private var unitRaw = "mm"
    let scanID: String
    @State private var report: PiecesReport?
    @State private var show3D = false
    @State private var editTarget = false
    @State private var kind: TargetShape.Kind = .auto
    @State private var a = ""
    @State private var b = ""
    @State private var c = ""

    private var scan: Scan? { model.scans.first { $0.id == scanID } }

    var body: some View {
        if let scan {
            List {
                statusSection(scan)
                if let r = report {
                    resultSections(scan, r)
                }
                Section {
                    LabeledContent("Original shape", value: TargetEditor.describe(scan.pieceTarget))
                    Button("Change the original shape and put together again") {
                        let t = scan.pieceTarget ?? .auto
                        kind = t.kind
                        let u = UnitPref.unit
                        a = t.aMM.map { u.format($0, symbol: false) } ?? ""
                        b = t.bMM.map { u.format($0, symbol: false) } ?? ""
                        c = t.cMM.map { u.format($0, symbol: false) } ?? ""
                        editTarget = true
                    }
                    .disabled(!scan.hasModel || model.buildingID == scan.id)
                    if scan.hasModel && model.buildingID != scan.id {
                        Button("Put together again") { model.reassemble(scan) }
                    }
                } header: {
                    Text("Settings")
                }
                Section {
                    let files = filesToShare(scan)
                    if !files.isEmpty {
                        ShareLink(items: files) { Label("Share the results (\(files.count) files)", systemImage: "square.and.arrow.up") }
                    }
                    if let d = scan.drive, d.complete, let when = d.lastSync {
                        Label("On Google Drive since \(when.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.icloud.fill")
                            .foregroundStyle(.green)
                    } else if model.driveSignedIn {
                        Label(model.driveStatus[scan.id] ?? "Waiting to upload", systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary)
                    }
                    Text("Google Drive › \(ScanPackage.rootFolder) › \(scan.id)_\(scan.fileStem) › model/pieces")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                } header: {
                    Text("Files")
                } footer: {
                    Text("pieces.json (every piece: size, volume, where it lay, where it goes, how sure; missing regions; what to do next), pieces.csv, the assembled model (OBJ, one group per piece, metres), the missing material (OBJ) and the pictures.")
                }
                Section {
                    Button("Delete this piece set", role: .destructive) { model.delete(scan) }
                }
            }
            .navigationTitle(scan.name)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: scan.piecesResult?.date) { report = loadReport(scan) }
            .fullScreenCover(isPresented: $show3D) { PiecesViewer(scan: scan) }
            .sheet(isPresented: $editTarget) {
                NavigationStack {
                    Form {
                        TargetEditor(kind: $kind, a: $a, b: $b, c: $c)
                    }
                    .navigationTitle("Original shape")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editTarget = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Put together") {
                                model.reassemble(scan, target: TargetEditor.target(kind, a, b, c))
                                editTarget = false
                            }
                        }
                    }
                }
            }
        } else {
            Text("This piece set was deleted.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func statusSection(_ scan: Scan) -> some View {
        Section {
            if model.buildingID == scan.id {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Working on the pieces", systemImage: "puzzlepiece.extension").font(.headline)
                    ProgressView(value: model.progress)
                    Text(model.progressNote).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text("You can use other apps or lock the phone; you'll get a notification.").font(.caption).foregroundStyle(.secondary)
                }
            } else if scan.buildRequested == true {
                Label("Waiting to build", systemImage: "clock")
            } else if let r = scan.piecesResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.headline).font(.headline)
                    if let share = r.recoveredShare {
                        Text(String(format: "The pieces fill %.0f%% of the original shape", share * 100)).font(.callout)
                    }
                    if let m = r.missingCM3, m > 0 {
                        Text("Missing material about " + LV(cm3: m)).font(.callout)
                    }
                }
            }
            if scan.hasModel && !scan.hasPhotos2 && !scan.hasModel2 && model.buildingID != scan.id {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Next: side 2", systemImage: "arrow.uturn.down.circle.fill").font(.headline).foregroundStyle(.orange)
                    Text("Turn every piece over where it lies (keep each one in its place) and scan again. Breaks that faced down can only be matched once they are seen.")
                        .font(.callout)
                    Button { model.startSecondSide(scan) } label: {
                        Label("Scan side 2", systemImage: "viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if scan.hasModel2 && model.buildingID != scan.id {
                Button("Scan side 2 again") { model.startSecondSide(scan) }
            }
        }
    }

    @ViewBuilder private func resultSections(_ scan: Scan, _ r: PiecesReport) -> some View {
        Section {
            if let img = UIImage(contentsOfFile: scan.piecesURL.appendingPathComponent("\(scan.fileStem)_assembled.png").path) {
                Image(uiImage: img).resizable().scaledToFit()
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            Button { show3D = true } label: { Label("Turn it round in 3D", systemImage: "rotate.3d") }
        } header: {
            Text("Put together")
        }
        Section {
            ForEach(r.pieces, id: \.id) { p in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(PiecesWorker.color(p.id))).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p.label) · " + PiecesWorker.statusText(p)).font(.callout.bold())
                        Text(LL(p.sizeMM) + " · " + LV(cm3: p.volumeCM3) + (p.sides == "both" ? " · both sides" : " · one side"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if !p.touches.isEmpty { Text("Touches " + p.touches.joined(separator: ", ")).font(.caption) }
                        if let n = p.note, p.status != "anchor" { Text(n).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
        } header: {
            Text("Pieces (\(r.pieces.count))")
        } footer: {
            Text("Sizes are the piece's own longest, middle and shortest extent. Confidence: high = confirmed by a second piece; medium = one clear fit; low = check by eye.")
        }
        if !r.missing.isEmpty {
            Section("Missing (\(r.missing.count))") {
                ForEach(r.missing, id: \.label) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.label).font(.callout.bold()).foregroundStyle(m.kind == "missing_piece" ? .red : .secondary)
                        Text(m.description).font(.caption)
                    }
                }
            }
        }
        if !r.guidance.isEmpty {
            Section("What to do next") {
                ForEach(r.guidance, id: \.self) { Text($0).font(.callout) }
            }
        }
        if !r.small.isEmpty {
            Section("Small fragments (\(r.small.count))") {
                Text(r.small.prefix(30).map { $0.label + " " + L($0.sizeMM) }.joined(separator: " · ")).font(.caption.monospacedDigit())
                if r.specks > 0 { Text("\(r.specks) specks below what the phone can measure.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        if let img = UIImage(contentsOfFile: scan.piecesURL.appendingPathComponent("\(scan.fileStem)_as-found.png").path) {
            Section("Where each piece lay") {
                Image(uiImage: img).resizable().scaledToFit()
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
        }
        Section {
            DisclosureGroup("Limits") {
                ForEach(r.limits, id: \.self) { Text($0).font(.caption) }
            }
        }
    }

    private func loadReport(_ scan: Scan) -> PiecesReport? {
        let url = scan.piecesURL.appendingPathComponent("\(scan.fileStem)_pieces.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .custom { path in AnyKey(Self.camel(path.last!.stringValue)) }
        return try? dec.decode(PiecesReport.self, from: data)
    }

    /// "volume_cm3" → "volumeCM3", "as_found_centre_mm" → "asFoundCentreMM" (the report's own property names).
    static func camel(_ snake: String) -> String {
        let parts = snake.split(separator: "_").map(String.init)
        guard let first = parts.first else { return snake }
        return first + parts.dropFirst().map { p in
            ["mm", "cm3", "cm2"].contains(p) ? p.uppercased() : p.prefix(1).uppercased() + p.dropFirst()
        }.joined()
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
    }

    private func filesToShare(_ scan: Scan) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: scan.piecesURL, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// The assembled pieces in 3D, with the missing material in see-through red.
struct PiecesViewer: View {
    @Environment(\.dismiss) private var dismiss
    let scan: Scan
    @State private var scene: SCNScene?
    @State private var missingNode: SCNNode?
    @State private var showMissing = true

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if let scene {
                    SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView("Loading…")
                }
                if missingNode != nil {
                    Toggle("Show missing material", isOn: $showMissing)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
            }
            .navigationTitle(scan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: showMissing) { _, v in missingNode?.isHidden = !v }
            .task {
                let dir = scan.piecesURL, stem = scan.fileStem
                let root = SCNScene()
                root.background.contents = UIColor(white: 0.1, alpha: 1)
                if let s = try? SCNScene(url: dir.appendingPathComponent("\(stem)_assembled.obj"), options: nil) {
                    let n = s.rootNode.clone()
                    root.rootNode.addChildNode(n)
                }
                if let s = try? SCNScene(url: dir.appendingPathComponent("\(stem)_missing.obj"), options: nil) {
                    let n = s.rootNode.clone()
                    n.enumerateHierarchy { node, _ in
                        guard let g = node.geometry else { return }
                        let m = SCNMaterial()
                        m.diffuse.contents = UIColor(red: 1, green: 0.1, blue: 0.1, alpha: 0.35)
                        m.lightingModel = .constant
                        m.isDoubleSided = true
                        m.writesToDepthBuffer = false
                        g.materials = [m]
                    }
                    root.rootNode.addChildNode(n)
                    missingNode = n
                }
                scene = root
            }
        }
    }
}
