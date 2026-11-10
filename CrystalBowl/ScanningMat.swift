import SwiftUI
import UIKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import ScanMath

/// The printable scanning mat (3.10): a 1:1 graph-paper work area with a degree ring, lettered tracking markers and
/// geologist's field scales (10 cm and 4 in, black and white blocks). Made by tools/make_mat.py; vector PDFs in
/// the app bundle, A4 and US Letter, light (for dark or grey rocks) and dark (for pale rocks).
enum ScanningMat {
    enum Paper: String, CaseIterable, Identifiable {
        case a4 = "A4", letter = "Letter"
        var id: String { rawValue }
        static var local: Paper { MatAdvisor.paper(region: Locale.current.region?.identifier) == "Letter" ? .letter : .a4 }
    }

    enum Tone: String, CaseIterable, Identifiable {
        case light, dark
        var id: String { rawValue }
        var title: String { self == .light ? "Light (dark or grey rocks)" : "Dark (white or pale rocks)" }
    }

    static var guideURL: URL? { Bundle.main.url(forResource: "CrystalBowl_scanning_mat_guide", withExtension: "pdf") }

    static func url(_ paper: Paper, _ tone: Tone) -> URL? {
        Bundle.main.url(forResource: "CrystalBowl_scanning_mat_\(paper.rawValue)_\(tone.rawValue)", withExtension: "pdf")
    }
}

