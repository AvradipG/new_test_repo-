import SwiftUI
import SceneKit
import ScanMath

/// 360° protractor in the style of SliceLock: 0° at the top, outer numbers counter-clockwise, inner numbers
/// clockwise, the swept wedge from 0° to the angle, a needle, and the exact angle in the hub.
/// Drag round the ring to turn the sample.
struct ProtractorDial: View {
    @Binding var angle: Double
    var accent: Color = Color(red: 0.35, green: 0.7, blue: 1)
    @State private var lastTouch: Double?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = min(size.width, size.height) / 2 - 4
                func pt(_ a: Double, _ r: CGFloat) -> CGPoint {
                    CGPoint(x: c.x - r * sin(a * .pi / 180), y: c.y - r * cos(a * .pi / 180))
                }
                let disc = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
                ctx.fill(disc, with: .color(.black.opacity(0.55)))
                ctx.fill(disc, with: .color(accent.opacity(0.12)))
                ctx.stroke(disc, with: .color(accent), lineWidth: 1.6)
                for a in 0..<360 {
                    let L: CGFloat = a % 10 == 0 ? R * 0.11 : (a % 5 == 0 ? R * 0.075 : R * 0.04)
                    var p = Path()
                    p.move(to: pt(Double(a), R - 1))
                    p.addLine(to: pt(Double(a), R - 1 - L))
                    ctx.stroke(p, with: .color(a % 10 == 0 ? .white : accent.opacity(a % 5 == 0 ? 0.8 : 0.5)), lineWidth: a % 30 == 0 ? 1.6 : 0.8)
                }
                for a in stride(from: 0, to: 360, by: 30) {
                    ctx.draw(Text("\(a)").font(.system(size: R * 0.09, weight: .bold)).foregroundColor(.white), at: pt(Double(a), R * 0.78))
                    ctx.draw(Text("\((360 - a) % 360)").font(.system(size: R * 0.06)).foregroundColor(accent.opacity(0.8)), at: pt(Double(a), R * 0.62))
                }
                // Swept wedge from 0° to the angle.
                let sv = Rotation.normalized(angle)
                if abs(sv) > 0.05 {
                    var w = Path()
                    w.move(to: c)
                    w.addArc(center: c, radius: R * 0.52, startAngle: .degrees(-90), endAngle: .degrees(-90 - sv), clockwise: sv > 0)
                    w.closeSubpath()
                    ctx.fill(w, with: .color(accent.opacity(0.22)))
                    ctx.stroke(w, with: .color(accent.opacity(0.7)), lineWidth: 1)
                }
                // Zero arm.
                var zero = Path()
                zero.move(to: c)
                zero.addLine(to: pt(0, R - 2))
                ctx.stroke(zero, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                // Needle.
                var needle = Path()
                needle.move(to: c)
                needle.addLine(to: pt(sv, R - 2))
                ctx.stroke(needle, with: .color(.red), lineWidth: 3)
                let tip = pt(sv, R - 2)
                ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 6, y: tip.y - 6, width: 12, height: 12)), with: .color(.red))
                // Hub.
                let hub = R * 0.3
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)), with: .color(.black.opacity(0.9)))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)), with: .color(accent.opacity(0.7)), lineWidth: 1)
                ctx.draw(Text(Rotation.text(angle)).font(.system(size: hub * 0.42, weight: .bold).monospacedDigit()).foregroundColor(.white),
                         at: CGPoint(x: c.x, y: c.y - hub * 0.12))
                ctx.draw(Text(sv > 0.005 ? "CCW · pos" : (sv < -0.005 ? "CW · neg" : "start")).font(.system(size: hub * 0.24)).foregroundColor(accent),
                         at: CGPoint(x: c.x, y: c.y + hub * 0.42))
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let a = atan2(-(v.location.x - side / 2), -(v.location.y - side / 2)) * 180 / .pi
                        if let last = lastTouch { angle = Rotation.normalized(angle + Rotation.normalized(a - last)) }
                        lastTouch = a
                    }
                    .onEnded { _ in lastTouch = nil }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Protractor")
        .accessibilityValue(Rotation.text(angle))
        .accessibilityAdjustableAction { dir in
            angle = Rotation.normalized(angle + (dir == .increment ? 1 : -1))
        }
    }
}

/// Fine angle controls under the dial.
struct AngleControls: View {
    @Binding var angle: Double

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach([-10.0, -1, -0.1], id: \.self) { step in
                    Button(String(format: "%g°", step)) { angle = Rotation.normalized(angle + step) }
                }
                Button("0°") { angle = 0 }.bold()
                ForEach([0.1, 1.0, 10], id: \.self) { step in
                    Button(String(format: "+%g°", step)) { angle = Rotation.normalized(angle + step) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption.monospacedDigit())
            Text("\(Rotation.text(angle)) \(Rotation.direction(angle)) · \(Rotation.token(angle))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// Which overlays are shown; remembered between sessions.
struct OverlayToggles: View {
    @Binding var dimensions: Bool
    @Binding var ruler: Bool
    @Binding var protractor: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $dimensions) { Label("Sizes", systemImage: "ruler") }
            Toggle(isOn: $ruler) { Label("Scale", systemImage: "ruler.fill") }
            Toggle(isOn: $protractor) { Label("Protractor", systemImage: "dial.medium") }
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }
}

/// Full-screen 3D measuring view: the model with its sizes marked on it, a ruler beside it and a 360° protractor
/// to turn and orient it.
struct MeasureViewer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let scan: Scan

