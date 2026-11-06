import Foundation
import SwiftUI
import UIKit
import VisionKit
import ScanMath

// MARK: Options

/// Optional lab tools (3.4). All are off until switched on in Settings › Extra tools, so the core scan, build,
/// measure and slice flow is unchanged. Their maths is unit-tested on GitHub and run by the self-test.
enum ExtraTool: String, CaseIterable, Identifiable {
    case density, coring, ctFrame, bedding, labelID, changeMap, scaleRef
    var id: String { rawValue }
    var key: String { "tools.\(rawValue)" }
    var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    var title: String {
        switch self {
        case .density: return "Bulk density and porosity"
        case .coring: return "Virtual coring (will a plug fit?)"
        case .ctFrame: return "Export in the micro-CT frame"
        case .bedding: return "Bedding or fracture dip"
        case .labelID: return "Sample ID from a label (QR, barcode or text)"
        case .changeMap: return "Change map between two scans"
        case .scaleRef: return "Phone scale reference"
        }
    }

    var detail: String {
        switch self {
        case .density: return "Type in the weighed mass; the app divides it by the scanned volume. With a grain density it also gives porosity."
        case .coring: return "Finds the longest 1″ or 1.5″ plug that fits inside the rock, up as scanned or along its long axis."
        case .ctFrame: return "Writes the model in millimetres with z up and the origin on the plug axis at the bottom, plus the matrix, for lining up with the CT."
        case .bedding: return "Tap three or more points along a layer on the unrolled side picture; the app fits the plane and gives its dip."
        case .labelID: return "Point the camera at the sample's label to fill in the Sample ID."
        case .changeMap: return "Lines up two scans of the same rock (for example before and after a test) and colours where the surface moved."
        case .scaleRef: return "Scan an object of known size once; the phone's correction can then be used for scans without a caliper check."
        }
    }
}

struct ExtraToolsSettingsSection: View {
    @AppStorage("tools.density") private var density = false
    @AppStorage("tools.coring") private var coring = false
    @AppStorage("tools.ctFrame") private var ctFrame = false
    @AppStorage("tools.bedding") private var bedding = false
    @AppStorage("tools.labelID") private var labelID = false
    @AppStorage("tools.changeMap") private var changeMap = false
    @AppStorage("tools.scaleRef") private var scaleRef = false

    var body: some View {
        Section {
            toggle(.density, $density)
            toggle(.coring, $coring)
            toggle(.ctFrame, $ctFrame)
            toggle(.bedding, $bedding)
            toggle(.labelID, $labelID)
            toggle(.changeMap, $changeMap)
            toggle(.scaleRef, $scaleRef)
        } header: {
            Text("Extra tools")
        } footer: {
            Text("Off by default. Each one adds a row on the scan page and leaves scanning, building, measuring and slicing as they are. Their sums are checked by the self-test in About.")
        }
    }

    private func toggle(_ t: ExtraTool, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title)
                Text(t.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Records

struct CoringRecord: Codable, Hashable {
    var diameterMM: Double
    var vertical: Bool
    var maxLengthMM: Double
    /// How far the plug's centre line is from the rock's mean point, mm.
    var offsetMM: Double
    var fromMM: Double
    var date: Date
}

struct BeddingRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var dipDegrees: Double
    var highAngleDegrees: Double
    var centreHeightMM: Double
    var rmsMM: Double
    var points: Int
    /// "mark" when angles are counted from the reference mark, else "chosen angle".
    var reference: String
    var date: Date
}

extension AppModel {
    func updateScan(_ id: String, _ change: (inout Scan) -> Void) {
        guard var s = scans.first(where: { $0.id == id }) else { return }
        change(&s)
        try? ScanStore.save(s)
        LabToolsFile.write(s)
        reload()
    }
}

/// Exports/lab-tools.json: what the extra tools found, so it travels to Drive with the scan.
enum LabToolsFile {
    static func url(_ scan: Scan) -> URL { scan.exportsURL.appendingPathComponent("\(scan.fileStem)_lab-tools.json") }

