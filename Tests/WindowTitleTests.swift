import XCTest
@testable import Clearway

/// Pins `DetailSelection.windowTitle`, the rule `ContentView.navigationTitle` resolves the window
/// title with. `ContentView` itself reads `@EnvironmentObject` state XCTest cannot build.
final class WindowTitleTests: XCTestCase {

    private func title(_ selection: DetailSelection?, worktreeTitle: (Worktree) -> String = { _ in "unused" }) -> String {
        DetailSelection.windowTitle(for: selection, projectName: "clearway", worktreeTitle: worktreeTitle)
    }

    func testTasks() {
        XCTAssertEqual(title(.tasks), "Tasks")
    }

    func testPrompts() {
        XCTAssertEqual(title(.prompts), "Prompts")
    }

    func testCommands() {
        XCTAssertEqual(title(.commands), "Commands")
    }

    func testWorktreeUsesTheWorktreeTitleForThatWorktree() {
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)
        var received: Worktree?
        let result = title(.worktree(wt)) { passed in
            received = passed
            return "Row text"
        }
        XCTAssertEqual(result, "Row text")
        XCTAssertEqual(received, wt)
    }

    func testNoSelectionShowsTheProjectName() {
        XCTAssertEqual(title(nil), "clearway")
    }
}
