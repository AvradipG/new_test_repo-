import Foundation
import SwiftUI
import UIKit
import Photos
import ImageIO

// MARK: Photos

/// Adds PNG files to the Photos library as they are (PNG stays PNG, file name kept). Needs only add-only access.
enum PhotoSaver {
    static let modeKey = "photos.sections"
    /// "every" = each slice and the all-in-one picture, "one" = only the all-in-one picture, "off".
    static var mode: String { UserDefaults.standard.string(forKey: modeKey) ?? "every" }
    static let deniedCode = 22

    static func save(_ urls: [URL]) async throws -> Int {
        guard !urls.isEmpty else { return 0 }
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "CrystalBowl", code: deniedCode, userInfo: [NSLocalizedDescriptionKey:
                "Crystal Bowl may not add pictures to Photos. Turn it on in Settings › Apps › Crystal Bowl › Photos."])
        }
        var saved = 0
        for start in stride(from: 0, to: urls.count, by: 40) {
            let chunk = Array(urls[start..<min(urls.count, start + 40)])
            try await PHPhotoLibrary.shared().performChanges {
                for url in chunk {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = url.lastPathComponent
                    request.addResource(with: .photo, fileURL: url, options: options)
                }
            }
            saved += chunk.count
        }
        return saved
    }
}

extension AppModel {
    static let photosPendingKey = "photos.pending"

    /// Saves files to Photos now (a button press) and says how it went.
    func saveToPhotos(_ urls: [URL], what: String) {
        Task {
            do {
                let n = try await PhotoSaver.save(urls)
                AppLog.info("photos", "Saved \(n) PNG(s) to Photos: \(what)")
                photosNote = "Saved \(what) to Photos (\(n) PNG\(n == 1 ? "" : "s"))."
            } catch {
                AppLog.error("photos", "Saving to Photos failed: \(what)", error)
                photosNote = "Couldn't save to Photos: \(error.localizedDescription)"
            }
        }
    }

    /// New stacks wait in a list until they are in Photos, so a build that ends off screen still gets there.
    func queueSectionsForPhotos(_ scan: Scan, _ series: [SectionSeries]) {
        guard PhotoSaver.mode != "off", !series.isEmpty else { return }
        var pending = UserDefaults.standard.stringArray(forKey: Self.photosPendingKey) ?? []
        for s in series where !pending.contains("\(scan.id)|\(s.id)") { pending.append("\(scan.id)|\(s.id)") }
        UserDefaults.standard.set(pending, forKey: Self.photosPendingKey)
        Task { await flushPhotosPending() }
    }

    func flushPhotosPending() async {
        guard !savingToPhotos else { return }
        var pending = UserDefaults.standard.stringArray(forKey: Self.photosPendingKey) ?? []
        guard !pending.isEmpty else { return }
        let mode = PhotoSaver.mode
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if mode == "off" || status == .denied || status == .restricted {
            if mode != "off" { AppLog.warn("photos", "Photos access is off, \(pending.count) stack(s) not saved there") }
            UserDefaults.standard.removeObject(forKey: Self.photosPendingKey)
            return
        }
        // iOS can only ask for permission while the app is on screen.
        if status == .notDetermined && UIApplication.shared.applicationState != .active { return }
        savingToPhotos = true
        defer { savingToPhotos = false }
        reload()
        while let key = pending.first {
            let parts = key.components(separatedBy: "|")
            if parts.count == 2, let scan = scans.first(where: { $0.id == parts[0] }),
               let s = scan.sections?.first(where: { $0.id == parts[1] }) {
                var urls = mode == "every" ? s.imageURLs(in: scan) : []
                let one = s.allInOneURL(in: scan)
                if FileManager.default.fileExists(atPath: one.path) { urls.append(one) }
                do {
                    let n = try await PhotoSaver.save(urls)
                    AppLog.info("photos", "Saved \(n) PNG(s) of \(s.folderName) to Photos", scan: scan)
                    photosNote = "Saved \(n) cross-section PNG\(n == 1 ? "" : "s") of \(scan.name) to Photos."
                } catch {
                    AppLog.error("photos", "Saving \(s.folderName) to Photos failed", error, scan: scan)
                    photosNote = "Couldn't save to Photos: \(error.localizedDescription)"
                    if (error as NSError).code != PhotoSaver.deniedCode { return } // try again next time
                }
            }
            pending.removeFirst()
            UserDefaults.standard.set(pending, forKey: Self.photosPendingKey)
        }
    }

