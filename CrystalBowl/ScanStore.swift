import Foundation
import ScanMath

/// One rock scan: a folder with the captured photos, the model and a metadata file.
struct Scan: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var created: Date
    var photoCount: Int?
    var passes: Int?
    var stats: MeshStats?
    var sections: [SectionSeries]?
    var drive: DriveSync?
    /// Share of the ring covered by photos on the last side scanned: low, middle and high camera heights (0…1).
    var coverage: [Double]?
    /// A length measured with calipers, used to check and correct the scan's scale.
    var caliper: CaliperCheck?

    /// Correction factor from a caliper check (1 when there is none).
    var scaleFactor: Double {
        guard let c = caliper, let s = stats else { return 1 }
        let model = [s.axisA, s.axisB, s.axisC][max(0, min(2, c.axis))]
        return model > 0 && c.measuredMM > 0 ? c.measuredMM / model : 1
    }

    var folderURL: URL { ScanStore.root.appendingPathComponent(id, isDirectory: true) }
    var imagesURL: URL { folderURL.appendingPathComponent("Images", isDirectory: true) }
    var checkpointURL: URL { folderURL.appendingPathComponent("Checkpoint", isDirectory: true) }
    var exportsURL: URL { folderURL.appendingPathComponent("Exports", isDirectory: true) }
    var sectionsURL: URL { folderURL.appendingPathComponent("Sections", isDirectory: true) }
    var modelURL: URL { folderURL.appendingPathComponent("\(fileStem).usdz") }
    var hasModel: Bool { FileManager.default.fileExists(atPath: modelURL.path) }
    var hasPhotos: Bool { ScanStore.countPhotos(in: imagesURL) > 0 }

    var fileStem: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? id : trimmed
    }
}

struct CaliperCheck: Codable, Hashable {
    /// 0 = a (longest), 1 = b, 2 = c (shortest).
    var axis: Int
    var measuredMM: Double
    var date: Date
}

enum ScanStore {
    /// Documents/Scans. The app shares Documents with the Files app, so scans can be copied to Drive from there.
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Scans", isDirectory: true)
    }

    static func create(name: String) throws -> Scan {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let scan = Scan(id: f.string(from: Date()), name: trimmed.isEmpty ? "Rock sample" : trimmed, created: Date())
        let fm = FileManager.default
        for dir in [scan.imagesURL, scan.checkpointURL, scan.exportsURL] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try save(scan)
        return scan
    }

    static func save(_ scan: Scan) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(scan).write(to: scan.folderURL.appendingPathComponent("scan.json"), options: .atomic)
    }

    static func loadAll() -> [Scan] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("scan.json")) else { return nil }
            return try? dec.decode(Scan.self, from: data)
        }
        .sorted { $0.created > $1.created }
    }

    static func delete(_ scan: Scan) {
        try? FileManager.default.removeItem(at: scan.folderURL)
    }

    /// Removes the capture photos and checkpoint once a model exists; they are only needed to rebuild it.
    static func deletePhotos(_ scan: Scan) {
        try? FileManager.default.removeItem(at: scan.imagesURL)
        try? FileManager.default.removeItem(at: scan.checkpointURL)
    }

    /// Bytes used by everything in the scan folder.
    static func size(of scan: Scan) -> Int64 {
        guard let e = FileManager.default.enumerator(at: scan.folderURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func countPhotos(in dir: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { ["heic", "jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }.count
    }
}
