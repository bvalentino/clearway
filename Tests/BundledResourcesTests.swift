import XCTest
@testable import Clearway

final class BundledResourcesTests: XCTestCase {

    func testThirdPartyLicensesShipsWithEveryNotice() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "THIRD-PARTY-LICENSES", withExtension: nil),
            "THIRD-PARTY-LICENSES is missing from the app bundle"
        )
        let lines = Set(try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines))

        for name in ["Git", "Ghostty", "cmark-gfm", "Sparkle"] {
            XCTAssertTrue(lines.contains(name), "THIRD-PARTY-LICENSES has no \(name) section heading")
        }
    }
}