    /// Sends the app log soon after something goes wrong, without waiting for the next scan upload.
    func scheduleLogUpload(after seconds: Double = 45) {
        guard !logUploadScheduled else { return }
        logUploadScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            logUploadScheduled = false
            await uploadAppLog()
        }
    }
}

// MARK: Thumbnails

enum SectionThumbs {
    private static let cache = NSCache<NSString, UIImage>()

    /// A small copy of a slice PNG, read without decoding the full picture.
    static func image(_ url: URL, maxPixel: Int) -> UIImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)|\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key)
        return image
    }
}

struct SectionThumb: View {
    let url: URL
    var maxPixel = 320
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: url) {
            let u = url, m = maxPixel
            image = await Task.detached { SectionThumbs.image(u, maxPixel: m) }.value
        }
    }
}

// MARK: Zoomable picture

/// Pinch to zoom, drag to move, double-tap to zoom in or back out, single tap for `onTap`.
struct ZoomableImage: UIViewRepresentable {
    let url: URL
    var onTap: () -> Void = {}

    func makeUIView(context: Context) -> ZoomImageView { ZoomImageView(frame: .zero) }
    func updateUIView(_ view: ZoomImageView, context: Context) {
        view.onTap = onTap
        view.show(url)
    }
}

final class ZoomImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var shown: URL?
    var onTap: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 8
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        addGestureRecognizer(single)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ url: URL) {
        guard url != shown else { return }
        shown = url
        setZoomScale(1, animated: false)
        imageView.image = UIImage(contentsOfFile: url.path)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= 1.0001 && imageView.frame.size != bounds.size {
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func singleTapped() { onTap() }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
            return
        }
        let p = g.location(in: imageView)
        let w = bounds.width / 3.5, h = bounds.height / 3.5
        zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }
}

// MARK: Full-screen slice viewer

struct SectionViewer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let scan: Scan
    let series: SectionSeries
    @Binding var index: Int
    @State private var chrome = true

    var body: some View {
        let n = series.rows.count
        let i = max(0, min(index, n - 1))
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(0..<n, id: \.self) { k in
                    ZoomableImage(url: series.imageURL(in: scan, index: k)) {
                        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
                    }
                    .ignoresSafeArea()
                    .tag(k)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chrome && n > 0 {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.title3.weight(.semibold)).padding(8)
                        }
                        .accessibilityLabel("Close")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(series.title) · slice \(i + 1) of \(n)").font(.headline)
                            Text((series.isHeightProfile ? "height " : "depth ") + L(series.rows[i].depthMM))
                                .font(.caption.monospacedDigit())
                        }
                        Spacer()
                        SectionExportMenu(scan: scan, series: series, index: i, compact: true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.6))
                    Spacer()
                    VStack(spacing: 4) {
                        Text(series.rows[i].measurementText)
                            .font(.caption.monospacedDigit())
                        if let note = model.photosNote {
                            Text(note).font(.caption).foregroundStyle(.green)
                        }
                        Text("Pinch or double-tap to zoom · swipe for the next slice · tap to hide this")
                            .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.6))
                }
                .foregroundStyle(.white)
                .transition(.opacity)
            }
        }
        .statusBarHidden(!chrome)
        .onAppear { model.photosNote = nil }
    }
}

// MARK: All slices as a grid

