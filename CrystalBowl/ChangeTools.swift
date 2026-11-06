import Foundation
import SwiftUI
import UIKit
import ScanMath

// MARK: Phone scale reference (3.5)

/// The phone's scale correction from one scan of an object of known size. Used only when the tool is on and
/// "apply" is chosen, and only for scans without their own caliper check.
enum PhoneScale {
    static let factorKey = "tools.scaleRef.factor"
    static let sourceKey = "tools.scaleRef.source"
    static let applyKey = "tools.scaleRef.apply"

    static var factor: Double? {
        let f = UserDefaults.standard.double(forKey: factorKey)
        return f > 0 ? f : nil
    }

    /// The factor scans without a caliper check get: 1 unless the tool is on and set to apply.
    static var applied: Double {
        guard ExtraTool.scaleRef.isOn, UserDefaults.standard.bool(forKey: applyKey), let f = factor else { return 1 }
        return f
    }
}

struct ScaleRefRows: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    @AppStorage(PhoneScale.applyKey) private var apply = false
    @AppStorage(PhoneScale.factorKey) private var stored = 0.0
    @AppStorage(PhoneScale.sourceKey) private var source = ""
    @State private var axis = 3
    @State private var trueMM: Double?
    @State private var note: String?

    var body: some View {
        Group {
            Picker("Known length of this object", selection: $axis) {
                Text("Height").tag(3)
                Text("a (longest)").tag(0)
                Text("b").tag(1)
                Text("c (shortest)").tag(2)
            }
            LabeledContent("True length (mm)") {
                TextField("e.g. 25.40", value: $trueMM, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Button("Make this scan the phone's scale reference") {
                // The scan's own LiDAR length, before any correction.
                guard let t = trueMM, let scanned = scan.modelLength(axis: axis) else { note = "Measure the scan first and type the true length."; return }
                guard let f = ScaleReference.factor(trueMM: t, scannedMM: scanned) else {
                    note = String(format: "%.2f mm against %.2f mm scanned is more than 20 %% apart: check the axis and the number.", t, scanned)
                    return
                }
                stored = f
                source = "\(scan.name), \(Date().formatted(date: .abbreviated, time: .omitted))"
                note = nil
                AppLog.info("tools", String(format: "Phone scale reference set: factor %.4f", f))
            }
            if stored > 0 {
                LabeledContent("Phone scale factor", value: String(format: "%.4f (%+.2f %%)", stored, (stored - 1) * 100))
                Text("From \(source)").font(.caption).foregroundStyle(.secondary)
                Toggle("Use it for scans without a caliper check", isOn: $apply)
                    .onChange(of: apply) { _, _ in model.reload() }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
        }
    }
}

// MARK: Change map between two scans (3.5)

struct CompareRows: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    @State private var otherID: String?
    @State private var working = false
    @State private var result: ChangeSummary?

    private var others: [Scan] {
        let all = model.scans.filter { $0.id != scan.id && $0.hasModel && !$0.isPieces }
        return all.filter { $0.sampleKey == scan.sampleKey } + all.filter { $0.sampleKey != scan.sampleKey }
    }

    var body: some View {
        Group {
            if others.isEmpty {
                Text("Compare needs another scan with a model.").foregroundStyle(.secondary)
            } else {
                Picker("Compare with", selection: Binding(get: { otherID ?? others.first?.id ?? "" }, set: { otherID = $0 })) {
                    ForEach(others) { s in Text("\(s.name) · \(s.created.formatted(date: .abbreviated, time: .omitted))").tag(s.id) }
                }
                Button {
                    run()
                } label: {
                    if working { ProgressView() } else { Label("Make the change map", systemImage: "square.3.layers.3d.down.right") }
                }
                .disabled(working)
            }
            if let r = result {
                if let img = UIImage(contentsOfFile: r.picture.path) {
                    Image(uiImage: img).resizable().scaledToFit().listRowInsets(EdgeInsets())
                }
                Text(r.text).font(.callout.monospacedDigit())
                ShareLink(items: r.files) { Label("Share the map (PNG, coloured PLY, JSON)", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private func run() {
        guard let other = others.first(where: { $0.id == (otherID ?? others.first?.id) }) else { return }
        working = true
        let me = scan
        Task {
            let out = await Task.detached { ChangeMapExport.make(compared: me, reference: other) }.value
            working = false
            if let out {
                result = out
                AppLog.info("tools", "Change map made: \(out.text)")
                Task { await model.syncAllPending() }
            } else {
                model.errorMessage = "Couldn't compare the two models."
            }
        }
    }
}

struct ChangeSummary: Sendable {
    let text: String
    let picture: URL
    let files: [URL]
}

enum ChangeMapExport {
    /// This scan (`compared`) against an earlier one (`reference`), both with their own scale corrections.
    static func make(compared: Scan, reference: Scan) -> ChangeSummary? {
        guard let b = MeshTools.loadMesh(compared.modelURL), let a = MeshTools.loadMesh(reference.modelURL),
              let r = ChangeMap.compare(reference: a, compared: b, scaleA: reference.scaleFactor, scaleB: compared.scaleFactor)
        else { return nil }
        let dir = compared.exportsURL.appendingPathComponent("change", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = "\(compared.fileStem)_vs_\(reference.fileStem)"
        let range = max(r.p95Abs, 0.0002)
        let mm = 1000.0
        let volA = (reference.stats?.volumeCM3 ?? 0) * pow(reference.scaleFactor, 3)
        let volB = (compared.stats?.volumeCM3 ?? 0) * pow(compared.scaleFactor, 3)

        // Coloured PLY of this scan, moved onto the reference, in millimetres.
        var ply = "ply\nformat ascii 1.0\ncomment Crystal Bowl change map: \(compared.name) against \(reference.name), mm, red = outside, blue = inside\n"
        ply += "element vertex \(b.positions.count)\nproperty float x\nproperty float y\nproperty float z\n"
        ply += "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty float distance_mm\n"
        ply += "element face \(b.indices.count / 3)\nproperty list uchar int vertex_indices\nend_header\n"
        ply.reserveCapacity(b.positions.count * 48 + b.indices.count * 8)
        var moved: [SIMD3<Double>] = []
        moved.reserveCapacity(b.positions.count)
        for (i, p) in b.positions.enumerated() {
            let q = r.pose.apply(SIMD3<Double>(p) * compared.scaleFactor)
            moved.append(q)
            let c = ChangeMap.colour(r.signed[i], range: range)
            ply += String(format: "%.4f %.4f %.4f %d %d %d %.4f\n", q.x * mm, q.y * mm, q.z * mm, c.r, c.g, c.b, r.signed[i] * mm)
        }
        var k = 0
        while k + 2 < b.indices.count {
            ply += "3 \(b.indices[k]) \(b.indices[k + 1]) \(b.indices[k + 2])\n"
            k += 3
        }
        let plyURL = dir.appendingPathComponent("\(stem)_change.ply")
        let pngURL = dir.appendingPathComponent("\(stem)_change.png")
        let jsonURL = dir.appendingPathComponent("\(stem)_change.json")

        let text = String(format: "Median %+.2f mm, mean %+.2f mm, 95 %% within ±%.2f mm, largest %.2f mm; alignment fit ±%.2f mm; volume %+.2f cm³",
                          r.median * mm, r.mean * mm, r.p95Abs * mm, r.maxAbs * mm, r.fitRMS * mm, volB - volA)
        let json: [String: Any] = [
            "schema": "crystal-bowl.change-map/1", "units": "mm", "app_version": AppInfo.label,
            "compared_scan_id": compared.id, "reference_scan_id": reference.id,
            "median_mm": r.median * mm, "mean_mm": r.mean * mm, "rms_mm": r.rms * mm, "p95_abs_mm": r.p95Abs * mm,
            "max_abs_mm": r.maxAbs * mm, "alignment_fit_rms_mm": r.fitRMS * mm,
            "volume_reference_cm3": volA, "volume_compared_cm3": volB,
            "pose_compared_to_reference": r.pose.matrix,
            "colour_range_mm": range * mm,
            "convention": "signed distance from each compared vertex to the reference surface along the reference normal; + = outside (gained), - = inside (lost)",
            "note": "Both surfaces come from photogrammetry; differences below about twice the alignment fit are noise.",
        ]
        do {
            try ply.write(to: plyURL, atomically: true, encoding: .utf8)
            try picture(moved, r.signed, range: range, title: "\(compared.name) vs \(reference.name)", text: text).write(to: pngURL, options: .atomic)
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: jsonURL, options: .atomic)
        } catch {
            AppLog.error("tools", "Writing the change map failed", error, scan: compared)
            return nil
        }
        return ChangeSummary(text: text, picture: pngURL, files: [pngURL, plyURL, jsonURL])
    }

    /// The change map unrolled round the reference's long axis: across = angle round the rock, up = along it.
    static func picture(_ pts: [SIMD3<Double>], _ d: [Double], range: Double, title: String, text: String) -> Data {
        let frame = ScanMath.principalFrame(pts.map { SIMD3<Float>($0) })
        let w = 900.0, h = 420.0, top = 54.0, bottom = 46.0
        let size = CGSize(width: w, height: top + h + bottom)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let lo = frame.lo[0], span = max(frame.hi[0] - frame.lo[0], 1e-9)
        return UIGraphicsImageRenderer(size: size, format: fmt).pngData { ctx in
            UIColor(white: 0.12, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (i, p) in pts.enumerated() {
                let rel = p - frame.center
                let t = (rel * frame.axes[0]).sum()
                let u = (rel * frame.axes[1]).sum(), v = (rel * frame.axes[2]).sum()
                let x = (atan2(v, u) + .pi) / (2 * .pi) * w
                let y = top + h - (t - lo) / span * h
                let c = ChangeMap.colour(d[i], range: range)
                UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1).setFill()
                ctx.fill(CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
            }
            let big: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: UIColor.white]
            let small: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: UIColor(white: 0.85, alpha: 1)]
            (title as NSString).draw(at: CGPoint(x: 12, y: 8), withAttributes: big)
            (text as NSString).draw(in: CGRect(x: 12, y: 32, width: w - 24, height: 20), withAttributes: small)
            // Colour bar.
            let barY = top + h + 14
            for k in 0..<300 {
                let dd = (Double(k) / 299 * 2 - 1) * range
                let c = ChangeMap.colour(dd, range: range)
                UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1).setFill()
                ctx.fill(CGRect(x: 12 + Double(k), y: barY, width: 1, height: 12))
            }
            (String(format: "−%.2f mm (lost)", range * 1000) as NSString).draw(at: CGPoint(x: 12, y: barY + 14), withAttributes: small)
            (String(format: "+%.2f mm (gained)", range * 1000) as NSString).draw(at: CGPoint(x: 230, y: barY + 14), withAttributes: small)
            ("across: angle round the long axis · up: along it" as NSString).draw(at: CGPoint(x: 340, y: barY), withAttributes: small)
        }
    }
}
