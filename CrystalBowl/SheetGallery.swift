import Foundation
import SwiftUI
import UIKit

/// One picture of the sample sheet: a whole sheet, a single view or the unrolled side (3.7).
struct GalleryItem: Identifiable, Hashable {
    let url: URL
    let title: String
    var id: String { url.path }
}

struct GalleryTarget: Identifiable {
    let id = UUID()
    let items: [GalleryItem]
    let start: Int
}

enum SheetPictures {
    /// The sample sheet's pictures in reading order: sheets, side views 0° → +90° → 180° → −90°, top, bottom,
    /// unrolled side.
    static func items(_ scan: Scan) -> [GalleryItem] {
        let dir = scan.exportsURL.appendingPathComponent("sheet", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" }
        func rank(_ u: URL) -> Double {
            let n = u.lastPathComponent
            if n.contains("sample-sheet-scientific") { return 0 }
            if n.contains("sample-sheet-clean") { return 1 }
            if n.contains("_view-side") {
                // 0°, +90°, 180°, −90° (= 270°) in that order.
                var a = (sideAngle(n) ?? 0).truncatingRemainder(dividingBy: 360)
                if a < 0 { a += 360 }
                return 2 + a / 1000
            }
            if n.contains("_view-top") { return 4 }
            if n.contains("_view-bottom") { return 5 }
            if n.contains("_unrolled_") { return 6 }
            return 7
        }
        return files.sorted { rank($0) < rank($1) }.map { GalleryItem(url: $0, title: title($0.lastPathComponent, scan: scan)) }
    }

    /// The view's angle from a file name such as `…_view-sidepos90_…` or `…_view-sideneg90p00_…`.
    static func sideAngle(_ name: String) -> Double? {
        guard let r = name.range(of: "_view-side") else { return nil }
        let rest = name[r.upperBound...]
        let token = rest.prefix { $0 != "_" }
        var s = String(token)
        var sign = 1.0
        if s.hasPrefix("pos") { s.removeFirst(3) } else if s.hasPrefix("neg") { s.removeFirst(3); sign = -1 }
        s = s.replacingOccurrences(of: "p", with: ".")
        return Double(s).map { $0 * sign }
    }

    static func title(_ name: String, scan: Scan) -> String {
        if name.contains("sample-sheet-scientific") { return "Scientific sample sheet" }
        if name.contains("sample-sheet-clean") { return "Clean sample sheet" }
        if name.contains("_view-top") { return "Top (seen from above)" }
        if name.contains("_view-bottom") { return "Bottom (seen from below)" }
        if name.contains("_unrolled_") { return "Unrolled side (360°)" }
        if let a = sideAngle(name) {
            if a == 0 { return (scan.mark?.isTrusted ?? false) ? "0° · mark facing you" : "0°" }
            return String(format: "%@%.0f° from 0°", a > 0 ? "+" : (a < 0 ? "−" : ""), abs(a))
        }
        return name
    }
}

/// Full screen: pinch or double-tap to zoom, swipe to the next picture, share or save each one.
struct GalleryViewer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: GalleryTarget
    @State private var index: Int
    @State private var chrome = true

    init(target: GalleryTarget) {
        self.target = target
        _index = State(initialValue: target.start)
    }

    var body: some View {
        let n = target.items.count
        let i = max(0, min(index, n - 1))
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(target.items.enumerated()), id: \.offset) { k, item in
                    ZoomableImage(url: item.url) { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } }
                        .ignoresSafeArea()
                        .tag(k)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            if chrome && n > 0 {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)).padding(8) }
                            .accessibilityLabel("Close")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(target.items[i].title).font(.headline)
                            Text("\(i + 1) of \(n)").font(.caption.monospacedDigit())
                        }
                        Spacer()
                        Menu {
                            ShareLink(item: target.items[i].url) { Label("Share this picture (PNG)", systemImage: "square.and.arrow.up") }
                            ShareLink(items: target.items.map(\.url)) { Label("Share all \(n) pictures", systemImage: "photo.stack") }
                            Button { model.saveToPhotos([target.items[i].url], what: target.items[i].title) } label: {
                                Label("Save this picture to Photos", systemImage: "photo.badge.plus")
                            }
                        } label: { Image(systemName: "square.and.arrow.up").font(.title3).padding(6) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.6))
                    Spacer()
                    VStack(spacing: 4) {
                        if let note = model.photosNote { Text(note).font(.caption).foregroundStyle(.green) }
                        Text("Pinch or double-tap to zoom · swipe for the next picture · tap to hide this")
                            .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.6))
                }
                .foregroundStyle(.white)
            }
        }
        .statusBarHidden(!chrome)
        .onAppear { model.photosNote = nil }
    }
}
