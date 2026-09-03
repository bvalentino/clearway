import XCTest
@testable import Clearway

/// Pins `DetailSelection.bottomPanelAction`, the rule Cmd+J routes on. `ContentView.bottomPanel`
/// itself is unreachable from XCTest — it reads `@EnvironmentObject` state a test cannot build.
final class BottomPanelActionTests: XCTestCase {

    private func action(_ selection: DetailSelection?) -> BottomPanelAction {
        DetailSelection.bottomPanelAction(for: selection)
    }

    func testWorktreeHostsTheSecondaryTerminal() {
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)
        XCTAssertEqual(action(.worktree(wt)), .secondaryTerminal)
    }

    /// The main worktree is not a special case — Cmd+J reaches its panel too.
    func testMainWorktreeHostsTheSecondaryTerminal() {
        let wt = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        XCTAssertEqual(action(.worktree(wt)), .secondaryTerminal)
    }

    func testPlanningHostsThePlanningTerminal() {
        XCTAssertEqual(action(.planning), .planningTerminal)
    }

    func testDestinationsWithoutABottomPanelGetNothing() {
        XCTAssertEqual(action(.prompts), .noPanel)
        XCTAssertEqual(action(.workflow), .noPanel)
        XCTAssertEqual(action(nil), .noPanel)
    }
}
