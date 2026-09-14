import XCTest
@testable import Clearway

final class SidePanelTabTests: XCTestCase {
    // A stored tab wins over the status rule.
    func testStoredTabBeatsTheStatusRule() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.prompts.rawValue,
                                taskStatus: WorkTask.ReservedStatus.inProgress,
                                current: .todos, isMain: false),
            .prompts)
    }

    // No stored tab + in_progress → .task.
    func testInProgressSelectsTask() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, taskStatus: WorkTask.ReservedStatus.inProgress,
                                current: .todos, isMain: false),
            .task)
    }

    // No stored tab + non-in_progress preserves current, demoting .task to .todos
    // (no spurious .task).
    func testNonInProgressPreservesCurrentDemotingTask() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, taskStatus: "done", current: .task, isMain: false),
            .todos)
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, taskStatus: "done", current: .prompts, isMain: false),
            .prompts)
    }

    // An invalid stored raw value falls through to the next rule.
    func testInvalidStoredRawValueFallsThrough() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: "NotARealTab", taskStatus: WorkTask.ReservedStatus.inProgress,
                                current: .todos, isMain: false),
            .task)
    }

    // Criterion 4 of the Notes removal: a worktree persisted on the now-deleted "Notes" tab
    // must fall back to a valid tab, never resolve to a stale/invalid selection.
    func testPersistedNotesTabFallsBackToValidTab() {
        let resolved = resolveSidePanelTab(stored: "Notes", taskStatus: "done",
                                           current: .prompts, isMain: false)
        XCTAssertEqual(resolved, .prompts)
        XCTAssertTrue(SidePanelTab.available(isMain: false).contains(resolved))
    }

    // Main never lands on .task: the status rule that would pick it is clamped to .todos.
    func testMainClampsInProgressDefaultToTodos() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, taskStatus: WorkTask.ReservedStatus.inProgress,
                                current: .task, isMain: true),
            .todos)
    }

    // Main drops a stored .task (e.g. persisted before this change), falling back to the current tab.
    func testMainDropsStoredTaskFallingBackToCurrent() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.task.rawValue, taskStatus: "build",
                                current: .prompts, isMain: true),
            .prompts)
    }

    // Main clamps to .todos when both the stored and current tabs are .task.
    func testMainClampsStoredAndCurrentTaskToTodos() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.task.rawValue, taskStatus: "build",
                                current: .task, isMain: true),
            .todos)
    }

    // Main keeps a valid stored non-task tab.
    func testMainKeepsStoredNonTaskTab() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.prompts.rawValue, taskStatus: "build",
                                current: .todos, isMain: true),
            .prompts)
    }

    // Main with no stored tab preserves a valid current non-task tab.
    func testMainPreservesCurrentNonTaskTab() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, taskStatus: "build", current: .prompts, isMain: true),
            .prompts)
    }
}
