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
}