    @State private var rig: SampleRig?
    @State private var scene: SCNScene?
    @State private var failed = false
    @State private var angle = 0.0
    @AppStorage("overlay.dimensions") private var showDims = true
    @AppStorage("overlay.ruler") private var showRuler = true
    @AppStorage("overlay.protractor") private var showDial = true
    @State private var showSheet = false
    @State private var sheetAtMark = true
    @AppStorage(UnitPref.key) private var unitRaw = "mm"

    private var current: Scan { model.scans.first { $0.id == scan.id } ?? scan }

    /// The dial and the angle buttons count from the reference mark when there is one: the mark is 0° (3.7).
    private var zero: Double { (current.mark?.isTrusted ?? false) ? (current.mark?.angle ?? 0) : 0 }
    private var shown: Binding<Double> {
        Binding(get: { Rotation.normalized(angle - zero) }, set: { angle = Rotation.normalized($0 + zero) })
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if let scene {
                    SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                        .ignoresSafeArea(edges: .bottom)
                } else if failed {
                    ContentUnavailableView("Couldn't open the model", systemImage: "cube.transparent")
                } else {
                    ProgressView("Measuring the model…")
                }
                if let rig {
                    VStack(spacing: 10) {
                        OverlayToggles(dimensions: $showDims, ruler: $showRuler, protractor: $showDial)
                        UnitSegments().frame(maxWidth: 260)
                        if let m = current.mark {
                            HStack(spacing: 6) {
                                Image(systemName: "line.diagonal").foregroundStyle(.red)
                                Text(m.summary).font(.caption2)
                                Button("Face the mark (0°)") { angle = m.angle }.font(.caption2.bold())
                            }
                        }
                        HStack(alignment: .center, spacing: 12) {
                            ProtractorDial(angle: shown).frame(width: 150, height: 150)
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(rig.data.summary, id: \.self) { Text($0).font(.caption2) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        AngleControls(angle: shown)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(8)
                }
            }
            .navigationTitle(scan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let m = current.mark, m.isTrusted {
                            Button { sheetAtMark = true; showSheet = true } label: { Label("Sample sheet, 0° at the mark", systemImage: "photo.on.rectangle.angled") }
                        }
                        Button { sheetAtMark = false; showSheet = true } label: { Label("Sample sheet, 0° = this angle (\(Rotation.text(angle)))", systemImage: "photo.on.rectangle") }
                        Divider()
                        Button { model.setMark(scan, angle: angle) } label: { Label("The mark faces me now: set 0° here", systemImage: "scope") }
                        if current.mark != nil {
                            Button(role: .destructive) { model.clearMark(scan) } label: { Label("Forget the reference mark", systemImage: "xmark.circle") }
                        }
                        Divider()
                        Button { model.arSelection = [scan.id]; model.tab = .ar; dismiss() } label: { Label("Open in AR", systemImage: "arkit") }
                        Button { UIPasteboard.general.string = rig?.data.summary.joined(separator: "\n") } label: { Label("Copy sizes", systemImage: "doc.on.doc") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(rig == nil)
                }
            }
            .sheet(isPresented: $showSheet) {
                if let rig {
                    let m = current.mark
                    if sheetAtMark, let m, m.isTrusted {
                        SampleSheetView(scan: current, rig: rig, reference: m.angle, referenceIsMark: true)
                    } else {
                        SampleSheetView(scan: current, rig: rig, reference: angle, referenceIsMark: false)
                    }
                }
            }
        }
        .task {
            await load()
            if let m = current.mark, m.isTrusted { angle = m.angle }
        }
        .onChange(of: unitRaw) { _, _ in Task { await load() } }
        .onChange(of: angle) { _, a in rig?.angle = a }
        .onChange(of: showDims) { _, _ in applyToggles() }
        .onChange(of: showRuler) { _, _ in applyToggles() }
        .onChange(of: showDial) { _, _ in applyToggles() }
    }

    private func applyToggles() { rig?.show(dimensions: showDims, ruler: showRuler, protractor: showDial) }

    /// Builds the rig (again after a unit change, so labels and ruler use the new unit).
    private func load() async {
        guard let loaded = await SampleRig.load(scan) else { failed = true; return }
        let r = SampleRig(scene: loaded.0, data: loaded.1, name: scan.name)
        let root = SCNScene()
        root.rootNode.addChildNode(r.stage)
        root.background.contents = UIColor(white: 0.08, alpha: 1)
        r.show(dimensions: showDims, ruler: showRuler, protractor: showDial)
        r.angle = angle
        rig = r
        scene = root
    }
}
