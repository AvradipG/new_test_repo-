import Foundation
import SwiftUI
import UIKit
import ScanMath

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

        // 5. Coverage guide bookkeeping.
        var ledger = ShotLedger()
        _ = ledger.update(session: 20, files: nil, pose: .init(degrees: 0, band: 1), now: 0)
        let afterRestart = ledger.update(session: 1, files: nil, pose: .init(degrees: 90, band: 1), now: 1)
        check("Gap filling count", afterRestart.count == 1 && ledger.counted == 21, "a new pass that restarts the camera's count still adds photos")

        // 6. The app log.
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
