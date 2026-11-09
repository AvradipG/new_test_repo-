import Foundation
import UIKit
import simd
import TidyCore

/// Photos, thumbnails and room scans live as files in the app's Documents folder (visible in the Files app).
enum Storage {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let captures = folder("Captures")
    static let thumbs = folder("Thumbs")
    static let roomScans = folder("RoomScans")
    static let worldMaps = folder("WorldMaps")
    static let designs = folder("Designs")

    private static func folder(_ name: String) -> URL {
        let url = docs.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func captureURL(_ file: String) -> URL { captures.appendingPathComponent(file) }
    static func thumbURL(_ file: String) -> URL { thumbs.appendingPathComponent(file) }
    static func roomScanURL(_ file: String) -> URL { roomScans.appendingPathComponent(file) }
    static func worldMapURL(_ file: String) -> URL { worldMaps.appendingPathComponent(file) }
    static func designURL(_ file: String) -> URL { designs.appendingPathComponent(file) }

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
        room.captures.forEach { remove(capture: $0.file); DepthStore.remove($0.uid) }
        if let f = room.worldMapFile { try? FileManager.default.removeItem(at: worldMapURL(f)) }
        room.designs.forEach { d in if let f = d.renderFile { try? FileManager.default.removeItem(at: designURL(f)) } }
        room.items.forEach { remove(thumb: $0.thumbFile) }
        if let f = room.usdzFile { try? FileManager.default.removeItem(at: roomScanURL(f)) }
    }
}

/// Keeps each AR photo's LiDAR depth next to it (Documents/Depth), so a photo that failed can be re-analysed and
/// still be measured. Format: 12 header floats (width, height, fx, fy, cx, cy, 4×4 pose column-major follows),
/// then depth floats, then confidence bytes.
enum DepthStore {
    static let folder: URL = {
        let url = Storage.docs.appendingPathComponent("Depth", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".depth") }

    static func save(_ f: DepthFrame, for id: UUID) {
        var header: [Float] = [Float(f.width), Float(f.height), f.fx, f.fy, f.cx, f.cy]
        let m = f.cameraToWorld
        for c in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] { header += [c.x, c.y, c.z, c.w] }
        var data = Data()
        header.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        f.depth.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        if let conf = f.confidence { data.append(contentsOf: conf) }
        try? data.write(to: url(id), options: .atomic)
    }

    static func load(for id: UUID) -> DepthFrame? {
        guard let data = try? Data(contentsOf: url(id)), data.count >= 22 * 4 else { return nil }
        let floats: [Float] = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(data.count / 4))
        }
        let w = Int(floats[0]), h = Int(floats[1]), n = w * h
        guard w > 0, h > 0, floats.count >= 22 + n else { return nil }
        let m = simd_float4x4(SIMD4(floats[6], floats[7], floats[8], floats[9]), SIMD4(floats[10], floats[11], floats[12], floats[13]),
                              SIMD4(floats[14], floats[15], floats[16], floats[17]), SIMD4(floats[18], floats[19], floats[20], floats[21]))
        let depth = Array(floats[22..<(22 + n)])
        let confStart = (22 + n) * 4
        let conf: [UInt8]? = data.count >= confStart + n ? Array(data[confStart..<(confStart + n)]) : nil
        return DepthFrame(width: w, height: h, depth: depth, confidence: conf, fx: floats[2], fy: floats[3], cx: floats[4], cy: floats[5],
                          cameraToWorld: m)
    }

    static func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }
}
