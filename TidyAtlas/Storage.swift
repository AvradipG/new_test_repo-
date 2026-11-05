import Foundation
import UIKit
import TidyCore

/// Photos, thumbnails and room scans live as files in the app's Documents folder (visible in the Files app).
enum Storage {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let captures = folder("Captures")
    static let thumbs = folder("Thumbs")
    static let roomScans = folder("RoomScans")

    private static func folder(_ name: String) -> URL {
        let url = docs.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func captureURL(_ file: String) -> URL { captures.appendingPathComponent(file) }
    static func thumbURL(_ file: String) -> URL { thumbs.appendingPathComponent(file) }
    static func roomScanURL(_ file: String) -> URL { roomScans.appendingPathComponent(file) }

    static func saveCapture(_ jpeg: Data) throws -> String {
        let name = UUID().uuidString + ".jpg"
        try jpeg.write(to: captureURL(name), options: .atomic)
        return name
    }

    /// Cuts the item out of its photo and saves a 240-pixel square thumbnail.
    static func saveThumbnail(from captureFile: String, box: PhotoBox) -> String? {
        guard let image = UIImage(contentsOfFile: captureURL(captureFile).path), let cg = image.cgImage else { return nil }
        let r = CropMath.rect(for: box, imageWidth: Double(cg.width), imageHeight: Double(cg.height))
        guard let crop = cg.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height).integral) else { return nil }
        let size = CGSize(width: 240, height: 240)
        let thumb = UIGraphicsImageRenderer(size: size).image { _ in
            UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = thumb.jpegData(compressionQuality: 0.8) else { return nil }
        let name = UUID().uuidString + ".jpg"
        return (try? data.write(to: thumbURL(name), options: .atomic)) != nil ? name : nil
    }

    static func remove(capture: String?) {
        if let capture { try? FileManager.default.removeItem(at: captureURL(capture)) }
    }

    static func remove(thumb: String?) {
        if let thumb { try? FileManager.default.removeItem(at: thumbURL(thumb)) }
    }

    /// Removes every file that belongs to a room (call before deleting it).
    static func removeFiles(of room: Room) {
        room.captures.forEach { remove(capture: $0.file) }
        room.items.forEach { remove(thumb: $0.thumbFile) }
        if let f = room.usdzFile { try? FileManager.default.removeItem(at: roomScanURL(f)) }
    }
}
