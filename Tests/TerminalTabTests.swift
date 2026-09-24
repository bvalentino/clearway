import XCTest
@testable import Clearway

final class TerminalTabTests: XCTestCase {
    func testNameWinsOverSurfaceTitle() {
        XCTAssertEqual(TerminalTab.displayTitle(name: "Setup", surfaceTitle: "zsh"), "Setup")
    }

    func testNoNameAndEmptyTitleFallsBackToTerminal() {
        XCTAssertEqual(TerminalTab.displayTitle(name: nil, surfaceTitle: ""), "Terminal")
    }

    func testNoNameUsesSurfaceTitle() {
        XCTAssertEqual(TerminalTab.displayTitle(name: nil, surfaceTitle: "vim"), "vim")
    }
}
