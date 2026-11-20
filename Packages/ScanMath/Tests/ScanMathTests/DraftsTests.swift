import XCTest
@testable import ScanMath

/// 3.19: an unfinished scan is never lost.
final class DraftsTests: XCTestCase {
    func testWhatAScanIs() {
        // Stopped with photos and no model: a draft to resume or build.
        XCTAssertEqual(Drafts.state(hasModel: false, photoCount: 7, buildRequested: false, captureOpen: false, capturingNow: false), .draft)
        // The app was closed mid-capture: still marked open on the next start.
        XCTAssertEqual(Drafts.state(hasModel: false, photoCount: 40, buildRequested: false, captureOpen: true, capturingNow: false), .interrupted)
        // Being captured now, building, or built: not a draft.
        XCTAssertEqual(Drafts.state(hasModel: false, photoCount: 40, buildRequested: false, captureOpen: true, capturingNow: true), .capturing)
        XCTAssertEqual(Drafts.state(hasModel: false, photoCount: 40, buildRequested: true, captureOpen: false, capturingNow: false), .done)
        XCTAssertEqual(Drafts.state(hasModel: true, photoCount: 0, buildRequested: false, captureOpen: false, capturingNow: false), .done)
        // Nothing taken: nothing to keep.
        XCTAssertEqual(Drafts.state(hasModel: false, photoCount: 0, buildRequested: false, captureOpen: true, capturingNow: false), .empty)
    }

    func testRecentSampleNames() {
        var list: [String] = []
        list = Drafts.recentNames(list, adding: "Desert Peak 4623-3")
        list = Drafts.recentNames(list, adding: "Adnoc Sample 5")
        list = Drafts.recentNames(list, adding: "  ")
        XCTAssertEqual(list, ["Adnoc Sample 5", "Desert Peak 4623-3"])
        // Used again (any case and spacing): moves to the front, once only.
        list = Drafts.recentNames(list, adding: "desert  peak 4623-3")
        XCTAssertEqual(list, ["desert  peak 4623-3", "Adnoc Sample 5"])
        // At most the limit, newest kept.
        for i in 0..<20 { list = Drafts.recentNames(list, adding: "Plug \(i)", limit: 5) }
        XCTAssertEqual(list, ["Plug 19", "Plug 18", "Plug 17", "Plug 16", "Plug 15"])
    }

    func testResumedPhotosJoinTheScanWithoutOverwritingAndInOrder() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("drafts-test-\(UUID().uuidString)")
        let images = base.appendingPathComponent("Images"), resume = base.appendingPathComponent("Images-resume-2")
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        try fm.createDirectory(at: resume, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        // The first session's photos, then a resumed session whose camera starts counting again.
        for name in ["00001.100.HEIC", "00002.200.HEIC", "00003.300.HEIC"] {
            try Data("first \(name)".utf8).write(to: images.appendingPathComponent(name))
        }
        for name in ["00001.100.HEIC", "00002.500.HEIC"] {
            try Data("second \(name)".utf8).write(to: resume.appendingPathComponent(name))
        }
        let moved = try Drafts.mergePhotos(from: resume, into: images, session: 2)
        XCTAssertEqual(moved, 2)
        let names = try fm.contentsOfDirectory(atPath: images.path).sorted()
        XCTAssertEqual(names, ["00001.100.HEIC", "00002.200.HEIC", "00003.300.HEIC", "s2-00001.100.HEIC", "s2-00002.500.HEIC"])
        // The first photo of the first session is untouched.
        XCTAssertEqual(try String(contentsOf: images.appendingPathComponent("00001.100.HEIC"), encoding: .utf8), "first 00001.100.HEIC")
        XCTAssertFalse(fm.fileExists(atPath: resume.path), "the emptied session folder is removed")
        // Resuming the same session number again doesn't overwrite either.
        try fm.createDirectory(at: resume, withIntermediateDirectories: true)
        try Data("third".utf8).write(to: resume.appendingPathComponent("00001.100.HEIC"))
        try Drafts.mergePhotos(from: resume, into: images, session: 2)
        XCTAssertTrue(fm.fileExists(atPath: images.appendingPathComponent("s2-2-00001.100.HEIC").path))
        XCTAssertEqual(try String(contentsOf: images.appendingPathComponent("s2-00001.100.HEIC"), encoding: .utf8), "second 00001.100.HEIC")
    }
}
