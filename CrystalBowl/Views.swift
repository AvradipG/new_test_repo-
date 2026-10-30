import SwiftUI
import RealityKit
import SceneKit
import ScanMath

@main
struct CrystalBowlApp: App {
    @StateObject private var model = AppModel()
    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}

enum Theme {
    static let violet = Color(red: 0.42, green: 0.28, blue: 0.95)
    static let blue = Color(red: 0.12, green: 0.52, blue: 0.95)
    static let teal = Color(red: 0.05, green: 0.74, blue: 0.68)
    static let gradient = LinearGradient(colors: [violet, blue, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            switch model.phase {
            case .home:
                HomeView()
            case .capturing:
                if let session = model.captureSession {
                    CaptureView(guide: model.guide, session: session)
                } else {
                    ProgressView("Starting camera…")
                }
            case .reconstructing:
                ReconstructionView()
            }
        }
        .tint(Theme.violet)
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await model.checkForUpdate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await model.checkForUpdate()
                    await model.syncAllPending()
                }
            }
        }
    }
}

// MARK: Home

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var sampleName = ""
    @AppStorage(AppModel.keepPhotosKey) private var keepPhotos = false
    @AppStorage(CaptureGuide.hapticsKey) private var haptics = true

    var body: some View {
        NavigationStack(path: $model.path) {
            List {
                Section {
                    HeroCard(scanCount: model.scans.count, onDrive: model.scans.filter { $0.drive?.complete == true }.count)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if let update = model.updateAvailable {
                    Section { UpdateBanner(remote: update) }
                }
                Section {
                    TextField("Sample ID, e.g. CNPC-2H plug 3", text: $sampleName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(start)
                    Button(action: start) {
                        Label("Start new scan", systemImage: "viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.isCaptureSupported)
                    if !model.isCaptureSupported {
                        Text("3D capture needs a LiDAR iPhone (12 Pro or later Pro model) on iOS 17 or later.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("New scan")
                } footer: {
                    Text("Put the rock on a textured, matte surface (a newspaper page works) in soft, even light, with room to walk all the way round.")
                }

                Section("Scans") {
                    if model.scans.isEmpty {
                        Text("No scans yet. Your scans appear here, in the Files app under On My iPhone › Crystal Bowl, and on Google Drive once you sign in.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.scans) { scan in
                        NavigationLink(value: scan) { ScanRow(scan: scan) }
                    }
                    .onDelete { offsets in
                        for i in offsets { model.delete(model.scans[i]) }
                    }
                }

                Section("How to get an accurate scan") {
                    TipRow(icon: "square.grid.3x3.fill", color: Theme.teal,
                           text: "Textured, matte surface and soft light. Shiny or plain white tables confuse the tracking.")
                    TipRow(icon: "hand.tap.fill", color: Theme.violet,
                           text: "Tap Start, point at the rock, tap Continue and fit the box snugly round the rock.")
                    TipRow(icon: "figure.walk.circle.fill", color: Theme.blue,
                           text: "Walk slowly round the rock about 30 cm away, looking down about 35°. The phone ticks with each photo and buzzes if you go too fast, turn back or drift off height.")
                    TipRow(icon: "circle.dashed", color: .orange,
                           text: "After the pass, check the ring. Orange sectors are gaps: tap Fill the gaps and the phone bumps when you reach one.")
                    TipRow(icon: "arrow.triangle.2.circlepath", color: .pink,
                           text: "Flip the rock and scan the underside the same way, then Finish.")
                    TipRow(icon: "ruler.fill", color: .green,
                           text: "On the scan page, enter one length measured with calipers to check and correct the scale.")
                }

                DriveSettingsSection()

                Section {
                    Toggle("Vibration guidance while scanning", isOn: $haptics)
                    Toggle("Keep photos after the model is built", isOn: $keepPhotos)
                } header: {
                    Text("Settings")
                } footer: {
                    Text("A scan needs a few hundred MB of photos while it is being built. Photos are kept until they are on Google Drive (when photo upload is on), then deleted unless you keep them. They let a Mac rebuild the model at full detail.")
                }
            }
            .navigationTitle("Crystal Bowl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About and updates", systemImage: model.updateAvailable == nil ? "info.circle" : "arrow.down.circle.fill")
                    }
                }
            }
            .navigationDestination(for: Scan.self) { scan in
                ScanDetailView(scanID: scan.id)
            }
            .refreshable { model.reload() }
        }
    }

    private func start() {
        guard model.isCaptureSupported else { return }
        model.startNewScan(name: sampleName)
        sampleName = ""
    }
}

struct HeroCard: View {
    let scanCount: Int
    let onDrive: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 34, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Crystal Bowl").font(.title.bold())
                    Text("3D rock scanner · sizes to the millimetre").font(.subheadline).opacity(0.9)
                }
            }
            HStack(spacing: 8) {
                Chip(text: "\(scanCount) scan\(scanCount == 1 ? "" : "s")", icon: "square.stack.3d.up.fill")
                Chip(text: "\(onDrive) on Drive", icon: "icloud.fill")
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct Chip: View {
    let text: String
    let icon: String
    var tint: Color = .white
    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.bold().monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.22), in: Capsule())
    }
}

