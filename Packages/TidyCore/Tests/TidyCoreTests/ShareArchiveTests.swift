import XCTest
@testable import TidyCore

final class ShareArchiveTests: XCTestCase {
    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.json")
        let big = Data((0..<(3 << 20)).map { UInt8($0 % 251) })
        try big.write(to: a)
        try Data("{\"x\":1}".utf8).write(to: b)
        let manifest = Data("{\"place\":\"Home\"}".utf8)
        let out = dir.appendingPathComponent("home.tidyatlas")
        try ShareArchive.write(manifest: manifest, files: [
            .init(folder: "Captures", name: "a.jpg", url: a),
            .init(folder: "RoomScans", name: "b.json", url: b),
            .init(folder: "Captures", name: "missing.jpg", url: dir.appendingPathComponent("missing.jpg")),
            .init(folder: "Captures", name: "../evil.jpg", url: a),
        ], to: out)
        let r = try ShareArchive.Reader(url: out)
        XCTAssertEqual(r.manifest, manifest)
        XCTAssertEqual(r.index.entries.map(\.name), ["a.jpg", "b.json"], "missing and unsafe files are left out")
        let back = dir.appendingPathComponent("back.jpg")
        try r.extract(0, to: back)
        XCTAssertEqual(try Data(contentsOf: back), big)
        try r.extract(1, to: back)
        XCTAssertEqual(try Data(contentsOf: back), Data("{\"x\":1}".utf8))
    }

    func testRejectsOtherFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tidyatlas")
        try Data("hello world, not an archive".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ShareArchive.Reader(url: url)) { XCTAssertEqual($0 as? ShareArchive.Failure, .notAShareFile) }
    }

    func testSafeNames() {
        XCTAssertTrue(ShareArchive.isSafeName("6F1C-1.capturedroom.json"))
        XCTAssertFalse(ShareArchive.isSafeName("../x"))
        XCTAssertFalse(ShareArchive.isSafeName("a/b"))
        XCTAssertFalse(ShareArchive.isSafeName(".hidden"))
        XCTAssertFalse(ShareArchive.isSafeName(""))
    }
}
