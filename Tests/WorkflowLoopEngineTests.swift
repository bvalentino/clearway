import XCTest
@testable import Clearway

/// Direct tests for the pure transition decision at the heart of the `WORKFLOW.json` loop engine.
/// No file watchers, no Ghostty — `decideTransition` is a side-effect-free function of
/// (running action `P`, written status `S`, definition), so the routing/validation contract is
/// exercised here in isolation. Launch + injection plumbing is covered by `buildPrompt`.
final class WorkflowLoopEngineTests: XCTestCase {

    // MARK: - Fixture

    /// The canonical implement → test → review graph from the spec brief. `review` is terminal
    /// (no routes). Decoded from JSON so the fixture mirrors a real `WORKFLOW.json`.
    private static let implementTestReview: WorkflowDefinition = {
        let json = """
        {
          "version": 1,
          "start": "implement",
          "actions": {
            "implement": {
              "name": "Implement",
              "instructions": "Implement the task.",
              "routes": { "success": "test" }
            },
            "test": {
              "name": "Test",
              "instructions": "Run the tests.",
              "routes": { "success": "review" }
            },
            "review": {
              "name": "Review",
              "instructions": "Review the diff."
            }
          }
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(WorkflowDefinition.self, from: Data(json.utf8))
    }()

    private var definition: WorkflowDefinition { Self.implementTestReview }

    // MARK: - First launch (seed)

    func testFirstLaunchOnStartLaunchesStartAction() {
        let result = WorkflowLoopEngine.decideTransition(running: nil, written: "implement", definition: definition)
        XCTAssertEqual(result, .launch(slug: "implement", nextValue: "test"))
    }

    func testSeedValueEqualsStart() {
        XCTAssertEqual(definition.start, "implement",
                       "the seed the engine writes is the workflow's start slug")
    }

    func testFirstWriteOfNonStartActionHalts() {
        // `test` is a real action but not `start`; writing it before anything ran is illegal.
        let result = WorkflowLoopEngine.decideTransition(running: nil, written: "test", definition: definition)
        guard case .halt = result else {
            return XCTFail("expected halt for a non-start first value, got \(result)")
        }
    }

    // MARK: - Legal advance

    func testLegalAdvanceLaunchesNextAction() {
        let result = WorkflowLoopEngine.decideTransition(running: "implement", written: "test", definition: definition)
        XCTAssertEqual(result, .launch(slug: "test", nextValue: "review"))
    }

    func testLegalAdvanceIntoTerminalLaunchesWithNoNextValue() {
        let result = WorkflowLoopEngine.decideTransition(running: "test", written: "review", definition: definition)
        XCTAssertEqual(result, .launch(slug: "review", nextValue: nil),
                       "a routeless action launches with no advance value injected")
    }

    // MARK: - Halt

    func testIllegalAdvanceHalts() {
        // `review` is a real action but not reachable from `implement` (only `test` is).
        let result = WorkflowLoopEngine.decideTransition(running: "implement", written: "review", definition: definition)
        guard case .halt = result else {
            return XCTFail("expected halt for an illegal route, got \(result)")
        }
    }

    func testUnknownSlugHalts() {
        let result = WorkflowLoopEngine.decideTransition(running: "implement", written: "frobnicate", definition: definition)
        guard case .halt = result else {
            return XCTFail("expected halt for an unknown slug, got \(result)")
        }
    }

    // MARK: - Ignore

    func testSameStatusAsRunningIsIgnored() {
        let result = WorkflowLoopEngine.decideTransition(running: "implement", written: "implement", definition: definition)
        XCTAssertEqual(result, .ignore, "S == P is a mid-step edit — ignore")
    }

    func testBacklogMarkersAreIgnored() {
        for marker in [WorkTask.ReservedStatus.new, WorkTask.ReservedStatus.readyToStart] {
            let result = WorkflowLoopEngine.decideTransition(running: "implement", written: marker, definition: definition)
            XCTAssertEqual(result, .ignore, "backlog marker '\(marker)' is not the engine's concern")
        }
    }

    // MARK: - Idempotent double-fire

    func testTerminalActionRunsOnceThenEnds() {
        // Once `review` is running, re-seeing `review` is S == P → ignore (no relaunch).
        let first = WorkflowLoopEngine.decideTransition(running: "test", written: "review", definition: definition)
        XCTAssertEqual(first, .launch(slug: "review", nextValue: nil))
        let second = WorkflowLoopEngine.decideTransition(running: "review", written: "review", definition: definition)
        XCTAssertEqual(second, .ignore, "the terminal action does not relaunch on a repeated write")
    }

    func testDoubleFireOfSameAdvanceLaunchesOnce() {
        // First advance: implement → test launches.
        let first = WorkflowLoopEngine.decideTransition(running: "implement", written: "test", definition: definition)
        XCTAssertEqual(first, .launch(slug: "test", nextValue: "review"))
        // After the launch, `test` is running; a second identical write is S == P → ignore.
        let second = WorkflowLoopEngine.decideTransition(running: "test", written: "test", definition: definition)
        XCTAssertEqual(second, .ignore, "the same status written twice yields a single launch")
    }

    // MARK: - Prompt injection

    func testBuildPromptAppendsAdvanceContract() {
        let prompt = WorkflowLoopEngine.buildPrompt(instructions: "Do the work.", nextValue: "review")
        XCTAssertEqual(prompt, """
        Do the work.

        [Clearway] When finished, set `status:` in .clearway/TASK.md to: review
        Write it last.
        """)
    }

    func testBuildPromptTerminalAppendsNoContract() {
        let prompt = WorkflowLoopEngine.buildPrompt(instructions: "Review the diff.", nextValue: nil)
        XCTAssertEqual(prompt, "Review the diff.",
                       "a terminal action gets its instructions verbatim with no advance contract")
    }
}
