import Foundation
import SwiftUI
import UIKit
import ScanMath
import simd
import PDFKit

/// Runs the app's own pipeline on a demo rock (a 1.5-inch plug, 50 mm long, made in code) and checks every
/// answer against the known size. It needs no camera, network or permission, so it runs by itself once after
/// each update, and from About › Self-test. Results go to the app log (and so to Drive) as PASS / FAIL lines.
enum SelfTest {
    struct Line: Identifiable, Sendable {
        let id = UUID()
        let name: String
        /// nil = can't be checked without the camera, the network or a permission.
        let pass: Bool?
        let detail: String
    }

    static let lastBuildKey = "selftest.lastBuild"
    static let radiusMM = 19.05, heightMM = 50.0

    static func run() -> [Line] {
        var out: [Line] = []
        func check(_ name: String, _ ok: Bool, _ detail: String) { out.append(Line(name: name, pass: ok, detail: detail)) }
        let fm = FileManager.default
        let demo = DemoRock.cylinder(radius: radiusMM / 1000, height: heightMM / 1000)
        let id = "selftest-\(Int(Date().timeIntervalSince1970))"
        let scan = Scan(id: id, name: "Self-test plug", created: Date())
        defer { try? fm.removeItem(at: scan.folderURL) }

        // 1. The model reader (Model I/O), with an OBJ of the demo rock.
        let mesh = demo
        do {
            try fm.createDirectory(at: scan.exportsURL, withIntermediateDirectories: true)
            var obj = ""
            for p in demo.positions { obj += "v \(p.x) \(p.y) \(p.z)\n" }
            var i = 0
            while i + 2 < demo.indices.count {
                obj += "f \(demo.indices[i] + 1) \(demo.indices[i + 1] + 1) \(demo.indices[i + 2] + 1)\n"
                i += 3
            }
            let url = scan.exportsURL.appendingPathComponent("demo.obj")
            try obj.write(to: url, atomically: true, encoding: .utf8)
            if let m = MeshTools.loadMesh(url), !m.indices.isEmpty {
                let ys = m.positions.map { Double($0.y) }
                let tall = ((ys.max() ?? 0) - (ys.min() ?? 0)) * 1000
                check("Model file reading", abs(tall - heightMM) < 0.05,
                      String(format: "%d points, %d triangles, %.2f mm tall", m.positions.count, m.indices.count / 3, tall))
            } else {
                check("Model file reading", false, "the demo model could not be read back")
            }
        } catch {
            check("Model file reading", false, AppLog.describe(error))
        }

        // 2. Measurements.
        let stats = ScanMath.stats(positions: mesh.positions, indices: mesh.indices, unitToMM: 1000)
        let volume = Double.pi * radiusMM * radiusMM * heightMM / 1000
        check("Volume", stats.isClosed && abs(stats.volumeCM3 - volume) < volume * 0.015,
              String(format: "%.2f cm³ (expected %.2f), closed: %@", stats.volumeCM3, volume, stats.isClosed ? "yes" : "no"))
        let h = stats.upright?.heightMM ?? 0, d = stats.upright?.cylinderDiameterMM ?? 0
        check("Height and micro-CT cylinder", abs(h - heightMM) < 0.3 && abs(d - 2 * radiusMM) < 0.3,
              String(format: "height %.2f mm, cylinder Ø %.2f mm (expected %.1f and %.2f)", h, d, heightMM, 2 * radiusMM))

        // 3. Cross-sections, pictures, table, all-in-one picture and Drive roles.
        var tested = scan
        tested.stats = stats
        do {
            let series = try CrossSectionMaker.make(scan: tested, axis: 3, spacingMM: 5, mesh: mesh)
            let pngs = series.imageURLs(in: tested)
            let mid = series.rows[series.rows.count / 2]
            let area = Double.pi * radiusMM * radiusMM
            check("Cross-sections", series.rows.count == 10 && pngs.count == 10 && abs(mid.areaMM2 - area) < area * 0.02,
                  String(format: "%d slices, %d pictures, middle area %.0f mm² (expected %.0f)", series.rows.count, pngs.count, mid.areaMM2, area))
            let one = series.allInOneURL(in: tested)
            let csv = series.folderURL(in: tested).appendingPathComponent("\(series.folderName).csv")
            check("All-in-one picture and table", fm.fileExists(atPath: one.path) && fm.fileExists(atPath: csv.path),
                  "all-slices PNG and CSV written")
            let thumb = pngs.first.flatMap { SectionThumbs.image($0, maxPixel: 200) }
            check("Slice viewer pictures", thumb != nil, thumb.map { "thumbnail \(Int($0.size.width))×\(Int($0.size.height)) px" } ?? "no thumbnail")
            let roles = Set(ScanPackage.files(for: tested, includePhotos: false).map { ScanPackage.role($0.0) })
            check("Drive file list", roles.contains("section_image") && roles.contains("section_all_in_one") && roles.contains("section_table"),
                  "\(roles.count) kinds of file listed for upload")
        } catch {
            check("Cross-sections", false, AppLog.describe(error))
        }

        // 4. Extra tools.
        if let b = Density.bulk(massG: 150, volumeCM3: volume), let p = Density.porosity(bulk: b, grain: 2.65) {
            check("Bulk density and porosity", abs(b - 150 / volume) < 1e-9 && p > 0 && p < 1, String(format: "150 g → %.3f g/cm³, porosity %.1f %%", b, p * 100))
        } else {
            check("Bulk density and porosity", false, "no result")
        }
        let fits = VirtualCoring.longestPlug(positions: mesh.positions, indices: mesh.indices, diameter: 0.0254, vertical: true, step: 0.001, gridStep: 0.002)
        let tooBig = VirtualCoring.longestPlug(positions: mesh.positions, indices: mesh.indices, diameter: 0.0508, vertical: true, step: 0.001, gridStep: 0.002)
        let len = (fits?.length ?? 0) * 1000
        check("Virtual coring", abs(len - heightMM) <= 1.1 && (tooBig?.length ?? 1) == 0,
              String(format: "1-inch plug %.1f mm long (expected %.0f), 2-inch plug doesn't fit: %@", len, heightMM, (tooBig?.length ?? 1) == 0 ? "yes" : "no"))
        let frame = CTFrame.make(mesh.positions)
        let ct = mesh.positions.map { frame.apply($0, scale: 1000) }
        let zMin = ct.map(\.z).min() ?? -1, zMax = ct.map(\.z).max() ?? -1
        let rMax = ct.map { hypot($0.x, $0.y) }.max() ?? -1
        check("Micro-CT frame", abs(zMin) < 0.01 && abs(zMax - heightMM) < 0.01 && abs(rMax - radiusMM) < 0.05,
              String(format: "z %.2f to %.2f mm, radius %.2f mm", zMin, zMax, rMax))
        let amp = radiusMM * tan(30 * Double.pi / 180)
        let angles = [20.0, 140, 260]
        let bed = BeddingFit.fit(angles: angles, heights: angles.map { 25 + amp * cos(($0 - 75) * .pi / 180) }, radiusMM: radiusMM)
        check("Bedding dip", bed.map { abs($0.dipDegrees - 30) < 0.01 && abs($0.highAngleDegrees - 75) < 0.01 } ?? false,
              bed.map { String(format: "dip %.2f° highest at %.1f° (expected 30° at 75°)", $0.dipDegrees, $0.highAngleDegrees) } ?? "no fit")

        let swollen = DemoRock.cylinder(radius: radiusMM / 1000 + 0.0005, height: heightMM / 1000)
        let turned = Pose.rotation(axis: SIMD3(0, 1, 0), degrees: 40) * Pose.rotation(axis: SIMD3(1, 0, 0), degrees: 25)
        let movedSwollen = (swollen.positions.map { SIMD3<Float>(turned * SIMD3<Double>($0) + SIMD3(0.05, 0.01, -0.03)) }, swollen.indices)
        if let ch = ChangeMap.compare(reference: mesh, compared: movedSwollen) {
            check("Change map", abs(ch.median * 1000 - 0.5) < 0.1,
                  String(format: "a plug 0.5 mm thicker, turned and moved: median %+.2f mm, fit ±%.3f mm", ch.median * 1000, ch.fitRMS * 1000))
        } else {
            check("Change map", false, "no result")
        }
        let sf = ScaleReference.factor(trueMM: 25.4, scannedMM: 25.0)
        check("Phone scale reference", sf.map { abs($0 - 1.016) < 1e-9 } ?? false && ScaleReference.factor(trueMM: 25.4, scannedMM: 50) == nil,
              sf.map { String(format: "25.4 mm object scanned as 25.0 mm → factor %.4f; a 2× mix-up is refused", $0) } ?? "no factor")

        // 5. Coverage guide bookkeeping.
        var ledger = ShotLedger()
        _ = ledger.update(session: 20, files: nil, pose: .init(degrees: 0, band: 1), now: 0)
        let afterRestart = ledger.update(session: 1, files: nil, pose: .init(degrees: 90, band: 1), now: 1)
        check("Gap filling count", afterRestart.count == 1 && ledger.counted == 21, "a new pass that restarts the camera's count still adds photos")

        // 6. Reference mark (3.8): a thin line, a little darker than the rock, red at the top, beside a bold sample
        // number written along the sample. The line must win (in 3.7 a written label was taken for the mark).
        do {
            let w = 720, h = 300
            var rgb = [SIMD3<Float>](repeating: SIMD3<Float>(0.62, 0.62, 0.60), count: w * h)
            var seed: UInt64 = 7
            for i in rgb.indices {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let n = Float(seed >> 40) / Float(1 << 24) * 0.1 - 0.05
                rgb[i] += SIMD3<Float>(repeating: n)
            }
            for y in 0..<h {
                if (40..<260).contains(y) {
                    let r = (y - 40) % 55
                    for x in 100..<160 where r < 44 && (x < 108 || x >= 152 || r < 8 || r >= 36) {
                        rgb[y * w + x] = SIMD3<Float>(0.06, 0.06, 0.07)
                    }
                }
                let c = 500 + y * 6 / h
                for x in c...(c + 2) { rgb[y * w + x] = y < 30 ? SIMD3<Float>(0.78, 0.18, 0.14) : SIMD3<Float>(0.47, 0.47, 0.45) }
            }
            let m = MarkFinder.detect(rgb: rgb, width: w, height: h, circumferenceMM: 80)
            let ok = m.map { abs($0.angle - 252) < 3 && $0.redEnd == .top } ?? false
            check("Reference mark finder", ok, m.map {
                String(format: "found %@ at %.1f° (expected the thin line at 252°, not the label at 65°), confidence %.2f",
                       $0.kind.rawValue, $0.angle, $0.confidence)
            } ?? "nothing found (expected the thin line at 252°)")
        }

        // 7. Sheet text is wrapped to its box instead of running off it (3.8).
        let long = "0° = reference mark (the side that faced the X-ray source) · view angle = sample turned from 0°, + = counter-clockwise seen from above (SliceLock convention)"
        let wrappedLines = SampleSheet.wrapped(long, size: 26, maxWidth: 900)
        let widest = wrappedLines.map { SampleSheet.width($0, size: 26) }.max() ?? 0
        check("Sheet text fits", wrappedLines.count > 1 && widest <= 900,
              String(format: "%d lines, widest %.0f px of 900", wrappedLines.count, widest))

        // 8. Scanning mat (3.10): every PDF in the app, at true size; and the scale-photo caption.
        var matOK = true
        var matText: [String] = []
        for paper in ScanningMat.Paper.allCases {
            for tone in ScanningMat.Tone.allCases {
                guard let u = ScanningMat.url(paper, tone), let doc = PDFDocument(url: u), let page = doc.page(at: 0) else {
                    matOK = false
                    matText.append("\(paper.rawValue) \(tone.rawValue) missing")
                    continue
                }
                let b = page.bounds(for: .mediaBox)
                let w = Double(b.width) * 25.4 / 72, h = Double(b.height) * 25.4 / 72
                let want: (Double, Double) = paper == .a4 ? (210, 297) : (215.9, 279.4)
                if abs(w - want.0) > 0.2 || abs(h - want.1) > 0.2 { matOK = false }
                matText.append(String(format: "%@ %@ %.1f × %.1f mm", paper.rawValue, tone.rawValue, w, h))
            }
        }
        check("Scanning mat PDFs (1:1)", matOK, matText.joined(separator: ", "))
        let fmt1 = UIGraphicsImageRendererFormat()
        fmt1.scale = 1
        let plain = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: fmt1).image { c in
            UIColor.gray.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let stamped = ScalePhotos.stamp(plain, "self-test caption")
        check("Scale photo caption", stamped.size.width == 400 && stamped.size.height > 300,
              String(format: "%.0f × %.0f px, caption strip below the photo", stamped.size.width, stamped.size.height))

        // 9. Which mat (3.11): a dark rock in the middle of a light frame, and the advice for pale and dark rock.
        let probe = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: fmt1).image { c in
            UIColor(white: 0.92, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            UIColor(white: 0.3, alpha: 1).setFill()
            c.cgContext.fillEllipse(in: CGRect(x: 75, y: 75, width: 150, height: 150))
        }
        let tone = RockTone.measure(probe)
        let toneOK = tone.map { abs($0.rock - 0.3) < 0.05 && abs($0.surround - 0.92) < 0.05 } ?? false
        let adviceOK = MatAdvisor.advise(rockLuma: 0.3).tone == .light && MatAdvisor.advise(rockLuma: 0.8).tone == .dark
        check("Scanning mat advice", toneOK && adviceOK && ScanningMat.guideURL != nil,
              tone.map { String(format: "rock %.2f on %.2f → light mat; pale rock → dark mat; guide PDF %@", $0.rock, $0.surround,
                                ScanningMat.guideURL == nil ? "missing" : "present") } ?? "could not measure")

        // 10. The app log.
        let marker = "self-test marker \(id)"
        AppLog.info("selftest", marker)
        AppLog.flush()
        check("App log", AppLog.tail(20).contains(marker), "written and read back")

        out.append(Line(name: "Camera, Photos, Google Drive, label reading", pass: nil,
                        detail: "need the camera, the network or a permission: check them by hand"))
        return out
    }

