import Foundation

/// Unfinished scans (3.19): a scan stopped by mistake, by the user on purpose, or by iOS closing the app is never
/// thrown away. Its photos are on disk from the moment they are taken; these are the rules for keeping it as a
/// draft, resuming it with more photos, and remembering what the user typed.
public enum Drafts {
    public enum State: String, Codable, Sendable {
        /// A finished scan, or one being built.
        case done
        /// A capture is going on right now.
        case capturing
        /// Photos and no model, nothing building: resume it, build it, or discard it.
        case draft
        /// The app was closed while this scan was being captured (by iOS or a crash): kept as a draft.
        case interrupted
        /// Nothing captured: nothing to keep.
        case empty
    }

    /// What a scan is, from what is on disk and its flags.
    /// - Parameters:
    ///   - captureOpen: the scan was marked "being captured" (set when a capture starts, cleared when it ends).
    ///   - capturingNow: this run of the app is capturing it right now.
    public static func state(hasModel: Bool, photoCount: Int, buildRequested: Bool, captureOpen: Bool, capturingNow: Bool) -> State {
        if capturingNow { return .capturing }
        if hasModel || buildRequested { return .done }
        if photoCount == 0 { return .empty }
        return captureOpen ? .interrupted : .draft
    }

    /// The list of recent Sample IDs with `name` put first: blanks ignored, the same name (any case or spacing)
    /// once only, at most `limit`.
    public static func recentNames(_ list: [String], adding name: String, limit: Int = 12) -> [String] {
        func key(_ s: String) -> String {
            s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [String] = trimmed.isEmpty ? [] : [trimmed]
        var seen = Set(out.map(key))
        for n in list {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(key(t)).inserted else { continue }
            out.append(t)
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    /// Moves every file from a resumed capture's folder into the scan's photo folder. Each file gets the session's
    /// prefix ("s2-…"), so nothing is overwritten and the new photos sort after the earlier ones (photogrammetry
    /// reads them in order). Returns how many were moved. The source folder is removed when it is empty.
    @discardableResult
    public static func mergePhotos(from source: URL, into destination: URL, session: Int) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var moved = 0
        for url in items {
            var name = "s\(session)-" + url.lastPathComponent
            var n = 1
            while fm.fileExists(atPath: destination.appendingPathComponent(name).path) {
                n += 1
                name = "s\(session)-\(n)-" + url.lastPathComponent
            }
            try fm.moveItem(at: url, to: destination.appendingPathComponent(name))
            moved += 1
        }
        if ((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).isEmpty { try? fm.removeItem(at: source) }
        return moved
    }
}
