import CryptoKit
import XCTest
import GhosttyKit
@testable import Clearway

/// Harness tests for the stateful `WorkTaskCoordinator` side of the `WORKFLOW.json` loop engine:
/// the `start` seed, trust gating, and the watcher-driven advance/halt decisions.
///
/// These exercise everything *except* the actual Ghostty surface launch, which needs a live
/// `ghostty_app_t`. To stay surface-free the fixture workflow is left **untrusted**, so a `.launch`
/// decision short-circuits to `.needsTrust` *before* any surface is created — letting us assert the
/// engine reached a launch decision (legal advance, terminal end) without spawning a terminal. The
/// pure routing/validation logic itself is covered exhaustively in `WorkflowLoopEngineTests`.
@MainActor
final class WorkflowLoopEngineHarnessTests: XCTestCase {

    private var tempRoot: String!

    /// A non-null placeholder `ghostty_app_t` (`void*`). Never dereferenced: every assertion here
    /// drives a path that returns before `launchWorkflowAgent` would touch it.
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 0x1)!

    override func setUp() {
        super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-loop-harness-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root = tempRoot {
            // Clear any trust approval this test minted so runs stay independent.
            UserDefaults.standard.removeObject(forKey: trustDefaultsKey(forProject: root))
            try? FileManager.default.removeItem(atPath: root)
        }
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Fixture builders

    private static let workflowJSON = """
    {
      "version": 1,
      "start": "implement",
      "actions": {
        "implement": { "name": "Implement", "instructions": "Implement.", "routes": { "success": "test" } },
        "test": { "name": "Test", "instructions": "Test.", "routes": { "success": "review" } },
        "review": { "name": "Review", "instructions": "Review." }
      }
    }
    """

    /// Writes `.clearway/WORKFLOW.json` into the project root.
    private func writeWorkflow() throws {
        let clearway = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let path = (clearway as NSString).appendingPathComponent("WORKFLOW.json")
        try Self.workflowJSON.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Writes a worktree `TASK.md` with the given status (and optional autopilot) and returns the
    /// worktree path.
    @discardableResult
    private func writeWorktreeTask(branch: String, status: String, autopilot: Bool? = nil, id: UUID = UUID()) throws -> String {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let taskMd = (clearway as NSString).appendingPathComponent("TASK.md")
        var task = WorkTask(id: id, title: "Task", status: status, worktree: branch)
        task.autopilot = autopilot
        try task.serialized().write(toFile: taskMd, atomically: true, encoding: .utf8)
        return worktreePath
    }

    /// Builds a coordinator wired to a manager + worktree manager scoped to `tempRoot`, with one
    /// live worktree on `branch` at `worktreePath`.
    private func makeCoordinator(branch: String, worktreePath: String) -> WorkTaskCoordinator {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }
        taskManager.setWatchedWorktrees([worktreePath])

        let worktreeManager = WorktreeManager(projectPath: tempRoot)
        worktreeManager.worktrees = [
            Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached),
        ]
        return WorkTaskCoordinator(
            workTaskManager: taskManager,
            terminalManager: TerminalManager(),
            worktreeManager: worktreeManager
        )
    }

    /// Builds a coordinator over several live worktrees (their `TASK.md` files must already be
    /// written via `writeWorktreeTask`). Used by restart-resume tests that stage a mix of worktrees.
    private func makeMultiCoordinator(_ pairs: [(branch: String, path: String)]) -> WorkTaskCoordinator {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        taskManager.worktreeResolver = { pairs }
        taskManager.setWatchedWorktrees(pairs.map(\.path))

        let worktreeManager = WorktreeManager(projectPath: tempRoot)
        worktreeManager.worktrees = pairs.map {
            Worktree(branch: $0.branch, path: $0.path, isMain: false, headStatus: .attached)
        }
        return WorkTaskCoordinator(
            workTaskManager: taskManager,
            terminalManager: TerminalManager(),
            worktreeManager: worktreeManager
        )
    }

    /// Mirrors `WorkflowDefinition`'s private trust key so the test can clear it in `tearDown`.
    private func trustDefaultsKey(forProject projectPath: String) -> String {
        let hash = SHA256Hex(projectPath)
        return "clearway.workflow.json.trusted.\(hash)"
    }

    // MARK: - Seed

    func testSeedWritesStartStatus() throws {
        try writeWorkflow()
        let branch = "seed"
        let worktreePath = try writeWorktreeTask(branch: branch, status: WorkTask.ReservedStatus.inProgress)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.seedWorkflowStatus(forBranch: branch)

        let task = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(task?.status, "implement", "seed writes the workflow's start slug")
    }

    func testSeedIsNoOpWithoutJSONWorkflow() throws {
        // No WORKFLOW.json written — legacy project, seed must not touch status.
        let branch = "legacy"
        let worktreePath = try writeWorktreeTask(branch: branch, status: WorkTask.ReservedStatus.inProgress)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.seedWorkflowStatus(forBranch: branch)

        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.status,
                       WorkTask.ReservedStatus.inProgress,
                       "a project without WORKFLOW.json is untouched by the seed")
    }

    // MARK: - Trust gating

    func testUntrustedWorkflowDoesNotLaunch() throws {
        try writeWorkflow()
        let branch = "trust"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .needsTrust,
                       "executable WORKFLOW.json must not run until approved — it surfaces instead")
    }

    func testTrustGateClearsAfterApproval() throws {
        try writeWorkflow()
        let branch = "trust2"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.approveJSONWorkflowTrust()
        // Now a legal launch decision would proceed to a real surface, which the harness can't
        // create — so we only assert the gate itself flipped, via the model API.
        XCTAssertTrue(WorkflowDefinition.isTrusted(projectPath: tempRoot),
                      "approval marks the current WORKFLOW.json bytes trusted")
    }

    // MARK: - Advance / halt (untrusted → launch short-circuits to needsTrust)

    func testLegalAdvanceReachesLaunchDecision() throws {
        try writeWorkflow()
        let branch = "advance"
        // Running `implement`; agent wrote `test` (a legal route). Untrusted → needsTrust proves the
        // decision was `.launch` (an illegal value would have returned `.halted` regardless of trust).
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .needsTrust, "a legal advance reaches the (trust-gated) launch path")
    }

    func testIllegalValueHalts() throws {
        try writeWorkflow()
        let branch = "illegal"
        // Running `implement`; agent wrote `review` — a real action but not reachable from implement.
        let worktreePath = try writeWorktreeTask(branch: branch, status: "review")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        guard case .halted = result else { return XCTFail("expected halt, got \(result)") }
        XCTAssertNotNil(coordinator.workTaskManager.task(forWorktree: branch)?.errorMessage,
                        "halt surfaces an errorMessage on the task")
    }

    func testUnknownSlugHalts() throws {
        try writeWorkflow()
        let branch = "unknown"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "frobnicate")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        guard case .halted = result else { return XCTFail("expected halt, got \(result)") }
    }

    // MARK: - Autopilot pause (advance gating)

    /// A paused worktree (`autopilot: false`) never advances: a legal next status that would launch
    /// is suppressed to `.ignored` *before* the trust gate, so the running step finishes and nothing
    /// new starts. (An unpaused legal advance reaches `.needsTrust` here — see
    /// `testLegalAdvanceReachesLaunchDecision` — so `.ignored` proves the pause, not a trust stall.)
    func testAutopilotFalsePausesAdvance() throws {
        try writeWorkflow()
        let branch = "paused"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: false)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .ignored, "a paused worktree does not advance even on a legal next status")
    }

    /// Re-enabling reaches the (trust-gated) launch of the current action: with the workflow
    /// approved removed for surface-safety, an enabled worktree whose status sits on a real action
    /// resolves to `.needsTrust` (the launch path) rather than `.ignored` (the pause path).
    func testAutopilotTrueReachesAdvance() throws {
        try writeWorkflow()
        let branch = "enabled"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .needsTrust, "an enabled worktree reaches the (trust-gated) launch path")
    }

    // MARK: - Agent-running accessor (toolbar activity indicator)

    /// `isAgentRunning(forWorktree:)` — the read-only window the toolbar's activity indicator reads —
    /// is false for an idle worktree and true once a running action (`P`) is staged, matching how the
    /// engine sets `runningAction` in lockstep with the live agent surface.
    func testIsAgentRunningReflectsRunningAction() throws {
        try writeWorkflow()
        let branch = "activity"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        let worktreeId = Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached).id

        XCTAssertFalse(coordinator.isAgentRunning(forWorktree: worktreeId), "idle worktree has no running step")

        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        XCTAssertTrue(coordinator.isAgentRunning(forWorktree: worktreeId), "a staged running action reads as running")
    }

    // MARK: - Restart resume

    /// Restart-resume relaunches only `autopilot: true` worktrees sitting on a real, non-terminal
    /// action. A paused (`false`), terminal, or backlog worktree stays put. The fixture workflow is
    /// untrusted, so a worktree that *reaches* the resume launch short-circuits to `.needsTrust`,
    /// which `surfaceNeedsTrust` records as an errorMessage — the observable proof it tried to resume.
    /// A worktree that never reaches the launch path keeps a nil errorMessage.
    func testResumeRelaunchesOnlyAutopiloted() throws {
        try writeWorkflow()
        let trustMessage = "Workflow paused: .clearway/WORKFLOW.json is not trusted. Approve it to run."

        // resumable: autopilot on, mid-loop on a real non-terminal action.
        let resumePath = try writeWorktreeTask(branch: "resume", status: "test", autopilot: true)
        // paused: autopilot off — must NOT resume.
        let pausedPath = try writeWorktreeTask(branch: "paused", status: "test", autopilot: false)
        // terminal: routeless action already ran — must NOT resume.
        let terminalPath = try writeWorktreeTask(branch: "term", status: "review", autopilot: true)
        // backlog marker — not a running loop — must NOT resume.
        let backlogPath = try writeWorktreeTask(branch: "back", status: WorkTask.ReservedStatus.new, autopilot: true)

        let coordinator = makeMultiCoordinator([
            (branch: "resume", path: resumePath),
            (branch: "paused", path: pausedPath),
            (branch: "term", path: terminalPath),
            (branch: "back", path: backlogPath),
        ])
        coordinator.appProvider = { [dummyApp] in dummyApp }

        coordinator.resumeWorkflowsOnStartup()

        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: "resume")?.errorMessage, trustMessage,
                       "the autopilot:true mid-loop worktree reached the resume launch path")
        XCTAssertNil(coordinator.workTaskManager.task(forWorktree: "paused")?.errorMessage,
                     "a paused worktree must not resume")
        XCTAssertNil(coordinator.workTaskManager.task(forWorktree: "term")?.errorMessage,
                     "a terminal worktree must not resume")
        XCTAssertNil(coordinator.workTaskManager.task(forWorktree: "back")?.errorMessage,
                     "a backlog worktree must not resume")
    }

    /// Restart-resume runs once per window: the `didResumeWorkflows` one-shot guard means a second
    /// call does nothing (the first already drove the resume decisions).
    func testResumeRunsOnce() throws {
        try writeWorkflow()
        let path = try writeWorktreeTask(branch: "once", status: "test", autopilot: true)
        let coordinator = makeMultiCoordinator([(branch: "once", path: path)])
        coordinator.appProvider = { [dummyApp] in dummyApp }

        coordinator.resumeWorkflowsOnStartup()
        XCTAssertTrue(coordinator.didResumeWorkflows, "resume marks the one-shot guard after running")

        // Clear the surfaced message; a second call must not re-run resume (so it stays cleared).
        if var task = coordinator.workTaskManager.task(forWorktree: "once") {
            task.errorMessage = nil
            coordinator.workTaskManager.updateTask(task)
        }
        coordinator.resumeWorkflowsOnStartup()
        XCTAssertNil(coordinator.workTaskManager.task(forWorktree: "once")?.errorMessage,
                     "a second resume call is a no-op (guard already set)")
    }

    // MARK: - Agent-exit clears runningAction (stranded-worktree fix)

    /// When the worktree's CURRENTLY-tracked live agent exits, the exit-decision helper says to clear
    /// live-agent state (`agentSurfaces` + `runningAction`). The real `handleChildExited` path needs a
    /// Ghostty surface, so we test the pure decision directly with stand-in reference objects.
    func testLiveAgentExitClearsRunningActionDecision() {
        let live = NSObject()
        XCTAssertTrue(
            WorkTaskCoordinator.shouldClearLiveAgentState(exitingSurface: live, liveAgentSurface: live),
            "the live agent's own exit must clear runningAction so a later relaunch/advance can re-fire"
        )
    }

    /// A superseded (old) surface exiting AFTER a normal advance already swapped in the next action's
    /// surface must NOT clear state — otherwise it would wipe the next action's freshly-set
    /// `runningAction`. The decision is keyed on identity vs. the *current* live surface.
    func testSupersededAgentExitDoesNotClearRunningActionDecision() {
        let oldSurface = NSObject()
        let newSurface = NSObject()
        XCTAssertFalse(
            WorkTaskCoordinator.shouldClearLiveAgentState(exitingSurface: oldSurface, liveAgentSurface: newSurface),
            "a superseded surface's exit must leave the next action's runningAction intact"
        )
        // And a worktree with no tracked live surface (already cleared) also must not re-trigger.
        XCTAssertFalse(
            WorkTaskCoordinator.shouldClearLiveAgentState(exitingSurface: oldSurface, liveAgentSurface: nil),
            "no live surface means nothing to clear"
        )
    }

    /// End-to-end at the coordinator state level, exercising the exact guard the fix unblocks.
    /// `relaunchCurrentAction` (the autopilot-flip / restart-resume path, reached here via
    /// `resumeWorkflowsOnStartup`) skips a worktree whose `runningAction` already equals its `status`.
    /// If an agent crashes BEFORE writing its next status, that stale `runningAction` would strand the
    /// worktree forever. Clearing it on the live agent's exit lets the resume re-fire — observable as
    /// the trust message `surfaceNeedsTrust` records once the relaunch reaches the (untrusted) launch.
    /// We drive `runningAction` directly because the surface-exit notification needs a live Ghostty app.
    func testRunningActionClearedAllowsResumeAfterExit() throws {
        try writeWorkflow()
        let trustMessage = "Workflow paused: .clearway/WORKFLOW.json is not trusted. Approve it to run."
        let branch = "exit-resume"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)

        // STRANDED case: runningAction still set to the current status (agent died before advancing).
        // resumeWorkflowsOnStartup → relaunchCurrentAction's `runningAction != status` guard is FALSE,
        // so nothing relaunches and no trust message is surfaced.
        let stranded = makeCoordinator(branch: branch, worktreePath: worktreePath)
        stranded.appProvider = { [dummyApp] in dummyApp }
        stranded.setRunningActionForTesting("test", branch: branch, worktreePath: worktreePath)
        stranded.resumeWorkflowsOnStartup()
        XCTAssertNil(stranded.workTaskManager.task(forWorktree: branch)?.errorMessage,
                     "a stale runningAction == status blocks the resume relaunch (the stranded bug)")

        // FIXED case: the live agent's exit cleared runningAction (the guarded handleChildExited
        // branch). Now relaunchCurrentAction's guard passes and the resume reaches the launch path,
        // surfacing the trust message — proof the worktree is no longer stranded.
        let resumed = makeCoordinator(branch: branch, worktreePath: worktreePath)
        resumed.appProvider = { [dummyApp] in dummyApp }
        // runningAction left unset = the cleared state after the live agent exited.
        resumed.resumeWorkflowsOnStartup()
        XCTAssertEqual(resumed.workTaskManager.task(forWorktree: branch)?.errorMessage, trustMessage,
                       "clearing runningAction on the live agent's exit lets resume relaunch the action")
    }

    func testSameStatusAsRunningIsIgnored() throws {
        try writeWorkflow()
        let branch = "idem"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .ignored, "a write equal to the running action is idempotently ignored")
    }

    // MARK: - Manual kill

    /// The manual kill pauses the loop by writing `autopilot = false` — the half that needs no
    /// Ghostty surface. (Surface termination is exercised via `shouldTerminateOnManualKill` below,
    /// since a live surface needs a real app.)
    func testManualKillPausesAutopilot() throws {
        try writeWorkflow()
        let branch = "kill"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.manualKill(forBranch: branch)

        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.autopilot, false,
                       "the manual kill pauses the loop by writing autopilot = false")
    }

    /// The surface-termination *decision* is false when no live agent surface is tracked, so a kill
    /// on an idle worktree pauses without requesting a (nonexistent) termination.
    func testManualKillDoesNotTerminateWhenNoSurface() throws {
        try writeWorkflow()
        let branch = "kill-idle"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        let worktreeId = Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached).id

        XCTAssertFalse(coordinator.shouldTerminateOnManualKill(forWorktree: worktreeId),
                       "no tracked agent surface means nothing to terminate")
        // The kill still pauses, even with nothing to terminate.
        coordinator.manualKill(forBranch: branch)
        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.autopilot, false)
    }

    /// `manualKill` on a branch with no task is a safe no-op (nothing to pause or terminate).
    func testManualKillNoTaskIsNoOp() throws {
        try writeWorkflow()
        let branch = "kill-notask"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.manualKill(forBranch: "nonexistent-branch")
        // The real branch is untouched.
        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.autopilot, true,
                       "killing an unknown branch leaves other worktrees untouched")
    }

    // MARK: - Reserved cap fields are decoded but not enforced (trust ordering)

    /// `max_attempts` is a reserved, NOT-enforced field in v1 (manual kill is the loop-stopper). A
    /// workflow carrying it still decodes/validates and launches exactly like any other: the launch
    /// path trust-gates first, so an untrusted self-routing action surfaces `.needsTrust` rather than
    /// any cap-driven halt. This pins that the reserved field never short-circuits a launch.
    func testReservedMaxAttemptsFieldDoesNotBlockLaunch() throws {
        let clearway = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let withReservedField = """
        {
          "version": 1,
          "start": "fix",
          "actions": {
            "fix": { "name": "Fix", "instructions": "Fix.", "routes": { "again": "fix" }, "max_attempts": 1 }
          }
        }
        """
        try withReservedField.write(toFile: (clearway as NSString).appendingPathComponent("WORKFLOW.json"),
                                    atomically: true, encoding: .utf8)
        let branch = "reserved"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "fix", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        // First write of `start` (no runningAction) reaches the launch path, which trust-gates first.
        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .needsTrust,
                       "a workflow carrying the reserved max_attempts field still trust-gates and launches normally")
    }
}

/// SHA-256 hex prefix matching `WorkflowDefinition`'s trust-key derivation (test-local helper).
private func SHA256Hex(_ string: String) -> String {
    let digest = SHA256.hash(data: Data(string.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}