struct TipRow: View {
    let icon: String
    let color: Color
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.bold())
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8))
            Text(text).font(.callout)
        }
        .padding(.vertical, 2)
    }
}

struct ScanRow: View {
    let scan: Scan
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: scan.hasModel ? "cube.fill" : "camera.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(scan.hasModel ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.orange.gradient), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(scan.name).font(.headline)
                HStack(spacing: 6) {
                    Text(scan.created, style: .date)
                    if let s = scan.stats {
                        let f = scan.scaleFactor
                        Text(String(format: "%.1f × %.1f × %.1f mm", s.axisA * f, s.axisB * f, s.axisC * f)).monospacedDigit()
                    } else if !scan.hasModel {
                        Text("No model yet").foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if scan.drive?.complete == true {
                        Chip(text: "On Drive", icon: "checkmark.icloud.fill", tint: .green).foregroundStyle(.green)
                    }
                    if scan.caliper != nil {
                        Chip(text: "Caliper checked", icon: "ruler.fill", tint: Theme.blue).foregroundStyle(Theme.blue)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: Capture

struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var guide: CaptureGuide
    let session: ObjectCaptureSession

    var body: some View {
        ZStack {
            if model.passCompleted {
                ObjectCapturePointCloudView(session: session)
                    .ignoresSafeArea()
            } else {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
            }
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    Button("Cancel", role: .destructive) { model.cancelCapture() }
                        .buttonStyle(.bordered)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Text("Pass \(model.passNumber) · \(model.shotCount) photos")
                            .font(.callout.monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                        if model.captureStage == .capturing && !model.passCompleted && guide.tracking {
                            CoverageRing(coverage: guide.coverage, angle: guide.angle,
                                         current: CaptureGuide.Band.of(guide.lookDown), target: guide.targetBand)
                                .frame(width: 112, height: 112)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                }
                if !model.passCompleted, let text = model.feedbackText ?? guide.hint {
                    Text(text)
                        .font(.callout.bold())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer()
                controls
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding()
        }
    }

    @ViewBuilder private var controls: some View {
        switch model.captureStage {
        case .initializing:
            ProgressView("Starting camera…")
        case .ready:
            VStack(spacing: 10) {
                Text("Point the camera at the rock.").multilineTextAlignment(.center)
                Button("Continue") { model.startDetecting() }
                    .buttonStyle(.borderedProminent)
            }
        case .detecting:
            VStack(spacing: 10) {
                Text("Drag the box edges so it just fits the rock.").multilineTextAlignment(.center)
                HStack {
                    Button("Reset box") { model.resetDetection() }.buttonStyle(.bordered)
                    Button("Start capture") { model.startCapturing() }.buttonStyle(.borderedProminent)
                }
            }
        case .capturing:
            if model.passCompleted {
                passSummary
            } else {
                VStack(spacing: 10) {
                    Text(guide.fillingGaps
                         ? "Go to the orange sectors on the ring. The phone bumps when you reach a gap."
                         : "Walk slowly round the rock, about 30 cm away. Feel a tick for each photo; a buzz means slow down or change height.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    Button("Finish now") { model.finishCapture() }.buttonStyle(.bordered)
                }
            }
        case .finishing:
            ProgressView("Saving photos…")
        case .completed, .failed:
            EmptyView()
        }
    }

    private var passSummary: some View {
        let advice = guide.advice()
        let cov = guide.bandCoverage
        let needsMore = !guide.gaps().isEmpty || cov[1] == 0 || cov[2] == 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("Pass \(model.passNumber) complete").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                CoverageRing(coverage: guide.coverage, angle: guide.angle, current: nil, target: guide.fillingGaps ? guide.targetBand : nil)
                    .frame(width: 96, height: 96)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "Covered: low %.0f%% · middle %.0f%% · high %.0f%%", cov[0] * 100, cov[1] * 100, cov[2] * 100))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        ForEach(advice, id: \.self) { Text($0).font(.footnote) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
            if needsMore {
                Button { model.anotherPass() } label: {
                    Label("Fill the gaps on this side", systemImage: "circle.dashed").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { model.flipAndContinue() } label: {
                    Label("Flip the rock and scan the underside", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button { model.flipAndContinue() } label: {
                    Label("Flip the rock and scan the underside", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { model.anotherPass() } label: {
                    Label("Another pass on this side", systemImage: "circle.dashed").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button { model.finishCapture() } label: {
                Label("Finish and build the model", systemImage: "cube.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Map of where photos were taken, seen from above: outer ring = low camera, inner ring = high camera.
/// 12 o'clock is where the pass started; sectors run clockwise the way the user walked.
struct CoverageRing: View {
    let coverage: [[Int]]
    let angle: Double
    let current: CaptureGuide.Band?
    let target: CaptureGuide.Band?

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let rMax = min(size.width, size.height) / 2
            let w = rMax / 3.6
            let n = coverage.first?.count ?? CaptureGuide.sectorCount
            func radius(_ band: Int) -> CGFloat { rMax - w * (CGFloat(band) + 0.5) }
            for b in 0..<coverage.count {
                for s in 0..<n {
                    var arc = Path()
                    let a0 = Angle.degrees(Double(s) * 360 / Double(n) - 90 + 1.5)
                    let a1 = Angle.degrees(Double(s + 1) * 360 / Double(n) - 90 - 1.5)
                    arc.addArc(center: c, radius: radius(b), startAngle: a0, endAngle: a1, clockwise: false)
                    let color: Color = coverage[b][s] > 0 ? .green : (b == target?.rawValue ? .orange : Color.gray.opacity(0.35))
                    ctx.stroke(arc, with: .color(color), lineWidth: w * 0.78)
                }
            }
            var start = Path()
            start.move(to: CGPoint(x: c.x, y: c.y - rMax - 2))
            start.addLine(to: CGPoint(x: c.x, y: c.y - rMax + w))
            ctx.stroke(start, with: .color(.primary), lineWidth: 2)
            if let current {
                let r = radius(current.rawValue)
                let t = CGFloat((angle - 90) * .pi / 180)
                let d = w * 0.95
                let dot = CGRect(x: c.x + r * cos(t) - d / 2, y: c.y + r * sin(t) - d / 2, width: d, height: d)
                ctx.fill(Path(ellipseIn: dot), with: .color(.white))
                ctx.stroke(Path(ellipseIn: dot), with: .color(.black), lineWidth: 1.5)
            }
        }
        .accessibilityLabel("Photo coverage map")
    }
}

// MARK: Reconstruction

struct ReconstructionView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cube.transparent.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 104, height: 104)
                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 26))
            Text("Building 3D model").font(.title2.bold())
            ProgressView(value: model.progress).frame(maxWidth: 280)
            Text(model.progressNote).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text("Keep the app open and the phone unlocked. This usually takes a few minutes. The model, lab files and cross-sections are then saved and uploaded to Google Drive by themselves.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
        }
    }
}

// MARK: Scan detail

struct ScanDetailView: View {
    @EnvironmentObject var model: AppModel
    let scanID: String
    @State private var exports: [URL] = []
    @State private var exporting = false
    @State private var measuring = false
    @State private var copied = false

    private var scan: Scan? { model.scans.first { $0.id == scanID } }

    var body: some View {
        if let scan {
            List {
                Section {
                    if scan.hasModel {
                        ModelPreview(url: scan.modelURL)
                            .frame(height: 320)
                            .listRowInsets(EdgeInsets())
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("No model yet. \(scan.photoCount ?? ScanStore.countPhotos(in: scan.imagesURL)) photos are saved.")
                            Button("Build model") { model.reconstruct(scan) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!scan.hasPhotos)
                        }
                    }
                }
                if scan.hasModel {
                    shareSection(scan)
                    driveSection(scan)
                }
                if let s = scan.stats {
                    measurementsSection(scan, s)
                    CaliperSection(scan: scan, stats: s)
                } else if scan.hasModel {
                    Section("Measurements") {
                        Button {
                            measuring = true
                            Task {
                                await model.measure(scan)
                                measuring = false
                            }
                        } label: {
                            if measuring { ProgressView() } else { Label("Measure", systemImage: "ruler") }
                        }
                        .disabled(measuring)
                    }
                }
                if scan.hasModel {
                    SectionsPanel(scan: scan)
                }
                Section {
                    LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: ScanStore.size(of: scan), countStyle: .file))
                    if scan.hasPhotos {
                        Button("Delete photos, keep model") { ScanStore.deletePhotos(scan); model.reload() }
                    }
                    Button("Delete scan", role: .destructive) { model.delete(scan) }
                }
            }
            .navigationTitle(scan.name)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: scan.hasModel) { await loadExports(scan) }
        } else {
            Text("This scan was deleted.").foregroundStyle(.secondary)
        }
    }

    private func loadExports(_ scan: Scan) async {
        guard scan.hasModel else { return }
        var files = MeshTools.existingExports(scan)
        if files.count <= 1 {
            exporting = true
            let s = scan
            files = await Task.detached { MeshTools.exportAll(s) }.value
            exporting = false
        }
        exports = files
    }

    private func shareSection(_ scan: Scan) -> some View {
        Section {
            if exporting || exports.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing STL, PLY, OBJ and report…").foregroundStyle(.secondary)
                }
            } else {
                ShareLink(items: exports) {
                    Label("Share all model files (\(exports.count))", systemImage: "square.and.arrow.up.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                DisclosureGroup("Share one file") {
                    ForEach(exports, id: \.self) { url in
                        ShareLink(item: url) {
                            Label(url.lastPathComponent, systemImage: Self.icon(for: url))
                        }
                    }
                }
            }
        } header: {
            Text("Share")
        } footer: {
            Text("STL for 3D printing and CAD, PLY and OBJ for analysis software, USDZ with colour for viewing, and a text report. Mesh files are in metres. Choose Save to Files, AirDrop, Mail or any app in the share sheet.")
        }
    }

    static func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "usdz": return "cube.fill"
        case "stl": return "printer.fill"
        case "txt": return "doc.text.fill"
        default: return "doc.fill"
        }
    }

    private func driveSection(_ scan: Scan) -> some View {
        let folder = "\(ScanPackage.rootFolder)/\(scan.id)_\(scan.fileStem)"
        return Section {
            if !model.driveSignedIn {
                Label("Sign in to Google Drive on the home screen and every scan uploads by itself.", systemImage: "person.badge.key")
                    .foregroundStyle(.secondary)
            } else {
                if let status = model.driveStatus[scan.id] {
                    Label(status, systemImage: "arrow.triangle.2.circlepath.icloud")
                } else if let d = scan.drive, d.complete, let when = d.lastSync {
                    Label("Uploaded \(when.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Waiting to upload", systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("My Drive › \(ScanPackage.rootFolder) › \(scan.id)_\(scan.fileStem)")
                        .font(.callout.monospaced())
                    Text("On a computer with Google Drive for desktop: My Drive\\\(ScanPackage.rootFolder)\\\(scan.id)_\(scan.fileStem)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let id = scan.drive?.folderID, let link = ScanPackage.folderLink(id) {
                    Link(destination: link) { Label("Open in Google Drive", systemImage: "arrow.up.forward.app") }
                }
                Button {
                    UIPasteboard.general.string = "My Drive/\(folder)"
                    copied = true
                } label: {
                    Label(copied ? "Path copied" : "Copy Drive path", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button("Upload now") { Task { await model.sync(scan) } }
                    .disabled(model.isSyncing)
            }
        } header: {
            Text("Google Drive")
        } footer: {
            Text("The folder holds manifest.json (measurements, scale check and every file with its SHA-256), model/ with USDZ, STL, PLY, OBJ and the report, sections/ and, when photo upload is on, images/. manifest.json is written last, so software can wait for it.")
        }
    }

    private func measurementsSection(_ scan: Scan, _ s: MeshStats) -> some View {
        let f = scan.scaleFactor
        return Section {
            LabeledContent("Axes a × b × c", value: String(format: "%.1f × %.1f × %.1f mm", s.axisA * f, s.axisB * f, s.axisC * f))
            LabeledContent("Volume", value: String(format: "%.2f cm³", s.volumeCM3 * f * f * f))
            if !s.isClosed {
                Text("The mesh has small gaps, so the volume is approximate.").font(.footnote).foregroundStyle(.secondary)
            }
            if let e = s.medianEdgeMM {
                LabeledContent("Mesh detail", value: String(format: "%.2f mm edges", e))
            }
            LabeledContent("Triangles", value: s.triangleCount.formatted())
            LabeledContent("Photos", value: "\(scan.photoCount ?? 0) in \(scan.passes ?? 1) pass(es)")
            if let cov = scan.coverage, cov.count == 3 {
                LabeledContent("Coverage low / mid / high", value: String(format: "%.0f / %.0f / %.0f %%", cov[0] * 100, cov[1] * 100, cov[2] * 100))
            }
        } header: {
            Text(scan.caliper == nil ? "Measurements (LiDAR scale)" : "Measurements (caliper-corrected)")
        } footer: {
            Text("a is the longest axis of the rock, c the shortest. Mesh detail is typical triangle spacing, not measured resolution or dimensional accuracy.")
        }
    }
}

struct CaliperSection: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    let stats: MeshStats
    @State private var axis = 0
    @State private var text = ""

    private var value: Double? {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        return v
    }

    var body: some View {
        Section {
            if let c = scan.caliper {
                let f = scan.scaleFactor
                let axisName = ["a", "b", "c"][max(0, min(2, c.axis))]
                LabeledContent("Calipers, axis \(axisName)", value: String(format: "%.2f mm", c.measuredMM))
                LabeledContent("Scan, axis \(axisName)", value: String(format: "%.2f mm", c.measuredMM / f))
                LabeledContent("Scan scale error", value: String(format: "%+.2f %%", (1 / f - 1) * 100))
                Button("Remove caliper check", role: .destructive) { model.setCaliper(scan, axis: 0, measuredMM: nil) }
            } else {
                Picker("Axis", selection: $axis) {
                    Text(String(format: "a %.1f", stats.axisA)).tag(0)
                    Text(String(format: "b %.1f", stats.axisB)).tag(1)
                    Text(String(format: "c %.1f", stats.axisC)).tag(2)
                }
                .pickerStyle(.segmented)
                TextField("Length measured with calipers, mm", text: $text)
                    .keyboardType(.decimalPad)
                Button("Save caliper check") {
                    if let v = value {
                        model.setCaliper(scan, axis: axis, measuredMM: v)
                        text = ""
                    }
                }
                .disabled(value == nil)
            }
        } header: {
            Text("Scale check")
        } footer: {
            Text("The scale comes from the iPhone's LiDAR and isn't checked by anything else. Measure the same length on the rock with calipers (a is the longest dimension) and enter it: measurements are corrected and the check goes into the report and manifest.json.")
        }
    }
}

struct ModelPreview: View {
    let url: URL
    @State private var scene: SCNScene?

    var body: some View {
        Group {
            if let scene {
                SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            scene = try? SCNScene(url: url, options: nil)
        }
    }
}

// MARK: Cross-sections

struct SectionsPanel: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    @State private var seriesID: String?
    @State private var index = 0.0
    @State private var axis = 0
    @State private var spacing = AppModel.defaultSpacingMM
    @State private var working = false
    @State private var zipURL: URL?

    private var series: SectionSeries? {
        let all = scan.sections ?? []
        return all.first { $0.id == seriesID } ?? all.first
    }

    var body: some View {
        Section {
            if let s = series, !s.rows.isEmpty {
                let i = min(Int(index.rounded()), s.rows.count - 1)
                let row = s.rows[i]
                if let img = UIImage(contentsOfFile: s.imageURL(in: scan, index: i).path) {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                        .listRowInsets(EdgeInsets())
                        .background(Color.black)
                }
                if s.rows.count > 1 {
                    Slider(value: $index, in: 0...Double(s.rows.count - 1), step: 1)
                }
                Text(String(format: "%@-axis slice %d of %d · depth %.1f mm", s.axisName, i + 1, s.rows.count, row.depthMM))
                    .font(.callout.monospacedDigit())
                Text(row.measurementText)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if (scan.sections ?? []).count > 1 {
                    Picker("Stack", selection: Binding(get: { series?.id ?? "" }, set: { seriesID = $0; index = 0; zipURL = nil })) {
                        ForEach(scan.sections ?? []) { s in
                            Text("\(s.axisName)-axis · every \(SectionSeries.format(s.spacingMM)) mm").tag(s.id)
                        }
                    }
                }
                if let zipURL {
                    ShareLink(item: zipURL) { Label("Share this stack (\(s.rows.count) PNG + CSV)", systemImage: "square.and.arrow.up") }
                } else {
                    Button {
                        let sc = scan
                        Task {
                            zipURL = await Task.detached { CrossSectionMaker.zip(s, in: sc) }.value
                        }
                    } label: { Label("Prepare stack to share", systemImage: "archivebox") }
                }
            } else {
                Text("No cross-sections yet.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Cross-sections")
        } footer: {
            Text("Slices are cut across the rock's own axes: a is the longest, c the shortest. They show the outer outline at each depth. A surface scan can't see inside the rock.")
        }

        Section("Cut a new stack") {
            Picker("Across axis", selection: $axis) {
                Text("a (long)").tag(0)
                Text("b").tag(1)
                Text("c (short)").tag(2)
            }
            .pickerStyle(.segmented)
            Picker("Spacing", selection: $spacing) {
                Text("0.5 mm").tag(0.5)
                Text("1 mm").tag(1.0)
                Text("2 mm").tag(2.0)
                Text("5 mm").tag(5.0)
            }
            .pickerStyle(.segmented)
            Button {
                working = true
                Task {
                    await model.makeSections(scan, axis: axis, spacingMM: spacing)
                    seriesID = SectionSeries(axis: axis, spacingMM: spacing, rows: []).id
                    index = 0
                    zipURL = nil
                    working = false
                }
            } label: {
                if working { ProgressView() } else { Label("Cut cross-sections", systemImage: "square.stack.3d.down.right") }
            }
            .disabled(working)
        }
    }
}

// MARK: Google Drive settings

struct DriveSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AppModel.autoUploadKey) private var autoUpload = true
    @AppStorage(AppModel.uploadPhotosKey) private var uploadPhotos = true
    @AppStorage(GoogleAuth.clientIDKey) private var pastedClientID = ""
    @State private var signingIn = false

    var body: some View {
        Section {
            if model.driveSignedIn {
                LabeledContent("Signed in as", value: model.driveEmail ?? "Google account")
                Toggle("Upload every scan automatically", isOn: $autoUpload)
                Toggle("Also upload original photos (Wi-Fi only)", isOn: $uploadPhotos)
                Button {
                    Task { await model.syncAllPending(force: true) }
                } label: {
                    if model.isSyncing { ProgressView() } else { Label("Upload pending scans now", systemImage: "icloud.and.arrow.up") }
                }
                .disabled(model.isSyncing)
                Button("Sign out of Google Drive", role: .destructive) { model.signOutOfDrive() }
            } else if GoogleAuth.shared.clientID != nil {
                Button {
                    signingIn = true
                    Task { await model.signInToDrive(); signingIn = false }
                } label: {
                    if signingIn { ProgressView() } else { Label("Sign in to Google Drive", systemImage: "person.badge.key") }
                }
                .disabled(signingIn)
            } else {
                Text("Google Drive upload isn't set up in this version yet.").foregroundStyle(.secondary)
                TextField("Paste Google client ID (optional)", text: $pastedClientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
            }
        } header: {
            Text("Google Drive")
        } footer: {
            Text("Finished scans go to My Drive › Crystal Bowl Scans, one folder per scan with manifest.json, the model in USDZ, STL, PLY and OBJ, and the cross-sections. On a computer with Google Drive for desktop it is the folder My Drive\\Crystal Bowl Scans. The app can only see the files it creates there. Original photos are a few hundred MB per scan, so they upload only on Wi-Fi; they let a Mac rebuild the model at full detail.")
        }
    }
}