    /// Runs off the main thread, writes every line to the log and returns the lines.
    @MainActor
    static func runAndLog(reason: String) async -> [Line] {
        AppLog.info("selftest", "Self-test started (\(reason))")
        let lines = await Task.detached { run() }.value
        for l in lines {
            let tag = l.pass.map { $0 ? "PASS" : "FAIL" } ?? "SKIP"
            if l.pass == false { AppLog.error("selftest", "\(tag) \(l.name): \(l.detail)") } else { AppLog.info("selftest", "\(tag) \(l.name): \(l.detail)") }
        }
        let failed = lines.filter { $0.pass == false }.count
        AppLog.info("selftest", failed == 0 ? "Self-test passed" : "Self-test: \(failed) check(s) failed")
        UserDefaults.standard.set(AppInfo.build, forKey: lastBuildKey)
        return lines
    }
}

struct SelfTestSection: View {
    @State private var lines: [SelfTest.Line] = []
    @State private var running = false

    var body: some View {
        Section {
            Button {
                running = true
                Task {
                    lines = await SelfTest.runAndLog(reason: "button")
                    running = false
                }
            } label: {
                if running { ProgressView() } else { Label("Run the self-test", systemImage: "checkmark.seal") }
            }
            .disabled(running)
            ForEach(lines) { l in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: l.pass == nil ? "minus.circle" : (l.pass! ? "checkmark.circle.fill" : "xmark.octagon.fill"))
                        .foregroundStyle(l.pass == nil ? Color.secondary : (l.pass! ? Color.green : Color.red))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.name).font(.callout)
                        Text(l.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Self-test")
        } footer: {
            Text("Checks the app on a demo rock made in code (a 1.5-inch plug, 50 mm long): reading a model, measuring, cross-sections and their pictures, the Drive file list, the extra tools and the log. It runs by itself once after each update; the results go to the app log.")
        }
    }
}
