import SwiftUI
import SceneKit
import simd
import ScanMath

/// A stand under the rock (3.14). A small rock is lifted on a block (wood, cork, putty) so the phone's LiDAR finds
/// it; the block becomes part of the 3D model. The app looks at the unrolled side of the model, where the stand
/// shows as a band of another colour at the bottom, cuts the model there (MeshCut, closed again) and measures,
/// slices and draws only the rock. The user checks the cut on the same strip and moves it, or says there is no
/// stand. The strip, the cut and a rock-only model go to Google Drive with the scan (model/stand/).
enum StandStrip {
    struct Strip {
        let image: UIImage
        /// Model heights (metres, +Y up) of the strip's top and bottom edges.
        let topY: Double
        let bottomY: Double
        let scaleFactor: Double
        var heightMM: Double { (topY - bottomY) * 1000 * scaleFactor }
        /// Model height of a point `share` of the way down the strip.
        func y(atShare share: Double) -> Double { topY - share * (topY - bottomY) }
        func share(atY y: Double) -> Double { (topY - y) / Swift.max(1e-9, topY - bottomY) }
    }

    struct Found {
        let cutY: Double
        let heightMM: Double
        let result: StandFinder.Result
        /// The outline changes where the colour does (3.16): without that, a colour change alone is not cut.
        var outlineChanges: Bool = true
        var outlineText: String = ""
    }

    static func folder(_ scan: Scan) -> URL { scan.exportsURL.appendingPathComponent("stand", isDirectory: true) }
    static func imageURL(_ scan: Scan) -> URL { folder(scan).appendingPathComponent("\(scan.fileStem)_stand-strip.png") }
    static func infoURL(_ scan: Scan) -> URL { folder(scan).appendingPathComponent("\(scan.fileStem)_stand.json") }

    /// The strip saved when the scan was first examined (the whole model, stand included).
    static func load(_ scan: Scan) -> Strip? {
        guard let img = UIImage(contentsOfFile: imageURL(scan).path),
              let data = try? Data(contentsOf: infoURL(scan)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let top = json["strip_top_y_m"] as? Double, let bottom = json["strip_bottom_y_m"] as? Double else { return nil }
        return Strip(image: img, topY: top, bottomY: bottom, scaleFactor: json["scale_factor"] as? Double ?? scan.scaleFactor)
    }

    /// Unrolls the whole model (stand included), saves the strip and looks for a stand on it.
    @MainActor
    static func examine(_ original: Scan) async -> Found? {
        var whole = original
        whole.standCutY = nil
        guard let loaded = await SampleRig.load(whole) else { return nil }
        let rig = SampleRig(scene: loaded.0, data: loaded.1, name: whole.name)
        guard let u = Unroller.unroll(rig: rig) else { return nil }
        let strip = Strip(image: u.image, topY: rig.data.maxY, bottomY: rig.data.minY, scaleFactor: whole.scaleFactor)
        let found = StandFinder.find(rows: u.rowColours)
        var cutY: Double?
        if let f = found, !u.rowColours.isEmpty {
            cutY = strip.y(atShare: Double(f.boundaryRow) / Double(u.rowColours.count))
        }
        guard let f = found, let y = cutY else {
            save(strip, scan: whole, cutY: nil, how: "not_found")
            return nil
        }
        // 3.16: the colour alone cut four straight cores (their black end marks read as a stand). A stand is
        // also a change of outline: the rock's footprint above the line differs from the block's below it.
        var changes = false
        var text = "outline not measured"
        let band: Double = Swift.max(0.002, 0.06 * (strip.topY - strip.bottomY))
        let checked = whole
        let step = await Task.detached { () -> (areaChange: Double, shift: Double)? in
            guard let mesh = MeshTools.loadMesh(checked) else { return nil }
            return StandFinder.outlineStep(positions: mesh.positions, y: y, band: band)
        }.value
        if let st = step {
            changes = st.areaChange >= 0.12 || st.shift >= 0.08
            text = String(format: "outline area changes %.0f%%, shifts %.2f of its size", st.areaChange * 100, st.shift)
        }
        save(strip, scan: whole, cutY: changes ? y : nil, how: changes ? "auto" : "not_found")
        return Found(cutY: y, heightMM: (y - strip.bottomY) * 1000 * whole.scaleFactor, result: f, outlineChanges: changes, outlineText: text)
    }

    static func save(_ strip: Strip, scan: Scan, cutY: Double?, how: String) {
        try? FileManager.default.createDirectory(at: folder(scan), withIntermediateDirectories: true)
        try? strip.image.pngData()?.write(to: imageURL(scan), options: .atomic)
        writeInfo(strip, scan: scan, cutY: cutY, how: how)
    }

    static func writeInfo(_ strip: Strip, scan: Scan, cutY: Double?, how: String) {
        var json: [String: Any] = [
            "schema": "crystal-bowl.stand/1",
            "strip_top_y_m": strip.topY, "strip_bottom_y_m": strip.bottomY, "scale_factor": strip.scaleFactor,
            "how": how,
            "note": "The strip is the model's side unrolled, stand included (top row = top of the model). The model is cut at cut_y_m (model frame, metres, +Y up) and closed there; everything measured, sliced and drawn is the part above. how: auto = found by its colour, user = set by hand, none = no stand, not_found = none found.",
        ]
        if let y = cutY {
            json["cut_y_m"] = y
            json["cut_above_bottom_mm"] = (y - strip.bottomY) * 1000 * strip.scaleFactor
            json["rock_height_mm"] = (strip.topY - y) * 1000 * strip.scaleFactor
        }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: infoURL(scan), options: .atomic)
        }
    }

    /// The rock alone as STL and OBJ (metres), next to the full model's files.
    static func exportRockOnly(_ scan: Scan) -> [URL] {
        guard scan.standCutY != nil, let mesh = MeshTools.loadMesh(scan) else { return [] }
        try? FileManager.default.createDirectory(at: folder(scan), withIntermediateDirectories: true)
        let stl = folder(scan).appendingPathComponent("\(scan.fileStem)_rock-only.stl")
        let obj = folder(scan).appendingPathComponent("\(scan.fileStem)_rock-only.obj")
        var out: [URL] = []
        // Binary STL.
        var data = Data(count: 80)
        let n = mesh.indices.count / 3
        var count = UInt32(n)
        data.append(Data(bytes: &count, count: 4))
        for t in 0..<n {
            let i0: Int = Int(mesh.indices[t * 3]), i1: Int = Int(mesh.indices[t * 3 + 1]), i2: Int = Int(mesh.indices[t * 3 + 2])
            let a = mesh.positions[i0], b = mesh.positions[i1], c = mesh.positions[i2]
            let cr = simd_cross(b - a, c - a)
            let l = simd_length(cr)
            let nrm: SIMD3<Float> = l > 0 ? cr / l : .zero
            for v in [nrm, a, b, c] {
                var x = v.x, y = v.y, z = v.z
                data.append(Data(bytes: &x, count: 4))
                data.append(Data(bytes: &y, count: 4))
                data.append(Data(bytes: &z, count: 4))
            }
            data.append(contentsOf: [0, 0])
        }
        if (try? data.write(to: stl, options: .atomic)) != nil { out.append(stl) }
        var text = "# \(scan.name): the rock without its stand (cut and closed), metres\n"
        for p in mesh.positions { text += String(format: "v %.6f %.6f %.6f\n", p.x, p.y, p.z) }
        for t in 0..<n {
            let i0: UInt32 = mesh.indices[t * 3] + 1, i1: UInt32 = mesh.indices[t * 3 + 1] + 1, i2: UInt32 = mesh.indices[t * 3 + 2] + 1
            text += "f \(i0) \(i1) \(i2)\n"
        }
        if (try? text.write(to: obj, atomically: true, encoding: .utf8)) != nil { out.append(obj) }
        return out
    }
}

