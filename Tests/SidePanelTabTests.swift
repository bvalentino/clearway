import XCTest
@testable import Clearway

final class SidePanelTabTests: XCTestCase {
    private let visibleTask = WorkTask(title: "Visible", worktree: "feature")

    private var hiddenTask: WorkTask {
        var task = WorkTask(title: "Shadow", worktree: "feature")
        task.hidden = true
        return task
    }

    func testStoredTabBeatsAVisibleLinkedTask() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.prompts.rawValue, linkedTask: visibleTask,
                                current: .todos, isMain: false),
            .prompts)
    }

    func testVisibleLinkedTaskSelectsTask() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, linkedTask: visibleTask, current: .todos, isMain: false),
            .task)
    }

    func testHiddenLinkedTaskPreservesCurrentDemotingTask() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, linkedTask: hiddenTask, current: .task, isMain: false),
            .todos)
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, linkedTask: hiddenTask, current: .prompts, isMain: false),
            .prompts)
    }

    func testNoLinkedTaskPreservesCurrentDemotingTask() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, linkedTask: nil, current: .task, isMain: false),
            .todos)
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, linkedTask: nil, current: .prompts, isMain: false),
            .prompts)
    }

    func testInvalidStoredRawValueFallsThrough() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: "NotARealTab", linkedTask: visibleTask,
                                current: .todos, isMain: false),
            .task)
    }

    // A worktree persisted on the deleted "Notes" tab must fall back to a valid tab.
    func testPersistedNotesTabFallsBackToValidTab() {
        let resolved = resolveSidePanelTab(stored: "Notes", linkedTask: nil,
                                           current: .prompts, isMain: false)
        XCTAssertEqual(resolved, .prompts)
        XCTAssertTrue(SidePanelTab.available(isMain: false).contains(resolved))
    }

    func testMainClampsAVisibleLinkedTaskToTodos() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, linkedTask: visibleTask, current: .task, isMain: true),
            .todos)
    }

    func testMainDropsStoredTaskFallingBackToCurrent() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.task.rawValue, linkedTask: visibleTask,
                                current: .prompts, isMain: true),
            .prompts)
    }

    func testMainClampsStoredAndCurrentTaskToTodos() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.task.rawValue, linkedTask: visibleTask,
                                current: .task, isMain: true),
            .todos)
    }

    func testMainKeepsStoredNonTaskTab() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: SidePanelTab.prompts.rawValue, linkedTask: visibleTask,
                                current: .todos, isMain: true),
            .prompts)
    }

    func testMainPreservesCurrentNonTaskTab() {
        XCTAssertEqual(
            resolveSidePanelTab(stored: nil, linkedTask: nil, current: .prompts, isMain: true),
            .prompts)
    }
}
