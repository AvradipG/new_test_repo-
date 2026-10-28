import SwiftUI
import RealityKit
import SceneKit

@main
struct CrystalBowlApp: App {
    @StateObject private var model = AppModel()
    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            switch model.phase {
            case .home:
                HomeView()
            case .capturing:
                if let session = model.captureSession {
                    CaptureView(session: session)
                } else {
                    ProgressView("Starting camera…")
                }
            case .reconstructing:
                ReconstructionView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: Home

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var sampleName = ""

    var body: some View {
        NavigationStack(path: $model.path) {
            List {
                Section {
                    TextField("Sample ID, e.g. CNPC-2H plug 3", text: $sampleName)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button {
                        model.startNewScan(name: sampleName)
                        sampleName = ""
                    } label: {
                        Label("Start new scan", systemImage: "viewfinder")
                            .font(.headline)
                    }
                    .disabled(!model.isCaptureSupported)
                    if !model.isCaptureSupported {
                        Text("3D capture needs a LiDAR iPhone (12 Pro or later Pro model) on iOS 17 or later.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("New scan")
                } footer: {
                    Text("Put the rock on a plain, matte surface with space to walk all the way around it. Use soft, even light.")
                }

                Section("Scans") {
                    if model.scans.isEmpty {
                        Text("No scans yet. Your scans appear here and in the Files app under On My iPhone › Crystal Bowl.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.scans) { scan in
                        NavigationLink(value: scan) { ScanRow(scan: scan) }
                    }
                    .onDelete { offsets in
                        for i in offsets { model.delete(model.scans[i]) }
                    }
                }

                Section("How to scan") {
                    TipRow(n: 1, text: "Tap Start, point at the rock, then tap Continue. Adjust the box so it just fits the rock.")
                    TipRow(n: 2, text: "Tap Start capture and walk slowly around the rock. The dial fills in as each angle is covered.")
                    TipRow(n: 3, text: "When the pass is done, flip the rock onto its side and scan again so the underside is captured.")
                    TipRow(n: 4, text: "Tap Finish. The model builds on the phone in a few minutes. Keep the app open.")
                }
            }
            .navigationTitle("Crystal Bowl")
            .navigationDestination(for: Scan.self) { scan in
                ScanDetailView(scanID: scan.id)
            }
            .refreshable { model.reload() }
        }
    }
}

struct TipRow: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.monospacedDigit().bold()).foregroundStyle(.tint)
            Text(text).font(.callout)
        }
    }
}

struct ScanRow: View {
    let scan: Scan
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(scan.name).font(.headline)
            HStack(spacing: 8) {
                Text(scan.created, style: .date)
                if let s = scan.stats {
                    Text(String(format: "%.0f × %.0f × %.0f mm", s.axisA, s.axisB, s.axisC)).monospacedDigit()
                } else if !scan.hasModel {
                    Text("No model yet").foregroundStyle(.orange)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Capture

struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    let session: ObjectCaptureSession

    var body: some View {
        ZStack {
            ObjectCaptureView(session: session)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Button("Cancel", role: .destructive) { model.cancelCapture() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Text("Pass \(model.passNumber) · \(model.shotCount) photos")
                        .font(.callout.monospacedDigit())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if let text = model.feedbackText {
                    Text(text)
                        .font(.callout.bold())
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
                VStack(spacing: 10) {
                    Text("Pass \(model.passNumber) complete.").font(.headline)
                    Button("Flip the rock and scan the underside") { model.flipAndContinue() }
                        .buttonStyle(.borderedProminent)
                    Button("Scan another pass without flipping") { model.anotherPass() }
                        .buttonStyle(.bordered)
                    Button("Finish and build the model") { model.finishCapture() }
                        .buttonStyle(.bordered)
                }
            } else {
                VStack(spacing: 10) {
                    Text("Walk slowly around the rock. Keep it inside the dial.").multilineTextAlignment(.center)
                    Button("Finish now") { model.finishCapture() }.buttonStyle(.bordered)
                }
            }
        case .finishing:
            ProgressView("Saving photos…")
        case .completed, .failed:
            EmptyView()
        }
    }
}

// MARK: Reconstruction

struct ReconstructionView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cube.transparent").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Building 3D model").font(.title2.bold())
            ProgressView(value: model.progress).frame(maxWidth: 280)
            Text(model.progressNote).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text("Keep the app open and the phone unlocked. This usually takes a few minutes.")
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
                if let s = scan.stats {
                    Section("Measurements") {
                        LabeledContent("Axes a × b × c", value: String(format: "%.1f × %.1f × %.1f mm", s.axisA, s.axisB, s.axisC))
                        LabeledContent("Volume", value: String(format: "%.2f cm³", s.volumeCM3))
                        if !s.isClosed {
                            Text("The mesh has small gaps, so the volume is approximate.").font(.footnote).foregroundStyle(.secondary)
                        }
                        LabeledContent("Triangles", value: s.triangleCount.formatted())
                        LabeledContent("Photos", value: "\(scan.photoCount ?? 0) in \(scan.passes ?? 1) pass(es)")
                    }
                }
                if scan.hasModel {
                    Section {
                        if exports.isEmpty {
                            Button {
                                exporting = true
                                Task {
                                    let s = scan
                                    exports = await Task.detached { MeshTools.exportAll(s) }.value
                                    exporting = false
                                }
                            } label: {
                                if exporting { ProgressView() } else { Label("Prepare files to share", systemImage: "doc.on.doc") }
                            }
                            .disabled(exporting)
                        } else {
                            ShareLink(items: exports) {
                                Label("Share \(exports.count) files", systemImage: "square.and.arrow.up")
                            }
                            ForEach(exports, id: \.self) { url in
                                ShareLink(item: url) {
                                    Label(url.lastPathComponent, systemImage: "doc")
                                }
                            }
                        }
                    } header: {
                        Text("Export")
                    } footer: {
                        Text("USDZ with colour, plus OBJ, PLY and STL in metres and a measurement report. Use Save to Files or Drive in the share sheet.")
                    }
                }
                Section {
                    Button("Delete scan", role: .destructive) { model.delete(scan) }
                }
            }
            .navigationTitle(scan.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("This scan was deleted.").foregroundStyle(.secondary)
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
