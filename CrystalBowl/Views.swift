import SwiftUI
import RealityKit
import SceneKit
import ScanMath

@main
struct CrystalBowlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView().environmentObject(delegate.model)
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
                TabView(selection: $model.tab) {
                    HomeView()
                        .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                        .tag(AppModel.Tab.scan)
                    PiecesHome()
                        .tabItem { Label("Pieces", systemImage: "puzzlepiece.extension") }
                        .tag(AppModel.Tab.pieces)
                    ARStudioHome()
                        .tabItem { Label("AR view", systemImage: "arkit") }
                        .tag(AppModel.Tab.ar)
                }
            case .capturing:
                if let session = model.captureSession {
                    CaptureView(guide: model.guide, session: session)
                } else {
                    ProgressView("Starting camera…")
                }
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
        .task {
            await model.checkForUpdate()
            // The new start (with its version line) goes to Drive straight away, then every 15 minutes on screen.
            await model.syncAllPending()
            await model.flushPhotosPending()
            if UserDefaults.standard.integer(forKey: SelfTest.lastBuildKey) != AppInfo.build {
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                if model.phase == .home && model.buildingID == nil && UIApplication.shared.applicationState == .active {
                    _ = await SelfTest.runAndLog(reason: "first start of \(AppInfo.label)")
                    await model.uploadAppLog()
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                if UIApplication.shared.applicationState == .active { await model.uploadAppLog() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            AppLog.setOnScreen(phase == .active)
            if phase == .active { AppLog.info("app", "On screen") }
            if phase == .background { AppLog.info("app", "Left the screen") }
            if phase == .active {
                model.resumePendingBuilds()
                Task { await model.upgradeScans() }
                Task {
                    await model.checkForUpdate()
                    await model.syncAllPending()
                    await model.flushPhotosPending()
                }
            } else if phase == .background {
                model.appMovedToBackground()
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
    @AppStorage("scan.quick") private var quick = false
    @State private var search = ""
    @State private var renaming: Scan?
    @State private var newName = ""
    @State private var showDriveSetup = false
    @State private var confirmDelete: Scan?

    private var shownScans: [Scan] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let samples = model.scans.filter { !$0.isPieces }
        return q.isEmpty ? samples : samples.filter { $0.name.lowercased().contains(q) || $0.id.contains(q) }
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            List {
                Section {
                    HeroCard(scanCount: model.scans.count,
                             onDrive: model.scans.filter { $0.drive?.complete == true || $0.folderSync?.complete == true }.count,
                             driveConnected: model.driveSignedIn || model.folderLinked) { showDriveSetup = true }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if let note = model.upgradeNote {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(note).font(.footnote)
                        }
                    }
                }
                if let notice = model.readyNotice {
                    Section {
                        ReadyCard(notice: notice) {
                            if let scan = model.scans.first(where: { $0.id == notice.id }) { model.path = [scan] }
                        } onDismiss: { model.readyNotice = nil }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
                if model.buildingID != nil || !model.pendingBuilds.isEmpty {
                    Section {
                        BuildStatusRow()
                    } footer: {
                        Text("The screen stays on while a model builds. Keep Crystal Bowl open (dim the screen if you like): an iPhone lets apps use its graphics chip only while they are on screen, so locking the phone or opening another app pauses the 3D build. It carries on from its last checkpoint when you come back.")
                    }
                }
                if let update = model.updateAvailable {
                    Section { UpdateBanner(remote: update) }
                }
                if !model.scansNeedingRepair.isEmpty {
                    Section {
                        Button {
                            Task { await model.repairAll() }
                        } label: {
                            HStack(spacing: 12) {
                                if model.repairing.isEmpty {
                                    Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                                } else {
                                    ProgressView()
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add full dimensions to \(model.scansNeedingRepair.count) older scan\(model.scansNeedingRepair.count == 1 ? "" : "s")")
                                        .font(.headline)
                                    Text("Re-measures each saved model, re-cuts its slices with sizes on every slice and adds a height profile. Photos aren't needed.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!model.repairing.isEmpty)
                    }
                }
                Section {
                    Picker("What do you need?", selection: $quick) {
                        Text("Dimensions only").tag(true)
                        Text("Dimensions + detail").tag(false)
                    }
                    .pickerStyle(.segmented)
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
                    Text(quick
                         ? "Dimensions only: one slow walk round the rock, then the app builds the model in the background and tells you the height, footprint and the cylinder it needs in the micro-CT. Use the same Sample ID for repeat scans so they are compared."
                         : "Dimensions + detail: walk round, flip the rock for the underside, then take close-ups of the surface with all lenses. Put the rock on a textured, matte surface (a newspaper page works) in soft, even light.")
                }

                Section {
                    if model.scans.isEmpty {
                        Text("No scans yet. Your scans appear here, in the Files app under On My iPhone › Crystal Bowl, and on Google Drive once it is connected.")
                            .foregroundStyle(.secondary)
                    } else if shownScans.isEmpty {
                        Text("No scan matches \"\(search)\".").foregroundStyle(.secondary)
                    }
                    ForEach(shownScans) { scan in
                        NavigationLink(value: scan) {
                            ScanRow(scan: scan, building: model.buildingID == scan.id, progress: model.progress,
                                    repeats: model.repeats(of: scan).count)
                        }
                        .contextMenu {
                            Button { newName = scan.name; renaming = scan } label: { Label("Rename", systemImage: "pencil") }
                            if scan.hasModel {
                                ShareLink(items: MeshTools.existingExports(scan)) { Label("Share model files", systemImage: "square.and.arrow.up") }
                            }
                            if scan.needsRepair {
                                Button { Task { await model.repair(scan) } } label: { Label("Repair (add full dimensions)", systemImage: "wrench.and.screwdriver") }
                            }
                            if !scan.hasModel && scan.hasPhotos && scan.buildRequested != true {
                                Button { model.reconstruct(scan) } label: { Label("Build model", systemImage: "cube") }
                            }
                            Button { UIPasteboard.general.string = model.dimensionsText(scan) } label: { Label("Copy dimensions", systemImage: "doc.on.doc") }
                            Divider()
                            Button(role: .destructive) { confirmDelete = scan } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { confirmDelete = scan } label: { Label("Delete", systemImage: "trash") }
                            Button { newName = scan.name; renaming = scan } label: { Label("Rename", systemImage: "pencil") }
                                .tint(Theme.blue)
                        }
                    }
                } header: {
                    Text("Scans")
                } footer: {
                    if !model.scans.isEmpty {
                        Text("Touch and hold a scan to rename, share, copy its dimensions or delete it. Swipe left for rename and delete.")
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
                           text: "On the scan page, enter one length measured with calipers to check and correct the scale. Later scans with the same Sample ID take that check over.")
                    TipRow(icon: "camera.macro", color: .purple,
                           text: "For surface patterns, open the scan and tap Take close-ups: the app picks the lens, keeps the rock in focus and zooms to it. Tap the rock on the screen if it focuses on something else.")
                }

                DriveSettingsSection()

                ExtraToolsSettingsSection()

                Section {
                    Toggle("Vibration guidance while scanning", isOn: $haptics)
                    Toggle("Keep photos after the model is built", isOn: $keepPhotos)
                    UnitPicker(title: "Show lengths in")
                } header: {
                    Text("Settings")
                } footer: {
                    Text("A scan needs a few hundred MB of photos while it is being built. Photos are kept until they are on Google Drive (when photo upload is on), then deleted unless you keep them. They let a Mac rebuild the model at full detail.")
                }
            }
            .navigationTitle("Crystal Bowl")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search scans")
            .sheet(isPresented: $showDriveSetup) { DriveSetupSheet() }
            .alert("Rename scan", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Sample ID", text: $newName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") {
                    if let scan = renaming { model.rename(scan, to: newName) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Files and the Google Drive folder keep their original names; the new name is shown in the app, the report and manifest.json.")
            }
            .confirmationDialog("Delete this scan?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete \(confirmDelete?.name ?? "scan")", role: .destructive) {
                    if let scan = confirmDelete { model.delete(scan) }
                    confirmDelete = nil
                }
            } message: {
                Text("The model, photos and slices on this iPhone are deleted. Copies on Google Drive stay.")
            }
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
                if scan.isPieces { PiecesDetailView(scanID: scan.id) } else { ScanDetailView(scanID: scan.id) }
            }
            .refreshable { model.reload() }
        }
    }

    private func start() {
        guard model.isCaptureSupported else { return }
        model.startNewScan(name: sampleName, quick: quick)
        sampleName = ""
    }
}

struct HeroCard: View {
    let scanCount: Int
    let onDrive: Int
    var driveConnected = false
    var onDriveTap: () -> Void = {}
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
                Button(action: onDriveTap) {
                    Chip(text: driveConnected ? "\(onDrive) on Drive" : "Connect Google Drive",
                         icon: driveConnected ? "icloud.fill" : "icloud.slash.fill")
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 22))
        .contentShape(Rectangle())
        .onTapGesture(perform: onDriveTap)
    }
}

/// Shown when a build has measured the rock: the sizes needed to centre it in the micro-CT come first.
struct ReadyCard: View {
    let notice: ReadyNotice
    let onOpen: () -> Void
    let onDismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.title)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(notice.name): dimensions ready").font(.headline)
                Text(notice.text).font(.callout.monospacedDigit())
                Text("Enough to centre it in the micro-CT. The full model and files finish in the background.")
                    .font(.caption).opacity(0.9)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) { Image(systemName: "xmark.circle.fill").font(.title3) }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(LinearGradient(colors: [.green, Theme.teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

/// Progress of the build running now and the builds waiting.
struct BuildStatusRow: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = model.buildingID, let scan = model.scans.first(where: { $0.id == id }) {
                Button { model.path = [scan] } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Building \(scan.name)", systemImage: "cube.transparent.fill").font(.headline)
                        ProgressView(value: model.progress)
                        Text(model.progressNote).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            if let note = model.buildPausedNote {
                Label(note, systemImage: "pause.circle.fill").font(.caption).foregroundStyle(.orange)
            }
            if model.buildingID != nil { BuildDimButton() }
            ForEach(model.pendingBuilds) { scan in
                Label("\(scan.name): waiting to build", systemImage: "clock").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Darkens the screen while a model builds. The screen has to stay on (an iPhone stops 3D building when it
/// locks), so this is the way to put the phone down and wait.
struct BuildDimButton: View {
    static let keepOpenText = "Keep Crystal Bowl open; the screen stays on. Locking the phone pauses the build (an iPhone builds 3D models only on screen), and it then carries on from its last checkpoint."
    @EnvironmentObject var model: AppModel
    @State private var dimmed = false
    var body: some View {
        Button { dimmed = true } label: {
            Label("Dim the screen while it builds", systemImage: "moon.fill").font(.callout)
        }
        .buttonStyle(.borderless)
        .fullScreenCover(isPresented: $dimmed) { BuildDimView().environmentObject(model) }
    }
}

struct BuildDimView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var saved: CGFloat?

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("\(Int(model.progress * 100))%").font(.system(size: 56, weight: .thin).monospacedDigit())
                Text(model.progressNote).font(.footnote).multilineTextAlignment(.center)
                Text("Building. Leave the phone like this; tap to brighten.").font(.caption)
            }
            .foregroundStyle(Color(white: 0.4))
            .padding(32)
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            saved = screen?.brightness
            screen?.brightness = 0.02
            AppLog.info("app", "Screen dimmed during the build")
        }
        .onDisappear { restore() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { restore() } }
        .onChange(of: model.buildingID) { _, id in if id == nil { dismiss() } }
    }

    private func restore() {
        if let saved { screen?.brightness = saved }
        saved = nil
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
    @AppStorage(UnitPref.key) private var unitRaw = "mm"
    let scan: Scan
    var building = false
    var progress = 0.0
    var repeats = 0
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
                        Text(LL([s.axisA * f, s.axisB * f, s.axisC * f])).monospacedDigit()
                    } else if building {
                        Text("Building… \(Int(progress * 100))%").foregroundStyle(Theme.violet).monospacedDigit()
                    } else if scan.buildRequested == true {
                        Text("Waiting to build").foregroundStyle(.orange)
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
                        Chip(text: "Caliper", icon: "ruler.fill", tint: Theme.blue).foregroundStyle(Theme.blue)
                    }
                    if scan.detailCount > 0 {
                        Chip(text: "\(scan.detailCount) close-ups", icon: "camera.macro", tint: .purple).foregroundStyle(.purple)
                    }
                    if repeats > 1 {
                        Chip(text: "\(repeats) scans", icon: "square.stack", tint: .orange).foregroundStyle(.orange)
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
                if model.captureStage == .capturing {
                    FocusTapLayer()
                        .ignoresSafeArea()
                }
            }
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Cancel", role: .destructive) { model.cancelCapture() }
                            .buttonStyle(.bordered)
                        if CameraAssist.hasLight && model.captureStage != .initializing {
                            Button { model.toggleLight() } label: {
                                Image(systemName: model.lightOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                                    .background(model.lightOn ? Color.yellow.opacity(0.85) : Color.clear, in: Circle())
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .accessibilityLabel(model.lightOn ? "Turn the light off" : "Turn the light on")
                        }
                    }
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
                if !model.passCompleted && model.captureStage == .capturing, let gap = guide.nextGap, gap != 0 {
                    GapArrow(sectors: gap)
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
                Text(model.piecesCapture
                     ? (model.captureSide == 2
                        ? "Side 2: every piece turned over where it lay. Point the camera at the pieces; the phone finds the table first."
                        : "Spread the pieces on a matte, textured surface, a finger-width apart, none touching. Point the camera at them; the phone finds the table first.")
                     : "Put the rock on a plain table and point the camera at it. The phone first finds the table surface, then the rock on it.")
                    .multilineTextAlignment(.center)
                Button("Continue") { model.startDetecting() }
                    .buttonStyle(.borderedProminent)
            }
        case .detecting:
            VStack(spacing: 10) {
                Text(model.piecesCapture
                     ? "Drag the box edges so it holds all the pieces (and the smallest grains), but as little else as possible."
                     : "The table is found and the box sits on it round the rock. Drag the box edges so it just fits the rock, nothing else.")
                    .multilineTextAlignment(.center)
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
                         ? "Follow the orange arrow to each orange sector, at the height the text says. Hold still for a second on each one. If the camera won't take it, Photo here turns orange: tap it."
                         : model.quickCapture
                            ? "Dimensions only: one slow walk round the rock, 25–40 cm away. A tick for each photo; a buzz means slow down, change height or a blurred photo."
                            : "Walk slowly round the rock, 25–40 cm away. Feel a tick for each photo; a buzz means slow down, change height or a blurred photo.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    Text("Tap the rock on screen to focus and brighten it. Hold still on an orange sector and the photo is taken for you, or tap the shutter.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Finish now") { model.finishCapture() }.buttonStyle(.bordered)
                        Button { model.takePhotoNow() } label: {
                            Label("Photo here", systemImage: "camera.circle.fill")
                                .symbolEffect(.pulse, isActive: guide.askManual)
                                .font(guide.askManual ? .title3.bold() : .body)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(guide.askManual ? .orange : nil)
                    }
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
        let enoughForSize = cov.max() ?? 0 >= 0.6
        return VStack(alignment: .leading, spacing: 10) {
            Text("Pass \(model.passNumber) complete").font(.headline)
            if model.blurryShots > 0 {
                Label("\(model.blurryShots) blurred photo\(model.blurryShots == 1 ? "" : "s"): those spots show as gaps and are left out of the model.",
                      systemImage: "camera.metering.unknown")
                    .font(.caption).foregroundStyle(.orange)
            }
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
            if model.piecesCapture {
                let gapsLabel = Label(needsMore ? "Fill the gaps (go round again, a bit higher)" : "Another pass, a bit higher",
                                      systemImage: "circle.dashed").frame(maxWidth: .infinity)
                let finishLabel = Label(model.captureSide == 2 ? "Finish side 2 and put the pieces together" : "Finish side 1",
                                        systemImage: "puzzlepiece.extension.fill").frame(maxWidth: .infinity)
                if needsMore {
                    Button { model.anotherPass() } label: { gapsLabel }.buttonStyle(.borderedProminent)
                    Button { model.finishCapture() } label: { finishLabel }.buttonStyle(.bordered)
                } else {
                    Button { model.finishCapture() } label: { finishLabel }.buttonStyle(.borderedProminent)
                    Button { model.anotherPass() } label: { gapsLabel }.buttonStyle(.bordered)
                }
                Text(model.captureSide == 2
                     ? "Both sides are then built and the pieces matched by themselves."
                     : "Next, the app builds side 1. Then turn every piece over where it lies and scan side 2 from the Pieces tab.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.quickCapture && enoughForSize {
                Button { model.finishCapture() } label: {
                    Label("Get the dimensions now", systemImage: "ruler.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("One ring is enough for height, footprint and the micro-CT cylinder. The underside isn't captured, so its shape is guessed flat.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { model.anotherPass() } label: {
                    Label("Fill the gaps first", systemImage: "circle.dashed").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else if needsMore {
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
            if !(model.quickCapture && enoughForSize) && !model.piecesCapture {
                Button { model.finishCapture() } label: {
                    Label("Finish and build the model", systemImage: "cube.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// Small "enlarge" badge on pictures that open full screen.
struct EnlargeBadge: View {
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption.weight(.bold)).foregroundStyle(.white)
            .padding(7).background(.black.opacity(0.55), in: Circle()).padding(8)
            .accessibilityHidden(true)
    }
}

/// Big turn arrow while filling gaps: which way round the rock and how far. It turns the same way as the ring,
/// where the user's walking direction is clockwise.
struct GapArrow: View {
    let sectors: Int
    var body: some View {
        let degrees = abs(sectors) * 360 / CaptureGuide.sectorCount
        HStack(spacing: 10) {
            Image(systemName: sectors > 0 ? "arrow.clockwise" : "arrow.counterclockwise")
                .font(.system(size: 34, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(degrees)° \(sectors > 0 ? "on" : "back")").font(.title3.bold().monospacedDigit())
                Text(sectors > 0 ? "the same way you walked" : "the way you came").font(.caption)
            }
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
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
                    // Orange: the ring being filled, and holes in any ring that already has photos.
                    let started = coverage[b].contains { $0 > 0 }
                    let color: Color = coverage[b][s] > 0 ? .green
                        : (b == target?.rawValue ? .orange : (started ? Color.orange.opacity(0.75) : Color.gray.opacity(0.35)))
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

// MARK: Scan detail

struct ScanDetailView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(UnitPref.key) private var unitRaw = "mm"
    let scanID: String
    @State private var exports: [URL] = []
    @State private var exporting = false
    @State private var measuring = false
    @State private var copied = false
    @State private var showDetailCamera = false
    @State private var showAR = false
    @State private var showMeasure = false
    @State private var sectionViewer: SectionViewerTarget?
    @State private var gallery: GalleryTarget?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var cleanSheet = false

    private var scan: Scan? { model.scans.first { $0.id == scanID } }

    var body: some View {
        if let scan {
            List {
                Section {
                    if scan.hasModel {
                        ModelPreview(url: scan.modelURL)
                            .frame(height: 320)
                            .listRowInsets(EdgeInsets())
                        Button { showMeasure = true } label: {
                            Label("Measure in 3D: sizes, ruler, protractor, sample sheet", systemImage: "ruler")
                        }
                        Button { showAR = true } label: {
                            Label("See it on the table in AR (real size or scaled)", systemImage: "arkit")
                        }
                    } else if model.buildingID == scan.id {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Building the 3D model", systemImage: "cube.transparent.fill").font(.headline)
                            ProgressView(value: model.progress)
                            Text(model.progressNote).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Text(BuildDimButton.keepOpenText + " The dimensions come first.")
                                .font(.caption).foregroundStyle(.secondary)
                            BuildDimButton()
                        }
                    } else if scan.buildRequested == true {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Waiting to build", systemImage: "clock").font(.headline)
                            Text("It starts by itself after the scan before it, or continues from where iOS paused it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("No model yet. \(scan.photoCount ?? ScanStore.countPhotos(in: scan.imagesURL)) photos are saved.")
                            Button("Build model") { model.reconstruct(scan) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!scan.hasPhotos)
                        }
                    }
                }
                if let s = scan.stats, let u = s.upright {
                    microCTSection(scan, s, u)
                }
                if scan.needsRepair {
                    Section {
                        Button {
                            Task { await model.repair(scan) }
                        } label: {
                            if model.repairing.contains(scan.id) {
                                HStack(spacing: 10) { ProgressView(); Text("Repairing: measuring and re-cutting…") }
                            } else {
                                Label("Repair: add full dimensions to this scan", systemImage: "wrench.and.screwdriver.fill")
                            }
                        }
                        .disabled(model.repairing.contains(scan.id))
                    } footer: {
                        Text("This scan was made with an older version: its slices lack sizes or it has no height profile. Repair re-measures the saved model; photos aren't needed.")
                    }
                }
                if scan.hasModel {
                    sampleSheetSection(scan)
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
                    detailSection(scan)
                    RepeatsSection(scan: scan, repeats: model.repeats(of: scan))
                    SectionsPanel(scan: scan, viewer: $sectionViewer)
                    ExtraToolsSection(scan: scan)
                }
                Section {
                    LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: ScanStore.size(of: scan), countStyle: .file))
                    if scan.hasPhotos {
                        Button("Delete photos, keep model") { ScanStore.deletePhotos(scan); model.reload() }
                    }
                    Button("Delete scan", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(scan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { newName = scan.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                        Button { UIPasteboard.general.string = model.dimensionsText(scan) } label: { Label("Copy dimensions", systemImage: "doc.on.doc") }
                        if scan.hasModel {
                            Button { showDetailCamera = true } label: { Label("Take close-ups", systemImage: "camera.macro") }
                        }
                        Divider()
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete scan", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Rename scan", isPresented: $renaming) {
                TextField("Sample ID", text: $newName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") { model.rename(scan, to: newName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Scans with the same Sample ID are compared as repeat scans of one sample.")
            }
            .confirmationDialog("Delete this scan?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete \(scan.name)", role: .destructive) { model.delete(scan) }
            } message: {
                Text("The model, photos and slices on this iPhone are deleted. Copies on Google Drive stay.")
            }
            .fullScreenCover(isPresented: $showAR) {
                ARStudioScreen(scans: [scan])
            }
            .fullScreenCover(isPresented: $showMeasure) {
                MeasureViewer(scan: scan)
            }
            .fullScreenCover(item: $sectionViewer) { target in
                SectionViewerHost(target: target).environmentObject(model)
            }
            .fullScreenCover(item: $gallery) { target in
                GalleryViewer(target: target).environmentObject(model)
            }
            .fullScreenCover(isPresented: $showDetailCamera) {
                DetailCaptureView(scan: scan) {
                    showDetailCamera = false
                    model.reload()
                    Task { await model.syncAllPending() }
                }
            }
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

    /// The latest sample sheet (made automatically, or again from the 3D view at another angle).
    @ViewBuilder private func sampleSheetSection(_ scan: Scan) -> some View {
        let dir = scan.exportsURL.appendingPathComponent("sheet", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        let sci = files.first { $0.lastPathComponent.contains("sample-sheet-scientific") }
        let clean = files.first { $0.lastPathComponent.contains("sample-sheet-clean") }
        let older = files.first { $0.lastPathComponent.contains("sample-sheet") }
        let chosen = (cleanSheet ? clean : sci) ?? sci ?? clean ?? older
        if let sheet = chosen, let img = UIImage(contentsOfFile: sheet.path) {
            Section {
                if sci != nil && clean != nil {
                    Picker("Template", selection: $cleanSheet) {
                        Text("Scientific").tag(false)
                        Text("Clean").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                let pictures = SheetPictures.items(scan)
                Image(uiImage: img).resizable().scaledToFit()
                    .overlay(alignment: .bottomTrailing) { EnlargeBadge() }
                    .contentShape(Rectangle())
                    .onTapGesture { open(pictures, sheet) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the sheet full screen to zoom")
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                // Each view on its own: tap to open it full screen.
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(pictures.filter { !$0.url.lastPathComponent.contains("sample-sheet") }) { p in
                            Button { open(pictures, p.url) } label: {
                                VStack(spacing: 3) {
                                    SectionThumb(url: p.url, maxPixel: 240)
                                        .frame(width: 84, height: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(p.title).font(.caption2).lineLimit(2).multilineTextAlignment(.center).frame(width: 84)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if let u = files.first(where: { $0.lastPathComponent.contains("_unrolled_") }), let ui = UIImage(contentsOfFile: u.path) {
                    DisclosureGroup("Unrolled side (360°)") {
                        Image(uiImage: ui).resizable().scaledToFit()
                            .overlay(alignment: .bottomTrailing) { EnlargeBadge() }
                            .contentShape(Rectangle())
                            .onTapGesture { open(pictures, u) }
                    }
                }
                ShareLink(items: files) { Label("Share the sample sheet (\(files.count) images)", systemImage: "square.and.arrow.up") }
            } header: {
                Text("Sample sheet")
            } footer: {
                Text((scan.mark?.summary ?? "No marker line found: views count from the start of the scan. Set the mark by hand in Measure in 3D.")
                     + ". Make it again at another angle from Measure in 3D.")
            }
        }
    }

    private func open(_ items: [GalleryItem], _ url: URL) {
        guard !items.isEmpty else { return }
        gallery = GalleryTarget(items: items, start: items.firstIndex { $0.url == url } ?? 0)
    }

    private func driveSection(_ scan: Scan) -> some View {
        let folder = "\(ScanPackage.rootFolder)/\(scan.id)_\(scan.fileStem)"
        return Section {
            if model.folderLinked && !model.driveSignedIn {
                if let status = model.folderStatus[scan.id] {
                    Label(status, systemImage: "arrow.triangle.2.circlepath.icloud")
                } else if let d = scan.folderSync, d.complete, let when = d.lastSync {
                    Label("In the Drive folder \(model.folderName ?? "") since \(when.formatted(date: .abbreviated, time: .shortened)); the Google Drive app uploads it.",
                          systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Waiting to copy to the Drive folder", systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary)
                }
                Text("Google Drive › \(model.folderName ?? "your folder") › \(scan.id)_\(scan.fileStem)")
                    .font(.callout.monospaced())
                Button("Copy to the Drive folder now") { Task { await model.syncToFolder(scan) } }
            }
            if !model.driveSignedIn && !model.folderLinked {
                Label("Not connected. Tap \"Connect Google Drive\" on the home screen and every scan goes there by itself.", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            } else if model.driveSignedIn {
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
            LabeledContent(s.box == nil ? "Axes a × b × c" : "Smallest box a × b × c", value: LL([s.axisA * f, s.axisB * f, s.axisC * f]))
            if let b = s.box {
                LabeledContent("Longest / narrowest (3D)", value: L(b.maxFeretMM * f) + " / " + L(b.minFeretMM * f))
            }
            if let shape = scan.shape {
                Text(shape.text(scale: f)).font(.callout)
            }
            LabeledContent("Volume", value: LV(cm3: s.volumeCM3 * f * f * f))
            if !s.isClosed {
                Text("The mesh has small gaps, so the volume is approximate.").font(.footnote).foregroundStyle(.secondary)
            }
            if let u = s.upright {
                LabeledContent("Height (as scanned)", value: L(u.heightMM * f))
                LabeledContent("Footprint L × W", value: LL([u.lengthMM * f, u.widthMM * f]))
                LabeledContent("Widest across", value: L(u.maxDiameterMM * f))
            }
            if let e = s.medianEdgeMM {
                LabeledContent("Mesh detail", value: String(format: "%.2f mm edges", e))
            }
            if let r = s.removedPieces, r > 0 {
                LabeledContent("Loose pieces left out", value: String(format: "%d (%.1f %% of surface)", r, (1 - (s.keptAreaShare ?? 1)) * 100))
            }
            if let b = scan.blurrySetAside, b > 0 {
                LabeledContent("Blurred photos left out", value: "\(b)")
            }
            LabeledContent("Triangles", value: s.triangleCount.formatted())
            LabeledContent("Photos", value: "\(scan.photoCount ?? 0) in \(scan.passes ?? 1) pass(es)")
            if let cov = scan.coverage, cov.count == 3 {
                LabeledContent("Coverage low / mid / high", value: String(format: "%.0f / %.0f / %.0f %%", cov[0] * 100, cov[1] * 100, cov[2] * 100))
            }
        } header: {
            Text(scan.caliper == nil ? "Measurements (LiDAR scale)" : "Measurements (caliper-corrected)")
        } footer: {
            Text(s.box == nil
                 ? "Measured with the older method. Tap Repair above to get the smallest-box sizes, which agree better between repeat scans."
                 : "a × b × c are the sides of the smallest box that holds the rock, so they don't depend on how it lay. Loose fragments and bits of table are left out. Mesh detail is triangle spacing, not accuracy.")
        }
    }
}

extension ScanDetailView {
    func microCTSection(_ scan: Scan, _ s: MeshStats, _ u: UprightSize) -> some View {
        let f = scan.scaleFactor
        return Section {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title2)
                Text("3D dimensions ready: enough to centre the sample in the micro-CT.").font(.callout.bold())
            }
            LabeledContent("Height (as it stood)", value: L(u.heightMM * f))
            LabeledContent("Fits a cylinder", value: "Ø " + L((u.cylinderDiameterMM ?? u.maxDiameterMM) * f))
            LabeledContent("Footprint L × W", value: LL([u.lengthMM * f, u.widthMM * f]))
        } header: {
            Text("Micro-CT centring")
        } footer: {
            Text(scan.caliper == nil
                 ? "LiDAR scale. The cylinder is the smallest upright cylinder around the rock as it stood when scanned: the clearance it needs turning on the stage. Enter a caliper length below to correct the scale."
                 : "Caliper-corrected. The cylinder is the smallest upright cylinder around the rock as it stood when scanned: the clearance it needs turning on the stage.")
        }
    }

    func detailSection(_ scan: Scan) -> some View {
        Section {
            Button { showDetailCamera = true } label: {
                Label(scan.detailCount == 0 ? "Take close-ups of the surface" : "Take more close-ups (\(scan.detailCount) so far)",
                      systemImage: "camera.macro")
            }
            if scan.detailCount > 0 {
                ShareLink(items: ScanStore.photoURLs(in: scan.detailURL)) {
                    Label("Share close-ups", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Detail photos (optional)")
        } footer: {
            Text("For surface patterns and later image identification. The camera uses all lenses (macro, main, telephoto), keeps the rock in focus, zooms to it and drops blurred shots. Not needed for the dimensions.")
        }
    }
}

/// Repeat scans of one sample (same Sample ID): mean, spread and range of each size.
struct RepeatsSection: View {
    let scan: Scan
    let repeats: [Scan]

    var body: some View {
        if repeats.count > 1 {
            Section {
                row("a (length)") { $0.axisA }
                row("b (width)") { $0.axisB }
                row("c (thickness)") { $0.axisC }
                row("Height as scanned") { $0.upright?.heightMM }
                row("Micro-CT cylinder Ø") { $0.upright?.cylinderDiameterMM }
            } header: {
                Text("Repeat scans of \(scan.name) (\(repeats.count))")
            } footer: {
                Text("Mean ± standard deviation and the range over all scans with this Sample ID, each with its own (or taken-over) caliper scale. A spread above about 1 mm usually comes from the scale: check one length with calipers and later scans take it over. Rename scans so repeats share one Sample ID.")
            }
        }
    }

    private func row(_ title: String, _ value: @escaping (MeshStats) -> Double?) -> some View {
        let values = repeats.compactMap { s -> Double? in s.stats.flatMap(value).map { $0 * s.scaleFactor } }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / max(n, 1)
        let sd = n > 1 ? (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / (n - 1)).squareRoot() : 0
        let lo = values.min() ?? 0, hi = values.max() ?? 0
        let un = UnitPref.unit
        let text = un.format(mean, symbol: false) + " ± " + un.format(sd) + " (" + un.format(lo, symbol: false) + "–" + un.format(hi, symbol: false) + ")"
        return LabeledContent(title, value: values.isEmpty ? "–" : text)
            .font(.callout.monospacedDigit())
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
                let axisName = c.axisName
                LabeledContent("Calipers, axis \(axisName)", value: String(format: "%.2f mm", c.measuredMM))
                LabeledContent("Scan, axis \(axisName)", value: String(format: "%.2f mm", c.measuredMM / f))
                LabeledContent("Scan scale error", value: String(format: "%+.2f %%", (1 / f - 1) * 100))
                if c.fromScanID != nil {
                    Text("Taken over from an earlier scan of the same sample. Enter a new caliper length to replace it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Remove caliper check", role: .destructive) { model.setCaliper(scan, axis: 0, measuredMM: nil) }
            } else {
                Picker("Axis", selection: $axis) {
                    Text(String(format: "a %.1f", stats.axisA)).tag(0)
                    Text(String(format: "b %.1f", stats.axisB)).tag(1)
                    Text(String(format: "c %.1f", stats.axisC)).tag(2)
                    if let u = stats.upright {
                        Text(String(format: "h %.1f", u.heightMM)).tag(3)
                    }
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
    @Binding var viewer: SectionViewerTarget?
    @AppStorage(PhotoSaver.modeKey) private var photosMode = "every"

    private var series: SectionSeries? {
        let all = scan.sections ?? []
        return all.first { $0.id == seriesID } ?? all.first
    }

    private func open(_ s: SectionSeries, _ k: Int) {
        viewer = SectionViewerTarget(scan: scan, series: s, index: k) { index = Double($0) }
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
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.bold)).foregroundStyle(.white)
                                .padding(7).background(.black.opacity(0.55), in: Circle()).padding(8)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { open(s, i) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Opens the slice full screen to zoom")
                        .listRowInsets(EdgeInsets())
                } else {
                    Text("This slice's picture is missing. Cut the stack again.").foregroundStyle(.secondary)
                }
                if s.rows.count > 1 {
                    Slider(value: $index, in: 0...Double(s.rows.count - 1), step: 1)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 6) {
                                ForEach(0..<s.rows.count, id: \.self) { k in
                                    SectionThumb(url: s.imageURL(in: scan, index: k), maxPixel: 200)
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(k == i ? Color.accentColor : .clear, lineWidth: 2))
                                        .onTapGesture { index = Double(k) }
                                        .onLongPressGesture { index = Double(k); open(s, k) }
                                        .id(k)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onChange(of: i) { _, k in withAnimation { proxy.scrollTo(k, anchor: .center) } }
                    }
                }
                Text(String(format: "%@ slice %d of %d · %@ ", s.title, i + 1, s.rows.count, s.isHeightProfile ? "height" : "depth") + L(row.depthMM))
                    .font(.callout.monospacedDigit())
                Text(row.measurementText)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if (scan.sections ?? []).count > 1 {
                    Picker("Stack", selection: Binding(get: { series?.id ?? "" }, set: { seriesID = $0; index = 0; zipURL = nil })) {
                        ForEach(scan.sections ?? []) { s in
                            Text("\(s.title) · every \(SectionSeries.format(s.spacingMM)) mm").tag(s.id)
                        }
                    }
                }
                Button { open(s, i) } label: {
                    Label("Open full screen to zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                NavigationLink {
                    SectionGridView(scan: scan, series: s, start: i) { index = Double($0) }
                } label: {
                    Label("See all \(s.rows.count) slices", systemImage: "square.grid.3x3")
                }
                SectionExportMenu(scan: scan, series: s, index: i)
                if let note = model.photosNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
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
            Text("Tap a slice to open it full screen: pinch or double-tap to zoom, swipe for the next one. Slices are cut across the rock's own axes (a longest, c shortest) or, for the height profile, horizontally up the model as it stood. Every slice gives its widest and narrowest size from the outline; area needs a closed outline. A surface scan can't see inside the rock.")
        }

        Section("Cut a new stack") {
            Picker("Across axis", selection: $axis) {
                Text("a (long)").tag(0)
                Text("b").tag(1)
                Text("c (short)").tag(2)
                Text("height").tag(3)
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

        Section {
            Picker("Save new stacks to Photos", selection: $photosMode) {
                Text("Every slice and the all-in-one picture").tag("every")
                Text("Only the all-in-one picture").tag("one")
                Text("Off").tag("off")
            }
        } header: {
            Text("Automatic copies")
        } footer: {
            Text("Every stack is saved as PNG pictures: one per slice and one with all slices together. They go to Google Drive by themselves (the scan's sections folder) and, with this setting, to Photos. Photos asks once for permission to add pictures.")
        }
    }
}

// MARK: Google Drive settings

struct DriveSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AppModel.uploadPhotosKey) private var uploadPhotos = true
    @AppStorage(GoogleAuth.clientIDKey) private var pastedClientID = ""
    @State private var signingIn = false

    @State private var showSetup = false

    var body: some View {
        Section {
            if model.folderLinked {
                LabeledContent("Drive folder", value: model.folderName ?? "chosen folder")
                Button("Choose a different folder") { showSetup = true }
                Button("Stop copying to this folder", role: .destructive) { model.unlinkFolder() }
            } else if !model.driveSignedIn {
                Button { showSetup = true } label: {
                    Label("Connect Google Drive", systemImage: "icloud.and.arrow.up.fill").font(.headline)
                }
            }
            if model.driveSignedIn {
                LabeledContent("Signed in as", value: model.driveEmail ?? "Google account")
                Button {
                    Task { await model.syncAllPending(force: true) }
                } label: {
                    if model.isSyncing { ProgressView() } else { Label("Upload pending scans now", systemImage: "icloud.and.arrow.up") }
                }
                .disabled(model.isSyncing)
                Button("Sign out of Google Drive", role: .destructive) { model.signOutOfDrive() }
            } else if GoogleAuth.shared.clientID != nil && !model.folderLinked {
                Button {
                    signingIn = true
                    Task { await model.signInToDrive(); signingIn = false }
                } label: {
                    if signingIn { ProgressView() } else { Label("Sign in to Google Drive", systemImage: "person.badge.key") }
                }
                .disabled(signingIn)
            }
            if model.folderLinked || model.driveSignedIn {
                Toggle("Also upload photos and close-ups (Wi-Fi only)", isOn: $uploadPhotos)
            }
        } header: {
            Text("Google Drive")
        } footer: {
            Text("Every finished scan uploads by itself, in the background too (other apps open, phone locked). It goes to My Drive › Crystal Bowl Scans: one folder per scan, named <date-time>_<sample>, with manifest.json, dimensions.json, the model in USDZ, STL, PLY and OBJ, and the cross-sections. index.json lists every scan with its date and sizes for other software. On a computer with Google Drive for desktop it is the folder My Drive\\Crystal Bowl Scans. Photos are a few hundred MB per scan, so they go only on Wi-Fi.")
        }
        .sheet(isPresented: $showSetup) { DriveSetupSheet() }
    }
}

/// Connecting Google Drive in one step: pick (or create) the folder in the Files app's Google Drive location.
struct DriveSetupSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(GoogleAuth.clientIDKey) private var pastedClientID = ""
    @State private var picking = false
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TipRow(icon: "1.circle.fill", color: Theme.violet, text: "Install the Google Drive app from the App Store and sign in to it (once).")
                    TipRow(icon: "2.circle.fill", color: Theme.blue, text: "Tap Choose folder below. Tap Browse › Google Drive › My Drive. Create a folder named Crystal Bowl Scans (or pick it) and tap Open.")
                    TipRow(icon: "3.circle.fill", color: Theme.teal, text: "Done. Every finished scan is copied there by itself, and the Google Drive app uploads it, even after you close Crystal Bowl.")
                    Button { picking = true } label: {
                        Label(model.folderLinked ? "Choose a different folder" : "Choose folder", systemImage: "folder.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(.white)
                            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    if model.folderLinked {
                        Label("Connected: \(model.folderName ?? "folder")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } header: {
                    Text("Recommended: through the Google Drive app")
                } footer: {
                    Text("No Google sign-in or setup inside Crystal Bowl. Your PC software finds the scans in My Drive\\Crystal Bowl Scans, each with manifest.json written last.")
                }
                Section {
                    if model.driveSignedIn {
                        LabeledContent("Signed in as", value: model.driveEmail ?? "Google account")
                    } else if GoogleAuth.shared.clientID != nil {
                        Button {
                            signingIn = true
                            Task { await model.signInToDrive(); signingIn = false }
                        } label: {
                            if signingIn { ProgressView() } else { Label("Sign in with Google", systemImage: "person.badge.key") }
                        }
                    } else {
                        Text("Direct upload needs a Google client ID for this app. Paste one here if you have it; otherwise use the folder above.")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("Google client ID (…apps.googleusercontent.com)", text: $pastedClientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                    }
                } header: {
                    Text("Alternative: direct upload")
                }
            }
            .navigationTitle("Connect Google Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    model.linkFolder(url)
                }
            }
        }
    }
}

/// Tap anywhere on the camera picture to focus and set the brightness on that spot (like the Camera app).
struct FocusTapLayer: View {
    @State private var mark: CGPoint?
    @State private var markID = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear.contentShape(Rectangle())
                if let mark {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: 76, height: 76)
                        .position(mark)
                        .transition(.opacity)
                }
            }
            .onTapGesture { p in
                guard geo.size.width > 0, geo.size.height > 0 else { return }
                CameraAssist.focus(atView: CGPoint(x: p.x / geo.size.width, y: p.y / geo.size.height))
                UISelectionFeedbackGenerator().selectionChanged()
                withAnimation { mark = p }
                markID += 1
                let id = markID
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if markID == id { withAnimation { mark = nil } }
                }
            }
        }
    }
}