/// Preview, print (at 100 %) or share the mat.
struct ScanningMatView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var paper = ScanningMat.Paper.local
    @State private var tone: ScanningMat.Tone
    @State private var advice: String?
    @State private var showCamera = false
    @State private var showGuide = false

    /// `suggested`: the mat the app recommends for the rock in hand (from an earlier scan), with why.
    init(suggested: MatAdvisor.Advice? = nil) {
        _tone = State(initialValue: suggested?.tone == .dark ? .dark : .light)
        _advice = State(initialValue: suggested.map { "Recommended: the \($0.tone == .dark ? "dark" : "light") mat. " + $0.reason })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Print it, lay it flat and place the rock or the pieces inside the grid, a finger-width apart. Its scale bars show in the photos, and the app keeps a few of those photos as scale photos, like a field photo with a hammer beside the rock.")
                        .font(.footnote).foregroundStyle(.secondary)
                    // Which mat: the guide, and the app's own check.
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Which mat?", systemImage: "questionmark.circle").font(.headline)
                        HStack(alignment: .top, spacing: 10) {
                            MatSwatch(dark: false)
                            Text("**Light mat** for dark, grey, brown, red, green or black rock: shale, mudstone, basalt, coal, dark sandstone, most cores and plugs. The default when unsure.")
                                .font(.footnote)
                        }
                        HStack(alignment: .top, spacing: 10) {
                            MatSwatch(dark: true)
                            Text("**Dark mat** for white, cream or very pale rock: limestone, chalk, white sandstone, quartzite, gypsum, anhydrite, salt, marble.")
                                .font(.footnote)
                        }
                        Button { showCamera = true } label: {
                            Label("Check my rock with the camera", systemImage: "camera.viewfinder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        if let advice {
                            Label(advice, systemImage: "checkmark.seal.fill").font(.footnote).foregroundStyle(.green)
                        }
                        if let g = ScanningMat.guideURL {
                            Button { showGuide = true } label: { Label("Full guide (PDF, one page)", systemImage: "doc.text") }
                                .sheet(isPresented: $showGuide) {
                                    NavigationStack {
                                        MatPreview(url: g).ignoresSafeArea(edges: .bottom)
                                            .navigationTitle("Scanning mat guide").navigationBarTitleDisplayMode(.inline)
                                            .toolbar {
                                                ToolbarItem(placement: .confirmationAction) { Button("Done") { showGuide = false } }
                                                ToolbarItem(placement: .primaryAction) { ShareLink(item: g) { Image(systemName: "square.and.arrow.up") } }
                                            }
                                    }
                                }
                        }
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    Picker("Paper", selection: $paper) {
                        ForEach(ScanningMat.Paper.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Tone", selection: $tone) {
                        ForEach(ScanningMat.Tone.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let u = ScanningMat.url(paper, tone) {
                        MatPreview(url: u).frame(height: 460).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        HStack {
                            Button { printMat(u) } label: { Label("Print", systemImage: "printer") }
                                .buttonStyle(.borderedProminent)
                            ShareLink(item: u) { Label("Share the PDF", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        Text("The mat is missing from this build.").foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Print at 100 % (“Actual size”), never “Fit to page”. Then check the line at the top measures exactly 100 mm.", systemImage: "ruler")
                        Label("Matte paper; keep it flat and out of glare. Light mat for dark or grey rocks, dark mat for white or pale ones.", systemImage: "sun.max")
                        Label("Set the rock's reference mark facing 0° on the ring, so the photos record which side faced the X-ray source.", systemImage: "scope")
                        Label("Keep pieces inside the grid and apart; the lettered squares help the phone keep track as you walk round.", systemImage: "square.grid.3x3")
                    }
                    .font(.footnote)
                }
                .padding()
            }
            .navigationTitle("Scanning mat")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showCamera) {
                CameraShot { img in
                    showCamera = false
                    guard let img, let m = RockTone.measure(img) else { return }
                    let a = MatAdvisor.advise(rockLuma: m.rock)
                    tone = a.tone == .dark ? .dark : .light
                    advice = "Use the \(a.tone == .dark ? "dark" : "light") mat. " + a.reason
                    AppLog.info("mat", String(format: "Camera check: rock brightness %.2f, surroundings %.2f, %@ mat", m.rock, m.surround, a.tone.rawValue))
                }
                .ignoresSafeArea()
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func printMat(_ u: URL) {
        let c = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = u.deletingPathExtension().lastPathComponent
        c.printInfo = info
        c.printingItem = u // a PDF prints at its own page size: 1:1 when the printer is set to 100 %
        c.present(animated: true)
    }
}

private struct MatPreview: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePage
        v.backgroundColor = .secondarySystemBackground
        v.document = PDFDocument(url: url)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
    }
}

/// Scale photos (3.10): a few of the capture's own photos, spread round the first pass and the sharpest near each
/// spot, kept as JPEGs with a caption. With the scanning mat under the rock its scale bars and grid show in them,
/// the way a field photo has a hammer beside the rock. They go to Drive in model/scale-photos/.
enum ScalePhotos {
    static func folder(_ scan: Scan) -> URL { scan.exportsURL.appendingPathComponent("scale-photos", isDirectory: true) }

    static func files(_ scan: Scan) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder(scan), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Picks `count` photos from `dir` and writes them. Runs off the main thread.
    @discardableResult
    static func make(scan: Scan, from dir: URL, side: Int, scores: [String: Double], count: Int = 4) -> [URL] {
        let photos = ShotQuality.photos(in: dir)
        guard !photos.isEmpty else { return [] }
        let out = folder(scan)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Old ones for this side go (a side scanned again).
        for f in files(scan) where f.lastPathComponent.contains("_side\(side)_") { try? FileManager.default.removeItem(at: f) }
        // Spots spread round the first pass (the first ~60 % of the photos), the sharpest within ±3 of each.
        let span = Swift.max(1, Int(Double(photos.count) * 0.6))
        var chosen: [URL] = []
        for k in 0..<Swift.min(count, photos.count) {
            let centre = Int((Double(k) + 0.5) / Double(count) * Double(span))
            let lo = Swift.max(0, centre - 3), hi = Swift.min(photos.count - 1, centre + 3)
            let pick = (lo...hi).max { (scores[photos[$0].lastPathComponent] ?? 0) < (scores[photos[$1].lastPathComponent] ?? 0) } ?? centre
            if !chosen.contains(photos[pick]) { chosen.append(photos[pick]) }
        }
        let date = scan.created.formatted(date: .abbreviated, time: .shortened)
        var written: [URL] = []
        for (i, src) in chosen.enumerated() {
            guard let img = load(src, maxPixel: 2400) else { continue }
            let caption = "\(scan.name) · side \(side) · \(date) · scale: the mat's 10 cm bar (1 cm blocks) and 1 cm grid"
            let stamped = stamp(img, caption)
            let u = out.appendingPathComponent("\(scan.fileStem)_scale-photo_side\(side)_\(i + 1).jpg")
            if let data = stamped.jpegData(compressionQuality: 0.86), (try? data.write(to: u, options: .atomic)) != nil {
                written.append(u)
            }
        }
        return written
    }

    static func load(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary).map { UIImage(cgImage: $0) }
    }

    /// The photo with a caption strip below it (nothing is drawn over the photo itself).
    static func stamp(_ img: UIImage, _ caption: String) -> UIImage {
        let w = img.size.width
        let fontSize = Swift.max(18, w / 70)
        let strip = fontSize * 2.2
        let size = CGSize(width: w, height: img.size.height + strip)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            img.draw(in: CGRect(origin: .zero, size: img.size))
            let z = SampleSheet.fitted(caption, size: fontSize, weight: .semibold, maxWidth: w - 2 * fontSize)
            SampleSheet.text(caption, at: CGPoint(x: fontSize, y: img.size.height + (strip - z * 1.2) / 2), size: z, weight: .semibold)
        }
    }
}

/// Settings: the scanning mat.
struct ScanningMatSettingsSection: View {
    @State private var show = false
    var body: some View {
        Section {
            Button { show = true } label: { Label("Scanning mat to print (PDF, 1:1)…", systemImage: "printer") }
        } footer: {
            Text("Graph paper at true size with 10 cm and 4 in field scales and a degree ring. Lay the rock or the pieces on it: they stand out, the phone keeps track, and the scale photos show the real size.")
        }
        .sheet(isPresented: $show) { ScanningMatView() }
    }
}

/// The scale photos of a scan: tap one to open it full screen.
struct ScalePhotosSection: View {
    let scan: Scan
    let open: ([GalleryItem], URL) -> Void

    var body: some View {
        let files = ScalePhotos.files(scan)
        if !files.isEmpty {
            let items = files.map { GalleryItem(url: $0, title: "Scale photo, side " + (($0.lastPathComponent.contains("_side2_")) ? "2" : "1")) }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(items) { item in
                            Button { open(items, item.url) } label: {
                                SectionThumb(url: item.url, maxPixel: 320)
                                    .frame(width: 120, height: 90)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                ShareLink(items: files) { Label("Share the scale photos", systemImage: "square.and.arrow.up") }
            } header: {
                Text("Scale photos")
            } footer: {
                Text("Photos from the scan with the mat's scale bars in view, kept automatically. Google Drive › model/scale-photos.")
            }
        }
    }
}

private struct MatSwatch: View {
    let dark: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(dark ? Color(red: 0.12, green: 0.16, blue: 0.23) : Color(red: 0.89, green: 0.95, blue: 0.96))
            Path { p in
                for i in 1..<4 {
                    let d = CGFloat(i) * 10
                    p.move(to: CGPoint(x: d, y: 0))
                    p.addLine(to: CGPoint(x: d, y: 40))
                    p.move(to: CGPoint(x: 0, y: d))
                    p.addLine(to: CGPoint(x: 40, y: d))
                }
            }
            .stroke(dark ? Color(red: 0.55, green: 0.72, blue: 0.85) : Color(red: 0.24, green: 0.55, blue: 0.67), lineWidth: 0.7)
            Circle().fill(dark ? Color(white: 0.87) : Color(white: 0.33)).frame(width: 18, height: 18)
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

/// How light a rock is in a photo: the middle of the frame (where the rock is when the phone points at it)
/// against the frame's edges (what it lies on). Median luma 0–1.
enum RockTone {
    static func pixels(_ img: UIImage, side n: Int = 96) -> [UInt8]? {
        guard let cg = img.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return ok ? px : nil
    }

    static func luma(_ p: [UInt8], _ i: Int) -> Double {
        (0.299 * Double(p[i * 4]) + 0.587 * Double(p[i * 4 + 1]) + 0.114 * Double(p[i * 4 + 2])) / 255
    }

    static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[s.count / 2]
    }

    static func measure(_ img: UIImage) -> (rock: Double, surround: Double)? {
        let n = 96
        guard let p = pixels(img, side: n) else { return nil }
        var mid: [Double] = [], edge: [Double] = []
        let a = Int(Double(n) * 0.32), b = Int(Double(n) * 0.68), e = Int(Double(n) * 0.12)
        for y in 0..<n {
            for x in 0..<n {
                let l = luma(p, y * n + x)
                if (a..<b).contains(x) && (a..<b).contains(y) {
                    mid.append(l)
                } else if x < e || x >= n - e || y < e || y >= n - e {
                    edge.append(l)
                }
            }
        }
        return (median(mid), median(edge))
    }

    /// Median brightness of a rendered surface (the unrolled side), its white or green background left out.
    static func surface(_ img: UIImage) -> Double? {
        let n = 128
        guard let p = pixels(img, side: n) else { return nil }
        var ls: [Double] = []
        for i in 0..<(n * n) {
            let r = p[i * 4], g = p[i * 4 + 1], b = p[i * 4 + 2]
            if r > 247 && g > 247 && b > 247 { continue }
            if g > 230 && r < 40 && b < 40 { continue }
            ls.append(luma(p, i))
        }
        return ls.count > 200 ? median(ls) : nil
    }
}

/// One photo from the camera.
struct CameraShot: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(_ d: @escaping (UIImage?) -> Void) { done = d }
        func imagePickerController(_ p: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ p: UIImagePickerController) { done(nil) }
    }
}