extension AppModel {
    /// The user set the cut (a model height), or said there is no stand (nil). The rock is measured and sliced
    /// again and the sheets are made again.
    func setStand(_ scan: Scan, cutY: Double?) {
        guard var s = scans.first(where: { $0.id == scan.id }) else { return }
        s.standCutY = cutY
        s.standCheck = cutY == nil ? "none" : "user"
        s.extrasVersion = Swift.min(s.extrasVersion ?? 0, 2)
        try? ScanStore.save(s)
        if let strip = StandStrip.load(s) { StandStrip.writeInfo(strip, scan: s, cutY: cutY, how: s.standCheck ?? "user") }
        reload()
        if let y = cutY, let strip = StandStrip.load(s) {
            AppLog.info("stand", String(format: "Stand cut set by hand at %.1f mm above the bottom", (y - strip.bottomY) * 1000 * strip.scaleFactor), scan: s)
        } else {
            AppLog.info("stand", cutY == nil ? "No stand: the whole model is measured" : "Stand cut set by hand", scan: s)
        }
        let target = s
        Task {
            await repair(target)
            await upgradeScans()
        }
    }
}

/// Scan page: the stand under the rock, found or not, and a way to check or move the cut.
struct StandSection: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    @State private var editing = false

    var body: some View {
        Section {
            switch scan.standCheck {
            case "auto":
                Label("A stand under the rock was found by its colour and cut off: only the rock is measured, sliced and drawn. Check the cut.",
                      systemImage: "scissors").font(.callout)
            case "user":
                Label("The stand is cut off where you set it.", systemImage: "scissors").font(.callout)
            case "ai":
                Label("A stand under the rock was found by the AI second opinion and cut off. Check the cut.", systemImage: "sparkles").font(.callout)
            case "none":
                Label("No stand: the whole model is measured.", systemImage: "cube").font(.callout)
            case "not_found":
                Label("No stand found under the rock.", systemImage: "cube").font(.callout)
            default:
                Label("Not looked at yet (it happens when the sample sheets are made).", systemImage: "clock").font(.callout)
            }
            if let note = scan.standNote {
                Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if let note = scan.standAI {
                Label(note, systemImage: "sparkles").font(.footnote).foregroundStyle(.secondary)
            }
            Button { editing = true } label: {
                Label(scan.standCutY == nil ? "Cut off a stand under the rock" : "Check or move the cut", systemImage: "slider.vertical.3")
            }
            .disabled(!scan.hasModel || model.buildingID == scan.id)
        } header: {
            Text("Stand under the rock")
        } footer: {
            Text("A small rock can stand on a block (wood, cork, putty) so the phone finds it. The block is cut off the model at the line you check here; the rock alone is measured. The full model is kept.")
        }
        .sheet(isPresented: $editing) { StandEditor(scan: scan).environmentObject(model) }
    }
}

