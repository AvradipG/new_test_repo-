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
    /// True from the end of capture until the model, measurements and lab files are all written; a build that
    /// iOS stopped resumes from its checkpoint the next time the app runs.
    var buildRequested: Bool?
    var buildAttempts: Int?
    /// Times iOS paused the build (phone locked, another app opened); these don't count as failed attempts.
    var pauses: Int?
    /// Photos set aside as blurry before the model was built (they are kept in Blurry/).
    var blurrySetAside: Int?
    /// Quick scan: one ring round the rock, enough for the dimensions.
    var quick: Bool?
    /// File name stem fixed when the scan was first named, so renaming keeps the model and Drive folder names.
    var storedStem: String?
    /// Copy in a Google Drive folder chosen through the Files app (works without a Google sign-in).
    var folderSync: DriveSync?
    /// Cylinder or sphere found in the model (2.0).
    var shape: ShapeRecord?
    /// Cross-section images drawn with millimetre rulers (2.0).
    var sectionsRuled: Bool?
    /// Which set of automatic extras this scan has (see AppModel.extrasVersion).
    var extrasVersion: Int?
    /// Reference mark: the marker line facing the X-ray source (3.0).
    var mark: MarkRecord?
    /// nil = one sample; "pieces" = broken pieces scanned together to be put back together (3.0).
    var kind: String?
    /// What the pieces were before they broke, as the user gave it.
    var pieceTarget: TargetShape?
    /// Which piece finder the pieces were last put together with (2 = 3.10 floor fix). Older sets are put together again.
    var piecesSplit: Int?
    /// Median brightness (0–1) of the rock's surface, for choosing the scanning mat (3.11).
    var rockLuma: Double?
    /// Set after a capture when the rock and what it lay on looked alike: which mat to use next time (3.11).
    var matTip: String?
    /// Photos of the second side (every piece turned over).
    var side2PhotoCount: Int?
    /// Latest reconstruction of the pieces.
    var piecesResult: PiecesSummary?
    /// Extra tools (3.4): weighed mass and grain density, virtual plugs, bedding planes.
    var massG: Double?
    var grainDensity: Double?
    var coring: [CoringRecord]?
    var bedding: [BeddingRecord]?
    /// True when the rock was flipped and its underside scanned; false when it wasn't (3.7). Nil for older scans.
    var underside: Bool?
    /// The same rock scanned the other way up, as its own scan (3.13): the id of the other scan, and which way up
    /// this one is ("upright" or "upside_down"). Kept apart; merged later on the computer if wanted.
    var pairedScanID: String?
    var orientation: String?
    /// Stand under the rock (3.14): the model is cut at this height (model frame, metres, +Y up) and only the
    /// rock above it is measured, sliced and drawn. nil = nothing cut.
    var standCutY: Double?
    /// How the cut was set: "auto" (found by colour), "user" (set or corrected by hand), "none" (the user said
    /// there is no stand), "not_found" (looked for, none found). nil = not looked for yet.
    var standCheck: String?

    /// Correction factor from a caliper check (1 when there is none).
    var scaleFactor: Double {
        // Without a caliper check: the phone's scale reference when that extra tool is on and applied, else 1.
        guard let c = caliper, let model = modelLength(axis: c.axis) else { return PhoneScale.applied }
        return model > 0 && c.measuredMM > 0 ? c.measuredMM / model : 1
    }

    /// Where the scale comes from, for reports and lab files.
    var scaleSource: String {
        if caliper != nil { return "caliper-corrected" }
        return PhoneScale.applied != 1 ? "phone scale reference" : "LiDAR"
    }

    /// The scan's own length for a caliper axis: a, b, c, or 3 = upright height.
    func modelLength(axis: Int) -> Double? {
        guard let s = stats else { return nil }
        switch axis {
        case 0: return s.axisA
        case 1: return s.axisB
        case 2: return s.axisC
        case 3: return s.upright?.heightMM
        default: return nil
        }
    }

    /// True for scans measured before 1.8 (no smallest-box sizes or micro-CT cylinder) or cut before 1.7
    /// (no height profile, or section stacks without outline sizes).
    /// Finished, and missing the shape fit, sample sheet or ruled cross-sections that newer versions add.
    var needsExtras: Bool {
        !isPieces && hasModel && buildRequested != true && (extrasVersion ?? 0) < AppModel.extrasVersion
    }

    var isPieces: Bool { kind == "pieces" }

    var needsRepair: Bool {
        guard hasModel, !isPieces else { return false }
        guard let s = stats, let u = s.upright, u.cylinderDiameterMM != nil, s.box != nil else { return true }
        let stacks = sections ?? []
        if !stacks.contains(where: { $0.isHeightProfile }) { return true }
        return stacks.contains { $0.rows.contains { $0.maxFeretMM == nil && $0.measurementStatus != "empty_section" } }
    }

    var folderURL: URL { ScanStore.root.appendingPathComponent(id, isDirectory: true) }
    var imagesURL: URL { folderURL.appendingPathComponent("Images", isDirectory: true) }
    var checkpointURL: URL { folderURL.appendingPathComponent("Checkpoint", isDirectory: true) }
    var exportsURL: URL { folderURL.appendingPathComponent("Exports", isDirectory: true) }
    var sectionsURL: URL { folderURL.appendingPathComponent("Sections", isDirectory: true) }
    /// Close-up photos for pattern and texture work; not used to build the model.
    var detailURL: URL { folderURL.appendingPathComponent("Detail", isDirectory: true) }
    var blurryURL: URL { folderURL.appendingPathComponent("Blurry", isDirectory: true) }
    var detailCount: Int { ScanStore.countPhotos(in: detailURL) }
    /// Sizes for the micro-CT are known once the model has been measured.
    var dimensionsReady: Bool { stats?.upright != nil }
    /// Scans of the same sample share a name (case and spacing ignored).
    var sampleKey: String { name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    var modelURL: URL { folderURL.appendingPathComponent("\(fileStem).usdz") }
    var hasModel: Bool { FileManager.default.fileExists(atPath: modelURL.path) }
    var hasPhotos: Bool { ScanStore.countPhotos(in: imagesURL) > 0 }
    // Pieces: the second side.
    var images2URL: URL { folderURL.appendingPathComponent("Images2", isDirectory: true) }
    var checkpoint2URL: URL { folderURL.appendingPathComponent("Checkpoint2", isDirectory: true) }
    var model2URL: URL { folderURL.appendingPathComponent("\(fileStem)_side2.usdz") }
    var hasModel2: Bool { FileManager.default.fileExists(atPath: model2URL.path) }
    var hasPhotos2: Bool { ScanStore.countPhotos(in: images2URL) > 0 }
    var piecesURL: URL { exportsURL.appendingPathComponent("pieces", isDirectory: true) }

    var fileStem: String { storedStem ?? Self.stem(for: name, id: id) }

    static func stem(for name: String, id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? id : trimmed
    }
}

struct CaliperCheck: Codable, Hashable {
    /// 0 = a (longest), 1 = b, 2 = c (shortest), 3 = upright height.
    var axis: Int
    var measuredMM: Double
    var date: Date
    /// Set when the check was taken over from an earlier scan of the same sample.
    var fromScanID: String?
    var axisName: String { ["a", "b", "c", "height"][max(0, min(3, axis))] }
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
        var scan = Scan(id: f.string(from: Date()), name: trimmed.isEmpty ? "Rock sample" : trimmed, created: Date())
        scan.storedStem = scan.fileStem
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
        try? FileManager.default.removeItem(at: scan.images2URL)
        try? FileManager.default.removeItem(at: scan.checkpoint2URL)
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

    static func photoURLs(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func countPhotos(in dir: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { ["heic", "jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }.count
    }
}