/// On a scan's page: which mat suits this rock, a warning when the rock and what it lay on looked alike, and
/// one when the rock is too big for the mat (3.11).
struct MatAdviceSection: View {
    let scan: Scan
    @State private var show = false

    var body: some View {
        let advice = scan.rockLuma.map { MatAdvisor.advise(rockLuma: $0) }
        let size = MatAdviceSection.footprintMM(scan)
        let paper = MatAdvisor.paper(region: Locale.current.region?.identifier)
        let tooBig = size.map { !MatAdvisor.fits(lengthMM: $0.0, widthMM: $0.1, paper: paper) } ?? false
        if advice != nil || scan.matTip != nil || tooBig {
            Section {
                if let tip = scan.matTip {
                    Label(tip, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                }
                if let a = advice {
                    Label("Mat for this rock: \(a.tone == .dark ? "dark" : "light"). " + a.reason, systemImage: "square.grid.3x3")
                        .font(.footnote)
                }
                if tooBig, let s = size {
                    Label(String(format: "The rock is about %.0f × %.0f mm, bigger than the %@ mat's work area: lay it diagonally or tape two sheets side by side.", s.0, s.1, paper),
                          systemImage: "arrow.up.left.and.arrow.down.right").font(.footnote)
                }
                Button { show = true } label: { Label("Scanning mat to print", systemImage: "printer") }
            } header: {
                Text("Scanning mat")
            }
            .sheet(isPresented: $show) { ScanningMatView(suggested: advice) }
        }
    }

    /// The two longest sizes (a rock lies on its largest face), true mm.
    static func footprintMM(_ scan: Scan) -> (Double, Double)? {
        guard let st = scan.stats else { return nil }
        let k = scan.scaleFactor
        let d = [st.axisA * k, st.axisB * k, st.axisC * k].sorted(by: >)
        return (d[0], d[1])
    }
}

/// Under "Start new scan": the mat for this Sample ID when it was scanned before, else a pointer to the guide.
struct MatHint: View {
    @EnvironmentObject var model: AppModel
    let sampleName: String
    @State private var show = false

    var body: some View {
        let key = sampleName.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let known = key.isEmpty ? nil : model.scans.filter { $0.sampleKey == key && $0.rockLuma != nil }.max { $0.created < $1.created }
        let advice = known?.rockLuma.map { MatAdvisor.advise(rockLuma: $0) }
        Button { show = true } label: {
            if let a = advice {
                Label("Use the \(a.tone == .dark ? "dark" : "light") scanning mat: " + a.reason, systemImage: "square.grid.3x3.fill")
                    .font(.footnote)
            } else {
                Label("Scanning mat: light for dark or grey rock, dark for pale rock. Tap to print or to check the rock with the camera.",
                      systemImage: "square.grid.3x3")
                    .font(.footnote)
            }
        }
        .sheet(isPresented: $show) { ScanningMatView(suggested: advice) }
    }
}
