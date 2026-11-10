import XCTest
@testable import ScanMath

final class MatAdvisorTests: XCTestCase {
    func testDarkAndGreyRocksGoOnTheLightMat() {
        for l in [0.08, 0.25, 0.45, 0.6] {
            XCTAssertEqual(MatAdvisor.advise(rockLuma: l).tone, .light, "brightness \(l)")
        }
    }

    func testPaleRocksGoOnTheDarkMat() {
        for l in [0.7, 0.8, 0.92] {
            let a = MatAdvisor.advise(rockLuma: l)
            XCTAssertEqual(a.tone, .dark, "brightness \(l)")
            XCTAssertGreaterThan(a.contrast, 0.5)
        }
    }

    func testLowContrastGivesATip() {
        XCTAssertNil(MatAdvisor.checkContrast(rockLuma: 0.4, surroundLuma: 0.9))
        let tip = try! XCTUnwrap(MatAdvisor.checkContrast(rockLuma: 0.85, surroundLuma: 0.9))
        XCTAssertTrue(tip.contains("dark scanning mat"))
        XCTAssertTrue(MatAdvisor.checkContrast(rockLuma: 0.2, surroundLuma: 0.25)!.contains("light scanning mat"))
    }

    func testPaperAndFit() {
        XCTAssertEqual(MatAdvisor.paper(region: "US"), "Letter")
        XCTAssertEqual(MatAdvisor.paper(region: "GB"), "A4")
        XCTAssertEqual(MatAdvisor.paper(region: nil), "A4")
        XCTAssertTrue(MatAdvisor.fits(lengthMM: 150, widthMM: 38, paper: "A4"))
        XCTAssertFalse(MatAdvisor.fits(lengthMM: 200, widthMM: 38, paper: "Letter"))
        XCTAssertFalse(MatAdvisor.fits(lengthMM: 150, widthMM: 140, paper: "A4"))
    }
}