    static func write(_ s: Scan) {
        var d: [String: Any] = ["schema": "crystal-bowl.lab-tools/1", "units": "mm, g, g/cm3, degrees", "scan_id": s.id,
                                "app_version": AppInfo.label, "caliper_scale_factor": s.scaleFactor]
        let volume = (s.stats?.volumeCM3 ?? 0) * pow(s.scaleFactor, 3)
        if let m = s.massG {
            d["mass_g"] = m
            d["volume_cm3"] = volume
            if let b = Density.bulk(massG: m, volumeCM3: volume) {
                d["bulk_density_g_cm3"] = b
                if let g = s.grainDensity {
                    d["grain_density_g_cm3"] = g
                    if let p = Density.porosity(bulk: b, grain: g) { d["porosity_fraction"] = p }
                }
            }
            d["density_note"] = (s.stats?.isClosed ?? false) ? "volume from a closed surface" : "surface not closed: volume and density are approximate"
        }
        if let c = s.coring, !c.isEmpty {
            d["virtual_coring"] = c.map { ["plug_diameter_mm": $0.diameterMM, "direction": $0.vertical ? "up as scanned" : "long axis a",
                                           "longest_plug_mm": $0.maxLengthMM, "centre_offset_mm": $0.offsetMM,
                                           "starts_mm_from_end": $0.fromMM, "date": ISO8601DateFormatter().string(from: $0.date)] }
        }
        if let b = s.bedding, !b.isEmpty {
            d["bedding_planes"] = b.map { ["dip_to_core_cross_plane_deg": $0.dipDegrees, "highest_at_protractor_deg": $0.highAngleDegrees,
                                           "centre_height_mm": $0.centreHeightMM, "fit_rms_mm": $0.rmsMM, "points": $0.points,
                                           "angles_from": $0.reference, "date": ISO8601DateFormatter().string(from: $0.date)] }
            d["bedding_convention"] = "dip = angle between the plane and the plane square to the sample axis; protractor angles + counter-clockwise seen from above"
        }
        guard d.count > 5 else { return }
        try? FileManager.default.createDirectory(at: s.exportsURL, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]).write(to: url(s), options: .atomic)
    }
}

// MARK: Scan page

struct ExtraToolsSection: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    @AppStorage("tools.density") private var density = false
    @AppStorage("tools.coring") private var coring = false
    @AppStorage("tools.ctFrame") private var ctFrame = false
    @AppStorage("tools.bedding") private var bedding = false
    @AppStorage("tools.labelID") private var labelID = false
    @AppStorage("tools.changeMap") private var changeMap = false
    @AppStorage("tools.scaleRef") private var scaleRef = false

    var body: some View {
        if (density || coring || ctFrame || bedding || labelID || changeMap || scaleRef) && !scan.isPieces {
            Section {
                if labelID { LabelIDRow(scan: scan) }
                if density, scan.stats != nil { DensityRows(scan: scan) }
                if coring, scan.hasModel { CoringRows(scan: scan) }
                if ctFrame, scan.hasModel { CTFrameRow(scan: scan) }
                if changeMap, scan.hasModel { CompareRows(scan: scan) }
                if scaleRef, scan.stats != nil { ScaleRefRows(scan: scan) }
                if bedding, scan.hasModel {
                    NavigationLink { BeddingView(scan: scan) } label: {
                        Label("Bedding or fracture dip (\(scan.bedding?.count ?? 0) saved)", systemImage: "line.diagonal")
                    }
                }
            } header: {
                Text("Extra tools")
            } footer: {
                Text("Results are saved in the scan's lab-tools.json and go to Google Drive with it. Switch tools on or off in Settings › Extra tools.")
            }
        }
    }
}

