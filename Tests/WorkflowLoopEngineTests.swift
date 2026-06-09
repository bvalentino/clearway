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

    // MARK: - Restart resume policy (pure)

    /// Only an `autopilot: true` worktree sitting on a real, non-terminal action resumes on restart.
    func testResumesAutopilotTrueOnRealAction() {
        XCTAssertTrue(WorkflowLoopEngine.shouldResumeOnRestart(
            status: "test", autopilot: true, definition: definition))
    }

    /// A paused worktree (`autopilot: false`) never auto-resumes — it stays paused across restarts.
    func testDoesNotResumePausedWorktree() {
        XCTAssertFalse(WorkflowLoopEngine.shouldResumeOnRestart(
            status: "test", autopilot: false, definition: definition))
    }

    /// A flag-less worktree (`autopilot: nil`, e.g. legacy / not-applicable) does not auto-resume.
    func testDoesNotResumeWhenAutopilotAbsent() {
        XCTAssertFalse(WorkflowLoopEngine.shouldResumeOnRestart(
            status: "test", autopilot: nil, definition: definition))
    }

    /// A terminal (routeless) action already ran and ended the loop — never relaunch it on restart.
    func testDoesNotResumeTerminalAction() {
        XCTAssertFalse(WorkflowLoopEngine.shouldResumeOnRestart(
            status: "review", autopilot: true, definition: definition),
            "a routeless action ended the loop; restart must not re-run it")
    }

    /// Backlog markers are pre-worktree, not a running loop — they don't resume.
    func testDoesNotResumeBacklogMarkers() {
        for marker in [WorkTask.ReservedStatus.new, WorkTask.ReservedStatus.readyToStart] {
            XCTAssertFalse(WorkflowLoopEngine.shouldResumeOnRestart(
                status: marker, autopilot: true, definition: definition),
                "backlog marker '\(marker)' is not a resumable loop state")
        }
    }

    /// An unknown slug (a halted loop's bad value, or a hand-edit) has no action to launch — stay put.
    func testDoesNotResumeUnknownSlug() {
        XCTAssertFalse(WorkflowLoopEngine.shouldResumeOnRestart(
            status: "frobnicate", autopilot: true, definition: definition))
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

    // MARK: - Loop guard (per-action entry cap)

    /// A `fix ↔ test` graph where `fix` is capped at 2 re-entries with a `review` escape — the
    /// canonical loop-guard fixture. `fix` self-routes so it can re-enter itself (the bounded case).
    private static let cappedFixLoop: WorkflowDefinition = {
        let json = """
        {
          "version": 1,
          "start": "fix",
          "actions": {
            "fix": {
              "name": "Fix",
              "instructions": "Fix the failure.",
              "routes": { "again": "fix", "done": "test" },
              "max_attempts": 2,
              "on_max_attempts": "review"
            },
            "test": { "name": "Test", "instructions": "Run the tests.", "routes": { "success": "fix" } },
            "review": { "name": "Review", "instructions": "Escalate to a human." }
          }
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(WorkflowDefinition.self, from: Data(json.utf8))
    }()

    /// A capped action with NO escape — re-entering past the cap must halt, never loop forever.
    private static let cappedNoEscape: WorkflowDefinition = {
        let json = """
        {
          "version": 1,
          "start": "fix",
          "actions": {
            "fix": {
              "name": "Fix",
              "instructions": "Fix the failure.",
              "routes": { "again": "fix" },
              "max_attempts": 2
            }
          }
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(WorkflowDefinition.self, from: Data(json.utf8))
    }()

    /// First entry of a fresh (uncapped-context) action counts as 1, regardless of prior attempt.
    func testCapFreshEntryCountsAsOne() {
        let decision = WorkflowLoopEngine.applyEntryCap(
            entering: "fix", previousAction: "test", currentAttempt: 9,
            definition: Self.cappedFixLoop)
        XCTAssertEqual(decision, .proceed(newCount: 1),
                       "entering a different action than the one running resets the count to 1")
    }

    /// Re-entering the same action increments the persisted attempt count.
    func testCapReentryIncrements() {
        let decision = WorkflowLoopEngine.applyEntryCap(
            entering: "fix", previousAction: "fix", currentAttempt: 1,
            definition: Self.cappedFixLoop)
        XCTAssertEqual(decision, .proceed(newCount: 2), "a re-entry of the same action increments the count")
    }

    /// Exceeding the cap with an escape defined routes to the escape slug (count reset).
    func testCapExceededRoutesToEscape() {
        // currentAttempt 2 == maxAttempts; the next re-entry would be 3 > 2 → escape.
        let decision = WorkflowLoopEngine.applyEntryCap(
            entering: "fix", previousAction: "fix", currentAttempt: 2,
            definition: Self.cappedFixLoop)
        XCTAssertEqual(decision, .routeToEscape(slug: "review", newCount: 1),
                       "exceeding the cap routes to on_max_attempts instead of relaunching the capped action")
    }

    /// Exceeding the cap with NO escape halts (never loop forever).
    func testCapExceededWithoutEscapeHalts() {
        let decision = WorkflowLoopEngine.applyEntryCap(
            entering: "fix", previousAction: "fix", currentAttempt: 2,
            definition: Self.cappedNoEscape)
        guard case .halt = decision else {
            return XCTFail("a capped action with no escape must halt past the cap, got \(decision)")
        }
    }

    /// Entering the cap's last permitted attempt still proceeds (boundary: count == maxAttempts).
    func testCapAtBoundaryProceeds() {
        let decision = WorkflowLoopEngine.applyEntryCap(
            entering: "fix", previousAction: "fix", currentAttempt: 1,
            definition: Self.cappedFixLoop)
        XCTAssertEqual(decision, .proceed(newCount: 2),
                       "count reaching maxAttempts is still within the cap; only exceeding it fires")
    }

    /// An uncapped action always proceeds, still tracking the count.
    func testUncappedActionAlwaysProceeds() {
        let reentry = WorkflowLoopEngine.applyEntryCap(
            entering: "test", previousAction: "test", currentAttempt: 50,
            definition: Self.cappedFixLoop)
        XCTAssertEqual(reentry, .proceed(newCount: 51), "an uncapped action proceeds and keeps counting")
    }

    /// Entering a different action resets the count even when the previous action was the capped one
    /// — the per-action count is consecutive-entry, so leaving the action clears it.
    func testCapResetsWhenActionChanges() {
        // Was running `fix` (count high); now entering `test` (a different, uncapped action).
        let decision = WorkflowLoopEngine.applyEntryCap(
            entering: "test", previousAction: "fix", currentAttempt: 99,
            definition: Self.cappedFixLoop)
        XCTAssertEqual(decision, .proceed(newCount: 1),
                       "the entry counter resets to 1 when the action slug changes")
    }

    /// First-ever launch (no previous action, no attempt) counts as 1.
    func testCapFirstLaunchNoPreviousCountsAsOne() {
        let decision = WorkflowLoopEngine.applyEntryCap(
            entering: "fix", previousAction: nil, currentAttempt: nil,
            definition: Self.cappedFixLoop)
        XCTAssertEqual(decision, .proceed(newCount: 1), "the first launch of an action counts as 1")
    }
}
