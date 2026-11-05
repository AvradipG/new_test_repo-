import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Something the user picked or recorded: a photo, or a walkthrough video to pull stills from.
enum PickedMedia {
    case image(UIImage)
    case movie(URL)
}

/// A video handed over by the photo picker, copied into the temporary folder.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

enum ImageTools {
    /// Longest side sent to Claude (its recommended maximum).
    static let maxSide: CGFloat = 1568

    /// Upright JPEG no bigger than `maxSide`.
    static func jpeg(_ image: UIImage, longestSide: CGFloat = ImageTools.maxSide) -> Data? {
        let scale = min(1, longestSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.jpegData(compressionQuality: 0.85)
    }

    /// Sharpness (variance of a Laplacian on a small greyscale copy), same idea as Crystal Bowl's blur check.
    static func sharpness(_ cg: CGImage) -> Double {
        let w = 256, h = max(1, Int(Double(cg.height) / Double(cg.width) * 256))
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok, w > 2, h > 2 else { return 0 }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Double(px[y * w + x]) * 4
                let l = c - Double(px[y * w + x - 1]) - Double(px[y * w + x + 1])
                    - Double(px[(y - 1) * w + x]) - Double(px[(y + 1) * w + x])
                sum += l
                sumSq += l * l
                n += 1
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    /// Pulls `count` stills from a walkthrough video: the sharpest frame from each of `count` equal stretches.
    static func frames(from url: URL, count: Int = 6) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        var out: [Data] = []
        let tries = 3
        for i in 0..<count {
            var best: (CGImage, Double)?
            for j in 0..<tries {
                let t = duration * (Double(i) + (Double(j) + 0.5) / Double(tries)) / Double(count)
                guard let frame = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
                let s = sharpness(frame)
                if best == nil || s > best!.1 { best = (frame, s) }
            }
            if let best, let data = jpeg(UIImage(cgImage: best.0)) { out.append(data) }
        }
        return out
    }

    /// Loads picker selections as photos or videos.
    static func load(_ items: [PhotosPickerItem]) async -> [PickedMedia] {
        var out: [PickedMedia] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) { out.append(.movie(movie.url)) }
            } else if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                out.append(.image(img))
            }
        }
        return out
    }
}

/// The system camera for one photo or a short walkthrough video.
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (PickedMedia) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoMaximumDuration = 30
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                try? FileManager.default.copyItem(at: url, to: dest)
                parent.onPick(.movie(dest))
            } else if let image = info[.originalImage] as? UIImage {
                parent.onPick(.image(image))
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
