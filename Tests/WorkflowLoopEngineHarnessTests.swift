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

    // MARK: - First-sight auto-pause (open never auto-runs)

    /// The first time the engine observes a worktree (e.g. it was just opened, or present at load),
    /// a stale `autopilot: true` is flipped to `false` and nothing launches — opening a worktree must
    /// never auto-run a workflow. The loop only (re)starts on an explicit play afterward.
    func testFirstSightPausesStaleAutopilotAndLaunchesNothing() throws {
        try writeWorkflow()
        let branch = "stale"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.appProvider = { [dummyApp] in dummyApp }
        var launches = 0
        coordinator.workflowAgentLauncher = { _, _, _, _ in launches += 1 }

        coordinator.handleTasksReloaded(branches: [branch])

        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.autopilot, false,
                       "a stale autopilot:true is paused on first sight")
        XCTAssertEqual(launches, 0, "opening a worktree launches no workflow action")
    }

    /// A worktree the engine is already running (e.g. one just seeded on create, whose agent launched
    /// directly) is exempt from the first-sight pause, so a fresh create still runs.
    func testFirstSightExemptsAlreadyRunningWorktree() throws {
        try writeWorkflow()
        let branch = "running"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.appProvider = { [dummyApp] in dummyApp }
        coordinator.workflowAgentLauncher = { _, _, _, _ in }
        coordinator.setRunningActionForTesting("test", branch: branch, worktreePath: worktreePath)

        coordinator.handleTasksReloaded(branches: [branch])

        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.autopilot, true,
                       "a worktree already running is not paused on reload")
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

    // MARK: - Manual status pick (picker)

    /// An idle worktree (nothing running) launches whatever action the user picks — the relaxed idle
    /// rule, so a manual jump doesn't halt as a "non-start first value".
    func testManualPickOnIdleWorktreeLaunches() throws {
        try writeWorkflow()
        let branch = "manual"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        // No setRunningActionForTesting → runningAction is nil (idle).

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .launched(slug: "test"),
                       "an idle worktree launches the manually-picked action instead of halting")
    }

    /// A manual pick made **while a step is running** must not halt as "not a legal next" — the user
    /// can set any state. Clearing the running pointer makes the engine treat it as an idle launch of
    /// the picked action (no route validation).
    func testManualPickWhileRunningNeverHalts() throws {
        try writeWorkflow()
        let branch = "redirect"
        // Running `implement`; the user picks `review` — NOT a legal next from `implement`.
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else {
            return XCTFail("task missing")
        }

        coordinator.setWorkflowStatus(task, to: "review")

        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.status, "review",
                       "the picked state is set even though it isn't a legal route")
        XCTAssertFalse(coordinator.engineHalted.contains(branch), "a manual pick never halts")
        // The follow-up advance (what the watcher drives) runs the picked action, not a halt. `review`
        // is terminal, so launching it resolves to `.ended` (runs once) — the point is it never halts.
        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .ended(slug: "review"),
                       "the picked action runs via the idle rule, with no route validation or halt")
    }

    /// A manual status pick clears a prior halt + error so the loop can recover, rather than being
    /// ignored because `engineHalted` is still set.
    func testManualStatusPickClearsHalt() throws {
        try writeWorkflow()
        let branch = "recover"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "review", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        // Halt: running `implement`, status wrote `review` (a real action but not reachable).
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        guard case .halted = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp) else {
            return XCTFail("expected the setup to halt")
        }
        XCTAssertTrue(coordinator.engineHalted.contains(branch))
        XCTAssertNotNil(coordinator.workTaskManager.task(forWorktree: branch)?.errorMessage)

        guard let halted = coordinator.workTaskManager.task(forWorktree: branch) else {
            return XCTFail("task missing after halt")
        }
        coordinator.setWorkflowStatus(halted, to: "test")

        XCTAssertFalse(coordinator.engineHalted.contains(branch), "a manual status pick clears the halt")
        let recovered = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(recovered?.status, "test", "the picked status is written")
        XCTAssertNil(recovered?.errorMessage, "and the stale halt error is cleared")
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
