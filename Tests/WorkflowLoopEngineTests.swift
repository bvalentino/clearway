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
        let result = WorkflowLoopEngine.decideTransition(running: nil, written: "implement", autopilot: true, definition: definition)
        XCTAssertEqual(result, .launch(slug: "implement", nextValue: "test"))
    }

    func testSeedValueEqualsStart() {
        XCTAssertEqual(definition.start, "implement",
                       "the seed the engine writes is the workflow's start slug")
    }

    func testFirstWriteOfNonStartActionHalts() {
        // `test` is a real action but not `start`; writing it before anything ran is illegal.
        let result = WorkflowLoopEngine.decideTransition(running: nil, written: "test", autopilot: true, definition: definition)
        guard case .halt = result else {
            return XCTFail("expected halt for a non-start first value, got \(result)")
        }
    }

    // MARK: - Legal advance

    func testLegalAdvanceLaunchesNextAction() {
        let result = WorkflowLoopEngine.decideTransition(running: "implement", written: "test", autopilot: true, definition: definition)
        XCTAssertEqual(result, .launch(slug: "test", nextValue: "review"))
    }

    func testLegalAdvanceIntoTerminalLaunchesWithNoNextValue() {
        let result = WorkflowLoopEngine.decideTransition(running: "test", written: "review", autopilot: true, definition: definition)
        XCTAssertEqual(result, .launch(slug: "review", nextValue: nil),
                       "a routeless action launches with no advance value injected")
    }

    // MARK: - Halt

    func testIllegalAdvanceHalts() {
        // `review` is a real action but not reachable from `implement` (only `test` is).
        let result = WorkflowLoopEngine.decideTransition(running: "implement", written: "review", autopilot: true, definition: definition)
        guard case .halt = result else {
            return XCTFail("expected halt for an illegal route, got \(result)")
        }
    }

    func testUnknownSlugHalts() {
        let result = WorkflowLoopEngine.decideTransition(running: "implement", written: "frobnicate", autopilot: true, definition: definition)
        guard case .halt = result else {
            return XCTFail("expected halt for an unknown slug, got \(result)")
        }
    }

    // MARK: - Ignore

    func testSameStatusAsRunningIsIgnored() {
        let result = WorkflowLoopEngine.decideTransition(running: "implement", written: "implement", autopilot: true, definition: definition)
        XCTAssertEqual(result, .ignore, "S == P is a mid-step edit — ignore")
    }

    func testBacklogMarkersAreIgnored() {
        for marker in [WorkTask.ReservedStatus.new, WorkTask.ReservedStatus.readyToStart] {
            let result = WorkflowLoopEngine.decideTransition(running: "implement", written: marker, autopilot: true, definition: definition)
            XCTAssertEqual(result, .ignore, "backlog marker '\(marker)' is not the engine's concern")
        }
    }

    // MARK: - Idempotent double-fire

    func testTerminalActionRunsOnceThenEnds() {
        // Once `review` is running, re-seeing `review` is S == P → ignore (no relaunch).
        let first = WorkflowLoopEngine.decideTransition(running: "test", written: "review", autopilot: true, definition: definition)
        XCTAssertEqual(first, .launch(slug: "review", nextValue: nil))
        let second = WorkflowLoopEngine.decideTransition(running: "review", written: "review", autopilot: true, definition: definition)
        XCTAssertEqual(second, .ignore, "the terminal action does not relaunch on a repeated write")
    }

    func testDoubleFireOfSameAdvanceLaunchesOnce() {
        // First advance: implement → test launches.
        let first = WorkflowLoopEngine.decideTransition(running: "implement", written: "test", autopilot: true, definition: definition)
        XCTAssertEqual(first, .launch(slug: "test", nextValue: "review"))
        // After the launch, `test` is running; a second identical write is S == P → ignore.
        let second = WorkflowLoopEngine.decideTransition(running: "test", written: "test", autopilot: true, definition: definition)
        XCTAssertEqual(second, .ignore, "the same status written twice yields a single launch")
    }

    // MARK: - Multi-route (v1 deterministic injection)

    /// A 2-route action documenting v1 behavior: the prompt injection uses the deterministic
    /// (sorted-first) next value, while `decideTransition` still accepts EITHER legal route value as
    /// a valid advance — so a branch landing on the non-first route later doesn't break the loop.
    func testMultiRouteActionInjectsDeterministicNextAndAcceptsAnyLegalRoute() {
        let json = """
        {
          "version": 1,
          "start": "implement",
          "actions": {
            "implement": {
              "name": "Implement",
              "instructions": "Implement the task.",
              "routes": { "pass": "review", "fail": "fix" }
            },
            "review": { "name": "Review", "instructions": "Review the diff." },
            "fix": { "name": "Fix", "instructions": "Fix the failure." }
          }
        }
        """
        // swiftlint:disable:next force_try
        let multi = try! JSONDecoder().decode(WorkflowDefinition.self, from: Data(json.utf8))

        // legalNext is deterministic (sorted): "fix" < "review".
        XCTAssertEqual(multi.legalNext(from: "implement"), ["fix", "review"])

        // Injection uses the deterministic sorted-first value ("fix").
        let launch = WorkflowLoopEngine.decideTransition(running: nil, written: "implement", autopilot: true, definition: multi)
        XCTAssertEqual(launch, .launch(slug: "implement", nextValue: "fix"),
                       "the injected next value is the deterministic sorted-first route target")

        // Both legal route targets are accepted as a valid advance from `implement`.
        let advanceToFix = WorkflowLoopEngine.decideTransition(running: "implement", written: "fix", autopilot: true, definition: multi)
        XCTAssertEqual(advanceToFix, .launch(slug: "fix", nextValue: nil),
                       "the sorted-first route is a legal advance")
        let advanceToReview = WorkflowLoopEngine.decideTransition(running: "implement", written: "review", autopilot: true, definition: multi)
        XCTAssertEqual(advanceToReview, .launch(slug: "review", nextValue: nil),
                       "the other legal route is also accepted, not halted")
    }

    // MARK: - Autopilot (pause gate)

    /// `autopilot == false` pauses: a decision that would launch is demoted to `.ignore` so nothing
    /// new starts (the running step finishes untouched). Covers both first-launch and advance.
    func testAutopilotFalsePausesLaunch() {
        let firstLaunch = WorkflowLoopEngine.decideTransition(
            running: nil, written: "implement", autopilot: false, definition: definition)
        XCTAssertEqual(firstLaunch, .ignore, "paused: the start action does not launch")

        let advance = WorkflowLoopEngine.decideTransition(
            running: "implement", written: "test", autopilot: false, definition: definition)
        XCTAssertEqual(advance, .ignore, "paused: a legal advance does not launch")
    }

    /// Pausing never masks a halt: an illegal/unknown write still surfaces even while paused, so a
    /// bad value isn't silently swallowed by autopilot-off.
    func testAutopilotFalseStillHalts() {
        let illegal = WorkflowLoopEngine.decideTransition(
            running: "implement", written: "review", autopilot: false, definition: definition)
        guard case .halt = illegal else {
            return XCTFail("paused loop must still halt on an illegal route, got \(illegal)")
        }
    }

    /// Enabling (autopilot true) launches the current/next action — this is the resume the pure
    /// function expresses; the coordinator's flip detection drives it from the watcher.
    func testAutopilotTrueLaunchesAsNormal() {
        let result = WorkflowLoopEngine.decideTransition(
            running: "implement", written: "test", autopilot: true, definition: definition)
        XCTAssertEqual(result, .launch(slug: "test", nextValue: "review"))
    }

    /// `autopilot == nil` (a flag-less worktree) is treated as on — it launches rather than silently
    /// pausing, so a missing flag never strands a JSON-workflow loop.
    func testAutopilotNilLaunchesAsNormal() {
        let result = WorkflowLoopEngine.decideTransition(
            running: "implement", written: "test", autopilot: nil, definition: definition)
        XCTAssertEqual(result, .launch(slug: "test", nextValue: "review"))
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