struct SectionGridView: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    let series: SectionSeries
    let start: Int
    var onIndex: (Int) -> Void = { _ in }
    @State private var index: Int?
    @State private var viewer: SectionViewerTarget?

    var body: some View {
        let current = index ?? start
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 8) {
                ForEach(0..<series.rows.count, id: \.self) { k in
                    Button {
                        select(k)
                        viewer = SectionViewerTarget(scan: scan, series: series, index: k) { select($0) }
                    } label: {
                        VStack(spacing: 3) {
                            SectionThumb(url: series.imageURL(in: scan, index: k))
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(k == current ? Color.accentColor : .clear, lineWidth: 2))
                            Text("#\(k + 1) · " + L(series.rows[k].depthMM))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .navigationTitle("\(series.title) · \(series.rows.count) slices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SectionExportMenu(scan: scan, series: series, index: current, compact: true)
            }
        }
        .fullScreenCover(item: $viewer) { target in
            SectionViewerHost(target: target).environmentObject(model)
        }
    }

    private func select(_ k: Int) {
        index = k
        onIndex(k)
    }
}

// MARK: Export menu

/// Share or save one slice, every slice as its own PNG, or all slices in one PNG.
struct SectionExportMenu: View {
    @EnvironmentObject var model: AppModel
    let scan: Scan
    let series: SectionSeries
    let index: Int
    var compact = false
    @State private var oneMade = 0

    var body: some View {
        let one = series.allInOneURL(in: scan)
        let hasOne = oneMade >= 0 && FileManager.default.fileExists(atPath: one.path)
        let slices = series.imageURLs(in: scan)
        let this = series.imageURL(in: scan, index: max(0, min(index, series.rows.count - 1)))
        Menu {
            Section("Share as PNG") {
                ShareLink(item: this) { Label("This slice (\(index + 1))", systemImage: "photo") }
                if !slices.isEmpty {
                    ShareLink(items: slices) { Label("Every slice, \(slices.count) separate PNGs", systemImage: "photo.stack") }
                }
                if hasOne {
                    ShareLink(item: one) { Label("All slices in one PNG", systemImage: "square.grid.3x3") }
                }
            }
            Section("Save to Photos") {
                Button { model.saveToPhotos([this], what: "slice \(index + 1)") } label: {
                    Label("This slice", systemImage: "photo.badge.plus")
                }
                if !slices.isEmpty {
                    Button { model.saveToPhotos(slices, what: "\(slices.count) slices") } label: {
                        Label("Every slice (\(slices.count))", systemImage: "photo.stack")
                    }
                }
                if hasOne {
                    Button { model.saveToPhotos([one], what: "the all-in-one picture") } label: {
                        Label("All slices in one picture", systemImage: "square.grid.3x3")
                    }
                }
            }
        } label: {
            if compact {
                Image(systemName: "square.and.arrow.up").font(.title3).padding(6)
            } else {
                Label("Export PNG (this slice, every slice or all in one)", systemImage: "square.and.arrow.up")
            }
        }
        .accessibilityLabel("Export PNG")
        .task(id: series.id) {
            // Stacks cut before 3.2 get their all-in-one picture the first time they are shown.
            guard !FileManager.default.fileExists(atPath: one.path), !slices.isEmpty else { return }
            let s = series, sc = scan
            let made = await Task.detached { (try? CrossSectionMaker.makeAllInOne(s, in: sc)) != nil }.value
            if made {
                oneMade += 1
                Task { await model.syncAllPending() }
            }
        }
    }
}

// MARK: Opening the viewer from a list

/// What the scan page opens full screen; `onIndex` carries the slice the viewer ended on back to the panel.
struct SectionViewerTarget: Identifiable {
    let id = UUID()
    let scan: Scan
    let series: SectionSeries
    let index: Int
    var onIndex: (Int) -> Void = { _ in }
}

struct SectionViewerHost: View {
    let target: SectionViewerTarget
    @State private var index: Int

    init(target: SectionViewerTarget) {
        self.target = target
        _index = State(initialValue: target.index)
    }

    var body: some View {
        SectionViewer(scan: target.scan, series: target.series, index: $index)
            .onChange(of: index) { _, k in target.onIndex(k) }
    }
}
