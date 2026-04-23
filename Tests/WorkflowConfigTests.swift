import XCTest
@testable import Clearway

final class WorkflowConfigTests: XCTestCase {

    // MARK: - stateCommand

    /// When only `promptTemplate` is set, `stateCommand(for: .inProgress)` must
    /// return nil — auto mode must never fire on the implicit body fallback.
    func testExplicitStateCommandNilWhenOnlyPromptTemplate() {
        let config = WorkflowConfig(promptTemplate: "Work on {{ task.title }}")
        XCTAssertNil(config.stateCommand(for: .inProgress))
        XCTAssertTrue(config.hasStateCommand(for: .inProgress),
                      "hasStateCommand (used by the play button) still returns true for the body fallback")
    }

    /// When `state_commands.in_progress` is explicit, `stateCommand` returns it.
    func testExplicitStateCommandReturnsConfiguredValue() {
        let config = WorkflowConfig(
            stateCommandInProgress: "claude /work",
            promptTemplate: ""
        )
        XCTAssertEqual(config.stateCommand(for: .inProgress), "claude /work")
    }

    /// All five state-command slots are reachable.
    func testExplicitStateCommandCoversAllStatuses() {
        let config = WorkflowConfig(
            stateCommandInProgress: "in_progress_cmd",
            stateCommandQa: "qa_cmd",
            stateCommandReadyForReview: "rfr_cmd",
            stateCommandDone: "done_cmd",
            stateCommandCanceled: "canceled_cmd",
            promptTemplate: ""
        )
        XCTAssertEqual(config.stateCommand(for: .inProgress), "in_progress_cmd")
        XCTAssertEqual(config.stateCommand(for: .qa), "qa_cmd")
        XCTAssertEqual(config.stateCommand(for: .readyForReview), "rfr_cmd")
        XCTAssertEqual(config.stateCommand(for: .done), "done_cmd")
        XCTAssertEqual(config.stateCommand(for: .canceled), "canceled_cmd")
        XCTAssertNil(config.stateCommand(for: .new))
        XCTAssertNil(config.stateCommand(for: .readyToStart))
    }

    // MARK: - hasAnyExplicitStateCommand

    /// The toolbar gate is false when only `promptTemplate` is set.
    func testHasAnyExplicitStateCommandFalseWhenOnlyPromptTemplate() {
        let config = WorkflowConfig(promptTemplate: "Work on {{ task.title }}")
        XCTAssertFalse(config.hasAnyExplicitStateCommand)
    }

    /// The toolbar gate is true when any single state-command slot is set.
    func testHasAnyExplicitStateCommandTrueForEachSlot() {
        let slots: [(String, WorkflowConfig)] = [
            ("inProgress", WorkflowConfig(stateCommandInProgress: "x", promptTemplate: "")),
            ("qa", WorkflowConfig(stateCommandQa: "x", promptTemplate: "")),
            ("readyForReview", WorkflowConfig(stateCommandReadyForReview: "x", promptTemplate: "")),
            ("done", WorkflowConfig(stateCommandDone: "x", promptTemplate: "")),
            ("canceled", WorkflowConfig(stateCommandCanceled: "x", promptTemplate: "")),
        ]
        for (label, config) in slots {
            XCTAssertTrue(config.hasAnyExplicitStateCommand, "slot: \(label) must enable the gate")
        }
    }

    func testHasAnyExplicitStateCommandFalseForEmptyConfig() {
        let config = WorkflowConfig(promptTemplate: "")
        XCTAssertFalse(config.hasAnyExplicitStateCommand)
    }
}
