import XCTest
@testable import Clearway

/// Pins `agentMenuRows`, the rule the tab strip's `+` menu is built from. The menu itself needs a
/// live `ghostty_app_t` to render, so the rule is tested rather than the view.
final class AgentMenuRowTests: XCTestCase {

    func testNoMainCommandMarksNoRow() {
        let rows = agentMenuRows(agents: agentAllowlist, mainCommand: nil)
        XCTAssertEqual(rows.count, agentAllowlist.count)
        XCTAssertTrue(rows.allSatisfy { !$0.carriesMainTerminalShortcut })
    }

    func testListedMainCommandMarksExactlyItsRow() {
        let rows = agentMenuRows(agents: agentAllowlist, mainCommand: "codex")
        XCTAssertEqual(rows.filter(\.carriesMainTerminalShortcut).map(\.command), ["codex"])
    }

    func testUnlistedMainCommandMarksNoRow() {
        let rows = agentMenuRows(agents: agentAllowlist, mainCommand: "fish")
        XCTAssertEqual(rows.count, agentAllowlist.count)
        XCTAssertTrue(rows.allSatisfy { !$0.carriesMainTerminalShortcut })
    }

    /// Reads `agentAllowlist` itself, so the menu order cannot drift from the picker order.
    func testRowsFollowTheAllowlistOrder() {
        let rows = agentMenuRows(agents: agentAllowlist, mainCommand: nil)
        XCTAssertEqual(rows.map(\.command), ["claude", "codex", "grok"])
        XCTAssertEqual(rows.map(\.title), ["Claude", "Codex", "Grok"])
    }
}
