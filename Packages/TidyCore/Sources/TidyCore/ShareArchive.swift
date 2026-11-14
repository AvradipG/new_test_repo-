import Foundation

/// The .tidyatlas share file: one file with a JSON manifest (the database of a place or room) and the files it uses
/// (photos, thumbnails, scans). Written and read in chunks, so big homes with many photos don't fill the memory.
///
/// Layout: magic line | UInt64 little-endian index length | index JSON | manifest bytes | file bytes, in index order.
public enum ShareArchive {
    public static let magic = Data("TIDYATLAS-SHARE-1\n".utf8)
    public static let fileExtension = "tidyatlas"
    public static let typeIdentifier = "com.avradip.tidyatlas.share"

    public struct Entry: Codable, Equatable, Sendable {
        /// App folder the file belongs in ("Captures", "Thumbs", "RoomScans"…).
        public var folder: String
        public var name: String
        public var length: UInt64

        public init(folder: String, name: String, length: UInt64) {
            self.folder = folder
            self.name = name
            self.length = length
        }
    }

    public struct Index: Codable, Equatable, Sendable {
        public var version: Int
        public var manifestLength: UInt64
        public var entries: [Entry]
    }

    public struct Source: Sendable {
        public var folder: String
        public var name: String
        public var url: URL

        public init(folder: String, name: String, url: URL) {
            self.folder = folder
            self.name = name
            self.url = url
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notAShareFile
        case damaged

        public var errorDescription: String? {
            switch self {
            case .notAShareFile: return "This isn't a Tidy Atlas share file."
            case .damaged: return "This share file is incomplete or damaged. Ask for it to be sent again."
            }
        }
    }

    /// Only plain file names are accepted from a share file (no folders, no hidden files), so a file from someone
    /// else can never write outside the app's own folders.
    public static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 200 && !s.hasPrefix(".") && !s.contains("/") && !s.contains("\\") && !s.contains("\0")
            && s != ".." && !s.contains("..")
    }

    /// Writes the archive. Files that don't exist are skipped.
    public static func write(manifest: Data, files: [Source], to url: URL) throws {
        let fm = FileManager.default
        var included: [(Source, UInt64)] = []
        for f in files where isSafeName(f.name) && isSafeName(f.folder) {
            guard let size = (try? fm.attributesOfItem(atPath: f.url.path))?[.size] as? NSNumber else { continue }
            included.append((f, size.uint64Value))
        }
        let index = Index(version: 1, manifestLength: UInt64(manifest.count),
                          entries: included.map { Entry(folder: $0.0.folder, name: $0.0.name, length: $0.1) })
        let indexData = try JSONEncoder().encode(index)
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var len = UInt64(indexData.count).littleEndian
        try out.write(contentsOf: magic)
        try out.write(contentsOf: withUnsafeBytes(of: &len) { Data($0) })
        try out.write(contentsOf: indexData)
        try out.write(contentsOf: manifest)
        for (f, size) in included {
            let input = try FileHandle(forReadingFrom: f.url)
            defer { try? input.close() }
            var left = size
            while left > 0 {
                let chunk = try input.read(upToCount: Int(min(left, 1 << 20))) ?? Data()
                if chunk.isEmpty { throw Failure.damaged }
                try out.write(contentsOf: chunk)
                left -= UInt64(chunk.count)
            }
        }
    }

    /// Opens an archive for reading.
    public final class Reader {
        public let index: Index
        public let manifest: Data
        private let handle: FileHandle
        private var offsets: [UInt64] = []

        public init(url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
            guard let head = try handle.read(upToCount: ShareArchive.magic.count), head == ShareArchive.magic else {
                try? handle.close()
                throw Failure.notAShareFile
            }
            guard let lenData = try handle.read(upToCount: 8), lenData.count == 8 else { throw Failure.damaged }
            let len = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
            guard len > 0, len < 64 << 20, let indexData = try handle.read(upToCount: Int(len)), indexData.count == Int(len),
                  let idx = try? JSONDecoder().decode(Index.self, from: indexData) else { throw Failure.damaged }
            index = idx
            guard idx.manifestLength < 512 << 20, let m = try handle.read(upToCount: Int(idx.manifestLength)),
                  m.count == Int(idx.manifestLength) else { throw Failure.damaged }
            manifest = m
            var at = UInt64(ShareArchive.magic.count) + 8 + len + idx.manifestLength
            for e in idx.entries {
                offsets.append(at)
                at += e.length
            }
        }

        deinit { try? handle.close() }

        /// Copies entry `i` to `url` (overwriting).
        public func extract(_ i: Int, to url: URL) throws {
            let e = index.entries[i]
            guard ShareArchive.isSafeName(e.name), ShareArchive.isSafeName(e.folder) else { throw Failure.damaged }
            try handle.seek(toOffset: offsets[i])
            let fm = FileManager.default
            try? fm.removeItem(at: url)
            guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let out = try FileHandle(forWritingTo: url)
            defer { try? out.close() }
            var left = e.length
            while left > 0 {
                let chunk = try handle.read(upToCount: Int(min(left, 1 << 20))) ?? Data()
                if chunk.isEmpty { throw Failure.damaged }
                try out.write(contentsOf: chunk)
                left -= UInt64(chunk.count)
            }
        }
    }
}
