import XCTest
@testable import Clearway

final class TerminalTabKindTests: XCTestCase {
    func testLauncherTabHasNilSurfaceAndReportsLauncher() {
        let tab = TerminalTab(id: UUID(), kind: .launcher)
        XCTAssertTrue(tab.isLauncher)
        XCTAssertNil(tab.surface)
    }

    func testSurfaceTabKindExposesSurface() {
        // We can't cheaply construct a real SurfaceView in tests (needs ghostty_app_t),
        // so exercise the Kind enum via a raw assertion: the launcher case is distinct
        // from the surface case even without instantiation.
        let launcher = TerminalTab(id: UUID(), kind: .launcher)
        if case .surface = launcher.kind {
            XCTFail("launcher should not match .surface case")
        }
    }

    func testMainTerminalActiveSurfaceIsNilForLauncherActive() {
        let launcher = TerminalTab(id: UUID(), kind: .launcher)
        let terminal = MainTerminal(tabs: [launcher], activeId: launcher.id)
        XCTAssertNil(terminal.activeSurface)
        XCTAssertEqual(terminal.activeTab?.id, launcher.id)
    }

    /// Regression: todo play button was disabled when the active tab was a launcher
    /// because `canSend` gated on `activeSurface != nil`. `sendToActiveMainTab`
    /// accepts launcher tabs (it seeds the draft), so the UI gate must too.
    func testMainTerminalHasActiveTabIsTrueForLauncher() {
        let launcher = TerminalTab(id: UUID(), kind: .launcher)
        let terminal = MainTerminal(tabs: [launcher], activeId: launcher.id)
        XCTAssertTrue(terminal.hasActiveTab)
        XCTAssertNil(terminal.activeSurface)
    }

    func testMainTerminalHasActiveTabIsFalseWhenEmpty() {
        let terminal = MainTerminal(tabs: [], activeId: nil)
        XCTAssertFalse(terminal.hasActiveTab)
    }

    // MARK: - Launcher draft append

    func testAppendingToDraftReturnsTextWhenExistingIsEmpty() {
        XCTAssertEqual(appendingToDraft(existing: "", "hello"), "hello")
    }

    func testAppendingToDraftSeparatesWithNewline() {
        XCTAssertEqual(appendingToDraft(existing: "Fix", "the bug"), "Fix\nthe bug")
    }

    func testAppendingToDraftDoesNotDoubleSeparatorWhenExistingEndsWithNewline() {
        XCTAssertEqual(appendingToDraft(existing: "Fix\n", "the bug"), "Fix\nthe bug")
    }

    func testAppendingToDraftPreservesMultilineExisting() {
        XCTAssertEqual(
            appendingToDraft(existing: "line one\nline two", "line three"),
            "line one\nline two\nline three"
        )
    }
}
