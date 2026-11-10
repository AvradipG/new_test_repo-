import SwiftUI
import UIKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// The printable scanning mat (3.10): a 1:1 graph-paper work area with a degree ring, lettered tracking markers and
/// geologist's field scales (10 cm and 4 in, black and white blocks). Made by tools/make_mat.py; vector PDFs in
/// the app bundle, A4 and US Letter, light (for dark or grey rocks) and dark (for pale rocks).
enum ScanningMat {
    enum Paper: String, CaseIterable, Identifiable {
        case a4 = "A4", letter = "Letter"
        var id: String { rawValue }
        static var local: Paper {
            let r = Locale.current.region?.identifier ?? ""
            return ["US", "CA", "MX", "PH", "CL", "CO"].contains(r) ? .letter : .a4
        }
    }

    enum Tone: String, CaseIterable, Identifiable {
        case light, dark
        var id: String { rawValue }
        var title: String { self == .light ? "Light (dark or grey rocks)" : "Dark (white or pale rocks)" }
    }

    static func url(_ paper: Paper, _ tone: Tone) -> URL? {
        Bundle.main.url(forResource: "CrystalBowl_scanning_mat_\(paper.rawValue)_\(tone.rawValue)", withExtension: "pdf")
    }
}

/// Preview, print (at 100 %) or share the mat.
struct ScanningMatView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var paper = ScanningMat.Paper.local
    @State private var tone = ScanningMat.Tone.light

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Print it, lay it flat and place the rock or the pieces inside the grid, a finger-width apart. Its scale bars show in the photos, and the app keeps a few of those photos as scale photos, like a field photo with a hammer beside the rock.")
                        .font(.footnote).foregroundStyle(.secondary)
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