/// The unrolled side with a line where the model is cut: drag it to the top of the stand.
struct StandEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let scan: Scan
    @State private var strip: StandStrip.Strip?
    @State private var share: Double = 0.85
    @State private var loading = true
    @State private var aiAnswer: AIAssist.StandAnswer?
    @State private var aiError: String?
    @State private var asking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let s = strip {
                        Text("The rock's side, unrolled all the way round, with the stand at the bottom. Drag the red line to where the rock ends and the stand begins.")
                            .font(.callout)
                        Image(uiImage: s.image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay {
                                GeometryReader { g in
                                    let y = g.size.height * share
                                    ZStack(alignment: .topLeading) {
                                        Rectangle().fill(Color.black.opacity(0.45))
                                            .frame(width: g.size.width, height: Swift.max(0, g.size.height - y))
                                            .offset(y: y)
                                        Rectangle().fill(Color.red).frame(width: g.size.width, height: 3).offset(y: y - 1.5)
                                        if let a = aiAnswer, a.hasStand {
                                            Rectangle().fill(Color.blue).frame(width: g.size.width, height: 2)
                                                .offset(y: g.size.height * a.boundaryFromTop - 1)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                                        share = Swift.min(Swift.max(v.location.y / Swift.max(1, g.size.height), 0.02), 0.98)
                                    })
                                }
                            }
                            .border(Color.secondary.opacity(0.4))
                        Text(heightsText(s))
                            .font(.callout.monospacedDigit())
                        Slider(value: $share, in: 0.02...0.98)
                        if AIAssist.isReady {
                            Button { Task { await askAI(s) } } label: {
                                Label(asking ? "Asking…" : "Ask the AI where the stand begins", systemImage: "sparkles")
                            }
                            .disabled(asking)
                            if let a = aiAnswer {
                                Text(aiText(a)).font(.footnote).foregroundStyle(.blue)
                                if a.hasStand {
                                    Button("Move the red line to the AI's (blue) line") { share = Swift.min(Swift.max(a.boundaryFromTop, 0.02), 0.98) }
                                }
                            }
                            if let e = aiError { Text(e).font(.footnote).foregroundStyle(.orange) }
                        }
                        Button {
                            model.setStand(scan, cutY: s.y(atShare: share))
                            dismiss()
                        } label: {
                            Label("Cut here and measure the rock again", systemImage: "scissors").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            model.setStand(scan, cutY: nil)
                            dismiss()
                        } label: {
                            Label("No stand: keep the whole model", systemImage: "cube").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else if loading {
                        ProgressView("Unrolling the side of the model…")
                    } else {
                        Text("The model couldn't be unrolled, so the cut can't be shown.").foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Stand under the rock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await prepare() }
        }
    }

    private func heightsText(_ s: StandStrip.Strip) -> String {
        let below: Double = (1 - share) * s.heightMM
        let rock: Double = share * s.heightMM
        let a: String = "Cut " + L(below) + " above the bottom"
        let b: String = " · rock " + L(rock) + " tall · model " + L(s.heightMM)
        return a + b
    }

    private func aiText(_ a: AIAssist.StandAnswer) -> String {
        let sure: String = String(format: "%.0f%% sure", a.confidence * 100)
        let what: String = a.hasStand ? "The AI sees a stand below the blue line (" + sure + "). " : "The AI sees no stand (" + sure + "). "
        return what + a.reason
    }

    private func askAI(_ s: StandStrip.Strip) async {
        asking = true
        aiError = nil
        do {
            aiAnswer = try await AIAssist.askStand(strip: s.image, heightMM: s.heightMM)
        } catch {
            aiError = error.localizedDescription
            AppLog.warn("ai", "Stand check failed: " + error.localizedDescription, scan: scan)
        }
        asking = false
    }

    private func prepare() async {
        if StandStrip.load(scan) == nil { _ = await StandStrip.examine(scan) }
        strip = StandStrip.load(scan)
        if let s = strip, let y = scan.standCutY { share = Swift.min(Swift.max(s.share(atY: y), 0.02), 0.98) }
        loading = false
    }
}
