import Foundation
import ImageIO
import CoreGraphics
import ScanMath

/// Sharpness check of capture photos. Object Capture runs the camera itself, so the app can't move the focus,
/// but it can spot photos that came out blurred (focus missed, phone moved, too close), warn at once, show the
/// spot as a gap on the ring, and keep those photos out of the model.
enum ShotQuality {
    /// A photo is blurry when its sharpness is below this share of the scan's median photo.
    static let blurRatio = 0.45
    /// At most this share of a scan's photos is ever set aside.
    static let maxSetAside = 0.15

    /// Photos in capture order (file creation time, then name).
    static func photos(in dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        let images = files.filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        let dated = images.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast) }
        return dated.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.lastPathComponent < $1.0.lastPathComponent }.map { $0.0 }
    }

    /// Sharpness of the middle of the photo, where the rock is, from an 800-pixel version of it.
    static func score(_ url: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 800,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        guard let crop = img.cropping(to: CGRect(x: w * 0.2, y: h * 0.2, width: w * 0.6, height: h * 0.6).integral) else { return nil }
        let cw = crop.width, ch = crop.height
        var pixels = [UInt8](repeating: 0, count: cw * ch)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))
            return true
        }
        guard drawn else { return nil }
        return ScanMath.sharpness(gray: pixels.map { Float($0) / 255 }, width: cw, height: ch)
    }

    /// Scores photos not in `known`, oldest first, at most `limit` per call. Files still being written fail to
    /// decode and are tried again next time.
    static func scoreNew(in dir: URL, known: Set<String>, limit: Int = 12) -> [String: Double] {
        var out: [String: Double] = [:]
        for url in photos(in: dir) where !known.contains(url.lastPathComponent) {
            if out.count >= limit { break }
            if let s = score(url) { out[url.lastPathComponent] = s }
        }
        return out
    }

    // MARK: Scores file

    static func scoresURL(_ scan: Scan) -> URL { scan.folderURL.appendingPathComponent("photo-sharpness.json") }

    static func loadScores(_ scan: Scan) -> [String: Double] {
        guard let data = try? Data(contentsOf: scoresURL(scan)) else { return [:] }
        return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
    }

    static func saveScores(_ scores: [String: Double], for scan: Scan) {
        if let data = try? JSONEncoder().encode(scores) { try? data.write(to: scoresURL(scan), options: .atomic) }
    }

    // MARK: Before the model is built

    /// Moves clearly blurred photos to Blurry/ so they don't soften the model. Needs at least 30 photos and
    /// never removes more than 15 %. Returns how many were moved.
    static func setAsideBlurry(_ scan: Scan) -> Int {
        let files = photos(in: scan.imagesURL)
        guard files.count >= 30 else { return 0 }
        var known = loadScores(scan)
        let scores = files.map { url -> Double in
            if let s = known[url.lastPathComponent] { return s }
            let s = score(url) ?? .nan
            known[url.lastPathComponent] = s
            return s
        }
        saveScores(known.filter { $0.value.isFinite }, for: scan)
        let bad = ScanMath.blurryIndices(scores, relative: blurRatio, maxFraction: maxSetAside)
        guard !bad.isEmpty else { return 0 }
        let fm = FileManager.default
        try? fm.createDirectory(at: scan.blurryURL, withIntermediateDirectories: true)
        var moved = 0
        for i in bad {
            let dest = scan.blurryURL.appendingPathComponent(files[i].lastPathComponent)
            if (try? fm.moveItem(at: files[i], to: dest)) != nil { moved += 1 }
        }
        return moved
    }

    /// Puts set-aside photos back, for a retry when a build with fewer photos fails.
    static func restoreBlurry(_ scan: Scan) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: scan.blurryURL, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.moveItem(at: url, to: scan.imagesURL.appendingPathComponent(url.lastPathComponent))
        }
        try? fm.removeItem(at: scan.blurryURL)
    }
}
