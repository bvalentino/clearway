import XCTest
@testable import Clearway

final class SidePanelTabTests: XCTestCase {
    // Criterion 1: JSON project + no stored tab → .task, for any status.
    func testJSONProjectNoStoredTabSelectsTaskForAnyStatus() {
        for status in ["new", "build", "ready_to_start", nil] {
            XCTAssertEqual(
                resolveSidePanelTab(stored: nil, isWorkflowJSONProject: true,
                                    taskStatus: status, current: .todos, isMain: false),
                .task,
                "JSON project with status \(String(describing: status)) should land on .task")
        }
    }

    // Criterion 2: stored tab wins over the JSON-project rule.
    func testStoredTabBeatsJSONProjectRule() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.notes.rawValue, isWorkflowJSONProject: true,
                                taskStatus: "build", current: .todos, isMain: false),
            .notes)
    }

    // Criterion 3: non-JSON + no stored tab + in_progress → .task.
    func testNonJSONInProgressSelectsTask() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, isWorkflowJSONProject: false,
                                taskStatus: WorkTask.ReservedStatus.inProgress, current: .todos, isMain: false),
            .task)
    }

    // Criterion 4: non-JSON + no stored tab + non-in_progress preserves current,
    // demoting .task to .todos (no spurious .task).
    func testNonJSONNonInProgressPreservesCurrentDemotingTask() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, isWorkflowJSONProject: false,
                                taskStatus: "done", current: .task, isMain: false),
            .todos)
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, isWorkflowJSONProject: false,
                                taskStatus: "done", current: .notes, isMain: false),
            .notes)
    }

    // An invalid stored raw value falls through to the next rule.
    func testInvalidStoredRawValueFallsThrough() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: "NotARealTab", isWorkflowJSONProject: true,
                                taskStatus: "build", current: .todos, isMain: false),
            .task)
    }

    // Main never lands on .task: the JSON-project default that would pick .task is clamped to .todos.
    func testMainClampsJSONDefaultToTodos() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, isWorkflowJSONProject: true,
                                taskStatus: "build", current: .task, isMain: true),
            .todos)
    }

    // Main drops a stored .task (e.g. persisted before this change), falling back to the current tab.
    func testMainDropsStoredTaskFallingBackToCurrent() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.task.rawValue, isWorkflowJSONProject: true,
                                taskStatus: "build", current: .notes, isMain: true),
            .notes)
    }

    // Main clamps to .todos when both the stored and current tabs are .task.
    func testMainClampsStoredAndCurrentTaskToTodos() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.task.rawValue, isWorkflowJSONProject: true,
                                taskStatus: "build", current: .task, isMain: true),
            .todos)
    }

    // Main keeps a valid stored non-task tab.
    func testMainKeepsStoredNonTaskTab() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.notes.rawValue, isWorkflowJSONProject: true,
                                taskStatus: "build", current: .todos, isMain: true),
            .notes)
    }

    // Main with no stored tab preserves a valid current non-task tab.
    func testMainPreservesCurrentNonTaskTab() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, isWorkflowJSONProject: true,
                                taskStatus: "build", current: .prompts, isMain: true),
            .prompts)
    }
}