struct DensityRows: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    @State private var mass: Double?
    @State private var grain: Double?
    @State private var loaded = false

    var body: some View {
        let volume = (scan.stats?.volumeCM3 ?? 0) * pow(scan.scaleFactor, 3)
        Group {
            LabeledContent("Mass (g)") {
                TextField("weigh it", value: $mass, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("Grain density (g/cm³)") {
                TextField("e.g. 2.65", value: $grain, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            if let m = mass, let b = Density.bulk(massG: m, volumeCM3: volume) {
                LabeledContent("Bulk density", value: String(format: "%.3f g/cm³", b))
                if let g = grain, let p = Density.porosity(bulk: b, grain: g) {
                    LabeledContent("Porosity", value: String(format: "%.1f %%", p * 100))
                } else if grain != nil {
                    Text("The grain density must be above the bulk density.").font(.caption).foregroundStyle(.orange)
                }
                Text(String(format: "Volume %.2f cm³%@", volume, (scan.stats?.isClosed ?? false) ? "" : " · surface not closed, so this is approximate"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            mass = scan.massG
            grain = scan.grainDensity
        }
        .onChange(of: mass) { _, v in model.updateScan(scan.id) { $0.massG = v } }
        .onChange(of: grain) { _, v in model.updateScan(scan.id) { $0.grainDensity = v } }
    }
}

struct CoringRows: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    @State private var diameter = 25.4
    @State private var vertical = true
    @State private var working = false

    var body: some View {
        Group {
            Picker("Plug", selection: $diameter) {
                Text("1 inch (25.4 mm)").tag(25.4)
                Text("1.5 inch (38.1 mm)").tag(38.1)
                Text("25 mm").tag(25.0)
                Text("30 mm").tag(30.0)
                Text("38 mm").tag(38.0)
            }
            Picker("Drilled", selection: $vertical) {
                Text("Up as scanned").tag(true)
                Text("Along the long axis").tag(false)
            }
            .pickerStyle(.segmented)
            Button {
                run()
            } label: {
                if working { ProgressView() } else { Label("Find the longest plug", systemImage: "cylinder.split.1x2") }
            }
            .disabled(working)
            if let r = scan.coring?.first(where: { $0.diameterMM == diameter && $0.vertical == vertical }) {
                Text(r.maxLengthMM > 0
                     ? String(format: "Longest plug: %.1f mm, its centre line %.1f mm from the rock's middle, starting %.1f mm from the end.", r.maxLengthMM, r.offsetMM, r.fromMM)
                     : "A plug this wide doesn't fit anywhere in this direction.")
                    .font(.callout)
            }
        }
    }

    private func run() {
        working = true
        let url = scan.modelURL, f = scan.scaleFactor, d = diameter, v = vertical, id = scan.id
        Task {
            let result = await Task.detached { () -> CoringResult? in
                guard let mesh = MeshTools.loadMesh(url) else { return nil }
                return VirtualCoring.longestPlug(positions: mesh.positions, indices: mesh.indices, diameter: d / 1000 / f,
                                                 vertical: v, step: 0.001 / f, gridStep: 0.002 / f)
            }.value
            working = false
            guard let r = result else {
                model.errorMessage = "Couldn't read the model to place the plug."
                return
            }
            let rec = CoringRecord(diameterMM: d, vertical: v, maxLengthMM: r.length * 1000 * f,
                                   offsetMM: hypot(r.center.x, r.center.y) * 1000 * f, fromMM: r.from * 1000 * f, date: Date())
            AppLog.info("tools", String(format: "Virtual coring %.1f mm %@: longest %.1f mm", d, v ? "vertical" : "along a", rec.maxLengthMM))
            model.updateScan(id) { s in
                var list = (s.coring ?? []).filter { !($0.diameterMM == d && $0.vertical == v) }
                list.insert(rec, at: 0)
                s.coring = list
            }
            Task { await model.syncAllPending() }
        }
    }
}

struct CTFrameRow: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    @AppStorage("tools.voxelUM") private var voxelUM = 0.0
    @State private var urls: [URL] = []
    @State private var working = false

    var body: some View {
        Group {
            LabeledContent("CT voxel size (µm, optional)") {
                TextField("e.g. 14", value: $voxelUM, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Button {
                working = true
                let s = scan, v = voxelUM
                Task {
                    let out = await Task.detached { CTFrameExport.write(s, voxelUM: v) }.value
                    working = false
                    if out.isEmpty {
                        model.errorMessage = "Couldn't write the micro-CT frame files."
                    } else {
                        urls = out
                        AppLog.info("tools", "Model written in the micro-CT frame")
                        Task { await model.syncAllPending() }
                    }
                }
            } label: {
                if working { ProgressView() } else { Label("Write the model in the micro-CT frame", systemImage: "cube.transparent") }
            }
            .disabled(working)
            if !urls.isEmpty {
                ShareLink(items: urls) { Label("Share the CT-frame OBJ and JSON", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

enum CTFrameExport {
    static func folder(_ scan: Scan) -> URL { scan.exportsURL.appendingPathComponent("ct-frame", isDirectory: true) }

    /// OBJ in millimetres (caliper scale applied) and a JSON with the matrix and conventions.
    static func write(_ scan: Scan, voxelUM: Double) -> [URL] {
        guard let mesh = MeshTools.loadMesh(scan.modelURL) else { return [] }
        let frame = CTFrame.make(mesh.positions)
        let scale = 1000 * scan.scaleFactor
        var obj = "# Crystal Bowl model in the micro-CT frame, millimetres\n"
        obj += "# z = up as scanned, origin on the axis of the footprint's smallest circle at the lowest point, x = model x\n"
        obj.reserveCapacity(mesh.positions.count * 36 + mesh.indices.count * 8)
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in mesh.positions {
            let q = frame.apply(p, scale: scale)
            lo = pointwiseMin(lo, q)
            hi = pointwiseMax(hi, q)
            obj += String(format: "v %.4f %.4f %.4f\n", q.x, q.y, q.z)
        }
        var i = 0
        while i + 2 < mesh.indices.count {
            obj += "f \(mesh.indices[i] + 1) \(mesh.indices[i + 1] + 1) \(mesh.indices[i + 2] + 1)\n"
            i += 3
        }
        let dir = folder(scan)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let objURL = dir.appendingPathComponent("\(scan.fileStem)_ct-frame.obj")
        let jsonURL = dir.appendingPathComponent("\(scan.fileStem)_ct-frame.json")
        var d: [String: Any] = [
            "schema": "crystal-bowl.ct-frame/1", "units": "mm", "scan_id": scan.id, "app_version": AppInfo.label,
            "matrix_model_m_to_ct_mm_row_major": frame.matrix(scale: scale),
            "caliper_scale_factor": scan.scaleFactor,
            "extent_min_mm": [lo.x, lo.y, lo.z], "extent_max_mm": [hi.x, hi.y, hi.z],
            "convention": "z up as the rock stood in the scan, origin on the axis of the smallest circle round the footprint at the lowest point, x along the model's x axis (not turned to the reference mark)",
            "note": "Surface model from photogrammetry. Use as a starting pose for registration with the CT, not as a final one.",
        ]
        if let m = scan.mark { d["reference_mark"] = m.json() }
        if voxelUM > 0 {
            d["voxel_size_um"] = voxelUM
            d["extent_voxels"] = [(hi.x - lo.x), (hi.y - lo.y), (hi.z - lo.z)].map { ($0 * 1000 / voxelUM).rounded() }
        }
        do {
            try obj.write(to: objURL, atomically: true, encoding: .utf8)
            try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]).write(to: jsonURL, options: .atomic)
            return [objURL, jsonURL]
        } catch {
            AppLog.error("tools", "Writing the CT-frame files failed", error, scan: scan)
            return []
        }
    }
}

// MARK: Bedding dip on the unrolled side

struct BeddingView: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    @State private var image: UIImage?
    @State private var info: (pxPerMM: Double, heightMM: Double, circumferenceMM: Double, reference: Double, isMark: Bool)?
    @State private var taps: [CGPoint] = [] // image pixels
    @State private var fit: BeddingFit?

    var body: some View {
        List {
            if let image, let info {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { g in
                                let k = g.size.width / image.size.width
                                Canvas { ctx, _ in
                                    if let fit { ctx.stroke(curve(fit, info, image.size, k), with: .color(.orange), lineWidth: 2) }
                                    for p in taps {
                                        let r = CGRect(x: p.x * k - 6, y: p.y * k - 6, width: 12, height: 12)
                                        ctx.fill(Path(ellipseIn: r), with: .color(.yellow))
                                        ctx.stroke(Path(ellipseIn: r), with: .color(.black), lineWidth: 1.5)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture(coordinateSpace: .local) { loc in
                                    taps.append(CGPoint(x: loc.x / k, y: loc.y / k))
                                    refit()
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets())
                    if let fit {
                        Text(String(format: "Dip %.1f° to the plane square across the sample, highest at %.0f° from the %@, fit ±%.1f mm (%d points)",
                                    fit.dipDegrees, fit.highAngleDegrees, info.isMark ? "mark" : "chosen 0°", fit.rmsMM, fit.points))
                            .font(.callout.monospacedDigit())
                    } else {
                        Text("Tap at least three points along one layer or fracture. Spread them round the sample.").font(.callout)
                    }
                    HStack {
                        Button("Undo") { if !taps.isEmpty { taps.removeLast(); refit() } }.disabled(taps.isEmpty)
                        Spacer()
                        Button("Clear") { taps = []; fit = nil }.disabled(taps.isEmpty)
                        Spacer()
                        Button("Save this plane") { save(info) }.disabled(fit == nil).buttonStyle(.borderedProminent)
                    }
                    .buttonStyle(.bordered)
                } footer: {
                    Text("The unrolled picture shows the side all the way round; the middle is the reference (the mark when one was found). A flat layer shows as a wave: the higher the wave, the steeper the layer.")
                }
            } else {
                Text("This scan has no unrolled side picture yet. It is made with the sample sheet (Measure in 3D › Sample sheet).")
                    .foregroundStyle(.secondary)
            }
            if let saved = model.scans.first(where: { $0.id == scan.id })?.bedding, !saved.isEmpty {
                Section("Saved planes") {
                    ForEach(saved) { b in
                        Text(String(format: "Dip %.1f°, highest at %.0f°, ±%.1f mm, %d points", b.dipDegrees, b.highAngleDegrees, b.rmsMM, b.points))
                            .font(.callout.monospacedDigit())
                    }
                    .onDelete { idx in model.updateScan(scan.id) { s in s.bedding?.remove(atOffsets: idx) } }
                }
            }
        }
        .navigationTitle("Bedding dip")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        let dir = scan.exportsURL.appendingPathComponent("sheet", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let png = files.first(where: { $0.lastPathComponent.contains("_unrolled_") && $0.pathExtension == "png" }),
              let img = UIImage(contentsOfFile: png.path),
              let jsonURL = files.first(where: { $0.lastPathComponent.hasSuffix("_sample-sheet.json") }),
              let data = try? Data(contentsOf: jsonURL),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let u = j["unrolled"] as? [String: Any],
              let px = u["px_per_mm"] as? Double, let h = u["height_mm"] as? Double, let c = u["circumference_mm"] as? Double
        else { return }
        image = img
        info = (px, h, c, j["reference_protractor_deg"] as? Double ?? 0, (j["reference"] as? String) == "mark")
    }

    /// Protractor angle of an image column: the middle is the reference, angles decrease to the right.
    private func angle(_ x: Double, width: Double, reference: Double) -> Double {
        reference + (width / 2 - x) / width * 360
    }

    private func refit() {
        guard let info, let image else { fit = nil; return }
        let w = Double(image.size.width)
        fit = BeddingFit.fit(angles: taps.map { angle(Double($0.x), width: w, reference: info.reference) },
                             heights: taps.map { info.heightMM - Double($0.y) / info.pxPerMM },
                             radiusMM: info.circumferenceMM / (2 * .pi))
    }

    private func curve(_ f: BeddingFit, _ info: (pxPerMM: Double, heightMM: Double, circumferenceMM: Double, reference: Double, isMark: Bool),
                       _ size: CGSize, _ k: CGFloat) -> Path {
        var path = Path()
        let w = Double(size.width)
        let amp = info.circumferenceMM / (2 * .pi) * tan(f.dipDegrees * .pi / 180)
        for x in stride(from: 0.0, through: w, by: 3) {
            let a = angle(x, width: w, reference: info.reference)
            let z = f.centreHeightMM + amp * cos((a - f.highAngleDegrees) * .pi / 180)
            let y = (info.heightMM - z) * info.pxPerMM
            let p = CGPoint(x: x * Double(k), y: y * Double(k))
            if x == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func save(_ info: (pxPerMM: Double, heightMM: Double, circumferenceMM: Double, reference: Double, isMark: Bool)) {
        guard let f = fit else { return }
        let rec = BeddingRecord(dipDegrees: f.dipDegrees, highAngleDegrees: f.highAngleDegrees, centreHeightMM: f.centreHeightMM,
                                rmsMM: f.rmsMM, points: f.points, reference: info.isMark ? "mark" : "chosen angle", date: Date())
        AppLog.info("tools", String(format: "Bedding plane saved: dip %.1f°, %d points, ±%.1f mm", f.dipDegrees, f.points, f.rmsMM))
        model.updateScan(scan.id) { s in s.bedding = (s.bedding ?? []) + [rec] }
        taps = []
        fit = nil
        Task { await model.syncAllPending() }
    }
}

// MARK: Sample ID from a label

struct LabelIDRow: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    @State private var scanning = false
    @State private var found: String?

    var body: some View {
        Group {
            if DataScannerViewController.isSupported {
                Button { scanning = true } label: { Label("Read the Sample ID from a label", systemImage: "qrcode.viewfinder") }
                    .disabled(!DataScannerViewController.isAvailable)
                if let found {
                    Text("Read: \(found)").font(.callout.monospacedDigit())
                    Button("Use \"\(found)\" as the Sample ID") {
                        model.rename(scan, to: found)
                        AppLog.info("tools", "Sample ID set from a label")
                        self.found = nil
                    }
                }
            } else {
                Text("This iPhone can't read labels with the camera.").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                LabelScanner { text in
                    found = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    scanning = false
                }
                .ignoresSafeArea()
                .navigationTitle("Point at the label")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
            }
        }
    }
}

/// A QR code or barcode is taken as soon as it is seen; text is taken when tapped.
struct LabelScanner: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(), .text()], qualityLevel: .balanced,
                                           recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        context.coordinator.onFound = onFound
        if !vc.isScanning { try? vc.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onFound: (String) -> Void
        private var done = false
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let b) = item, let s = b.payloadStringValue, !s.isEmpty { deliver(s, dataScanner) }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            switch item {
            case .barcode(let b): if let s = b.payloadStringValue { deliver(s, dataScanner) }
            case .text(let t): deliver(t.transcript, dataScanner)
            @unknown default: break
            }
        }

        private func deliver(_ s: String, _ scanner: DataScannerViewController) {
            guard !done else { return }
            done = true
            scanner.stopScanning()
            onFound(String(s.prefix(60)))
        }
    }
}
