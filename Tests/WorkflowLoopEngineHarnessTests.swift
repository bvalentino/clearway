import XCTest
import GhosttyKit
@testable import Clearway

/// Harness tests for the stateful `WorkTaskCoordinator` side of the `WORKFLOW.json` loop engine:
/// the `start` seed and the watcher-driven advance / halt / resume decisions.
///
/// These exercise everything *except* the actual Ghostty surface launch, which needs a live
/// `ghostty_app_t`. To stay surface-free, each coordinator is given a no-op `workflowAgentLauncher`
/// (the production seam that normally spawns the surface) — so a `.launch` runs the engine's full
/// bookkeeping (`runningAction`, return value) without creating a terminal. Tests that need to count
/// or attribute launches override that seam with a recorder. The pure routing/validation logic is
/// covered exhaustively in `WorkflowLoopEngineTests`.
@MainActor
final class WorkflowLoopEngineHarnessTests: XCTestCase {

    private var tempRoot: String!

    /// A non-null placeholder `ghostty_app_t` (`void*`). Never dereferenced: the no-op launcher seam
    /// stands in for the real surface spawn, so `app` is only ever passed around, never touched.
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 0x1)!

    override func setUp() {
        super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-loop-harness-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root = tempRoot {
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
    private func writeWorktreeTask(branch: String, status: String, autopilot: Bool? = nil, title: String = "Task", id: UUID = UUID()) throws -> String {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let taskMd = (clearway as NSString).appendingPathComponent("TASK.md")
        var task = WorkTask(id: id, title: title, status: status, worktree: branch)
        task.autopilot = autopilot
        try task.serialized().write(toFile: taskMd, atomically: true, encoding: .utf8)
        return worktreePath
    }

    /// Builds a coordinator wired to a manager + worktree manager scoped to `tempRoot`, with one
    /// live worktree on `branch` at `worktreePath`. Installs a no-op launcher so any launch the test
    /// drives stays surface-free; tests that need to observe launches override it with a recorder.
    private func makeCoordinator(branch: String, worktreePath: String) -> WorkTaskCoordinator {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }
        taskManager.setWatchedWorktrees([worktreePath])

        let worktreeManager = WorktreeManager(projectPath: tempRoot)
        worktreeManager.worktrees = [
            Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached),
        ]
        let coordinator = WorkTaskCoordinator(
            workTaskManager: taskManager,
            terminalManager: TerminalManager(),
            worktreeManager: worktreeManager
        )
        coordinator.workflowAgentLauncher = { _, _, _, _ in }
        return coordinator
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
        let coordinator = WorkTaskCoordinator(
            workTaskManager: taskManager,
            terminalManager: TerminalManager(),
            worktreeManager: worktreeManager
        )
        coordinator.workflowAgentLauncher = { _, _, _, _ in }
        return coordinator
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

    func testSeedDefaultsAutopilotOnForTaskWithContent() throws {
        try writeWorkflow()
        let branch = "filled"
        let worktreePath = try writeWorktreeTask(branch: branch, status: WorkTask.ReservedStatus.new, title: "Add dark mode")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.seedWorkflowStatus(forBranch: branch)

        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.autopilot, true,
                       "a task with content defaults to autopilot on")
    }

    func testSeedStartsPausedForEmptyTask() throws {
        try writeWorkflow()
        let branch = "empty"
        // A manually-created worktree's shadow task: empty title + body, no content.
        let worktreePath = try writeWorktreeTask(branch: branch, status: WorkTask.ReservedStatus.inProgress, title: "")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.seedWorkflowStatus(forBranch: branch)

        let task = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(task?.status, "implement", "seed still positions the loop at start")
        XCTAssertEqual(task?.autopilot, false,
                       "an empty task starts paused — no point auto-running an agent on a blank TASK.md")
        XCTAssertTrue(coordinator.runningAction.isEmpty, "a paused empty task launches no agent")
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

    // MARK: - Advance / halt

    func testLegalAdvanceLaunchesNextAction() throws {
        try writeWorkflow()
        let branch = "advance"
        // Running `implement`; agent wrote `test` (a legal route) → the engine launches `test`.
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .launched(slug: "test"), "a legal advance launches the next action")
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
    /// is suppressed to `.ignored`, so the running step finishes and nothing new starts. (An unpaused
    /// legal advance launches — see `testLegalAdvanceLaunchesNextAction` — so `.ignored` proves the
    /// pause, not some other stall.)
    func testAutopilotFalsePausesAdvance() throws {
        try writeWorkflow()
        let branch = "paused"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: false)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .ignored, "a paused worktree does not advance even on a legal next status")
    }

    /// Re-enabling launches the current action: an enabled worktree whose status sits on a real
    /// action resolves to `.launched` (the launch path) rather than `.ignored` (the pause path).
    func testAutopilotTrueReachesAdvance() throws {
        try writeWorkflow()
        let branch = "enabled"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .launched(slug: "test"), "an enabled worktree launches the next action")
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
    /// action. A paused (`false`), terminal, or backlog worktree stays put. A launch recorder captures
    /// which worktrees actually reached the launch path — the observable proof of who resumed.
    func testResumeRelaunchesOnlyAutopiloted() throws {
        try writeWorkflow()

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
        var launchedBranches: [String] = []
        coordinator.workflowAgentLauncher = { _, _, worktree, _ in launchedBranches.append(worktree.branch ?? "?") }

        coordinator.resumeWorkflowsOnStartup()

        XCTAssertEqual(launchedBranches, ["resume"],
                       "only the autopilot:true mid-loop worktree reaches the resume launch path")
    }

    /// Restart-resume runs once per window: the `didResumeWorkflows` one-shot guard means a second
    /// call does nothing (the first already drove the resume launches).
    func testResumeRunsOnce() throws {
        try writeWorkflow()
        let path = try writeWorktreeTask(branch: "once", status: "test", autopilot: true)
        let coordinator = makeMultiCoordinator([(branch: "once", path: path)])
        coordinator.appProvider = { [dummyApp] in dummyApp }
        var launchCount = 0
        coordinator.workflowAgentLauncher = { _, _, _, _ in launchCount += 1 }

        coordinator.resumeWorkflowsOnStartup()
        XCTAssertTrue(coordinator.didResumeWorkflows, "resume marks the one-shot guard after running")
        XCTAssertEqual(launchCount, 1, "the autopilot:true worktree relaunched once")

        coordinator.resumeWorkflowsOnStartup()
        XCTAssertEqual(launchCount, 1, "a second resume call is a no-op (guard already set)")
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
    /// worktree forever. Clearing it on the live agent's exit lets the resume re-fire — observed here
    /// via a launch recorder: the stranded coordinator never launches, the cleared one launches once.
    /// We drive `runningAction` directly because the surface-exit notification needs a live Ghostty app.
    func testRunningActionClearedAllowsResumeAfterExit() throws {
        try writeWorkflow()
        let branch = "exit-resume"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)

        // STRANDED case: runningAction still set to the current status (agent died before advancing).
        // resumeWorkflowsOnStartup → relaunchCurrentAction's `runningAction != status` guard is FALSE,
        // so nothing relaunches.
        let stranded = makeCoordinator(branch: branch, worktreePath: worktreePath)
        stranded.appProvider = { [dummyApp] in dummyApp }
        var strandedLaunches = 0
        stranded.workflowAgentLauncher = { _, _, _, _ in strandedLaunches += 1 }
        stranded.setRunningActionForTesting("test", branch: branch, worktreePath: worktreePath)
        stranded.resumeWorkflowsOnStartup()
        XCTAssertEqual(strandedLaunches, 0,
                       "a stale runningAction == status blocks the resume relaunch (the stranded bug)")

        // FIXED case: the live agent's exit cleared runningAction (the guarded handleChildExited
        // branch). Now relaunchCurrentAction's guard passes and the resume reaches the launch path.
        let resumed = makeCoordinator(branch: branch, worktreePath: worktreePath)
        resumed.appProvider = { [dummyApp] in dummyApp }
        var resumedLaunches = 0
        resumed.workflowAgentLauncher = { _, _, _, _ in resumedLaunches += 1 }
        // runningAction left unset = the cleared state after the live agent exited.
        resumed.resumeWorkflowsOnStartup()
        XCTAssertEqual(resumedLaunches, 1,
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

    // MARK: - Legacy WORKFLOW.md is suppressed for JSON projects

    /// In a JSON-workflow project, starting a task whose worktree already exists must NOT run the
    /// legacy WORKFLOW.md launch (its loop was seeded at creation). It returns `.reuse` and spawns no
    /// agent surface — reaching here without touching the dummy app proves the legacy path is gated.
    func testStartTaskDoesNotRunLegacyLaunchForJSONProject() throws {
        try writeWorkflow()
        let branch = "start-json"
        let worktreePath = try writeWorktreeTask(branch: branch, status: WorkTask.ReservedStatus.readyToStart)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else {
            return XCTFail("task missing")
        }

        let result = coordinator.startTask(task, app: dummyApp)
        guard case .reuse = result else { return XCTFail("expected .reuse, got \(result)") }
        XCTAssertTrue(coordinator.agentSurfaces.isEmpty,
                      "a JSON project must not launch the legacy WORKFLOW.md agent on start")
    }

    /// `completePendingLaunch` still relocates the task file into the worktree (so the seed writes to
    /// the right place) but hands back **no** launch closure for a JSON project — the loop engine, not
    /// the legacy WORKFLOW.md launch, owns starting the agent.
    func testCompletePendingLaunchYieldsNoLegacyLaunchForJSONProject() throws {
        try writeWorkflow()
        let branch = "pending-json"
        let worktreePath = try writeWorktreeTask(branch: branch, status: WorkTask.ReservedStatus.new)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else {
            return XCTFail("task missing")
        }
        coordinator.pendingLaunch = (id: task.id, branch: branch)
        let worktree = Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached)

        let launch = coordinator.completePendingLaunch(branch: branch, worktree: worktree, app: dummyApp)
        XCTAssertNil(launch, "a JSON project gets no legacy launch closure from completePendingLaunch")
    }

    // MARK: - after_create hook is sourced from WORKFLOW.json

    /// A JSON-workflow project's after_create hook comes from `WORKFLOW.json`'s `hooks.after_create`,
    /// not the legacy `WORKFLOW.md`. A workflow without a `hooks` block yields no hook.
    func testAfterCreateHookComesFromWorkflowJSON() throws {
        let clearway = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let withHook = """
        {
          "version": 1,
          "start": "implement",
          "hooks": { "after_create": "npm install" },
          "actions": { "implement": { "name": "Implement", "instructions": "Go." } }
        }
        """
        try withHook.write(toFile: (clearway as NSString).appendingPathComponent("WORKFLOW.json"),
                           atomically: true, encoding: .utf8)
        let branch = "hooked"
        let worktreePath = try writeWorktreeTask(branch: branch, status: WorkTask.ReservedStatus.new)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        XCTAssertEqual(coordinator.workflowAfterCreateHook(), "npm install",
                       "the after_create hook is sourced from WORKFLOW.json")
    }

    func testNoAfterCreateHookWhenWorkflowJSONOmitsHooks() throws {
        try writeWorkflow()   // fixture has no `hooks` block
        let branch = "nohook"
        let worktreePath = try writeWorktreeTask(branch: branch, status: WorkTask.ReservedStatus.new)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        XCTAssertNil(coordinator.workflowAfterCreateHook(),
                     "a JSON workflow without a hooks block runs no after_create hook")
    }

    // MARK: - Reserved cap fields are decoded but not enforced

    /// `max_attempts` is a reserved, NOT-enforced field in v1 (manual kill is the loop-stopper). A
    /// workflow carrying it still decodes/validates and launches exactly like any other: a self-routing
    /// action launches normally rather than hitting any cap-driven halt. This pins that the reserved
    /// field never short-circuits a launch.
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

        // First write of `start` (no runningAction) launches; the self-route makes `fix` its own next.
        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .launched(slug: "fix"),
                       "a workflow carrying the reserved max_attempts field still launches normally")
    }
}
