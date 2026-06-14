import XCTest
@testable import Clearway

final class SidePanelTabTests: XCTestCase {
    // Criterion 1: JSON project + no stored tab → .task, for any status.
    func testJSONProjectNoStoredTabSelectsTaskForAnyStatus() {
        for status in ["new", "build", "ready_to_start", nil] {
            XCTAssertEqual(
                resolveSidePanelTab(stored: nil, isWorkflowJSONProject: true,
                                    taskStatus: status, current: .todos),
                .task,
                "JSON project with status \(String(describing: status)) should land on .task")
        }
    }

    // Criterion 2: stored tab wins over the JSON-project rule.
    func testStoredTabBeatsJSONProjectRule() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.notes.rawValue, isWorkflowJSONProject: true,
                                taskStatus: "build", current: .todos),
            .notes)
    }

    // Criterion 3: non-JSON + no stored tab + in_progress → .task.
    func testNonJSONInProgressSelectsTask() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, isWorkflowJSONProject: false,
                                taskStatus: WorkTask.ReservedStatus.inProgress, current: .todos),
            .task)
    }

    // Criterion 4: non-JSON + no stored tab + non-in_progress preserves current,
    // demoting .task to .todos (no spurious .task).
    func testNonJSONNonInProgressPreservesCurrentDemotingTask() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, isWorkflowJSONProject: false,
                                taskStatus: "done", current: .task),
            .todos)
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, isWorkflowJSONProject: false,
                                taskStatus: "done", current: .notes),
            .notes)
    }

    // An invalid stored raw value falls through to the next rule.
    func testInvalidStoredRawValueFallsThrough() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: "NotARealTab", isWorkflowJSONProject: true,
                                taskStatus: "build", current: .todos),
            .task)
    }
}
