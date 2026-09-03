import XCTest
import GhosttyKit
@testable import Clearway

/// Harness tests for the **terminal-action completion** path of the `WORKFLOW.json` loop engine:
/// a terminal action's agent writes `completed: true`, the engine ends the loop (pauses autopilot,
/// launches nothing), and a manual re-drive (status pick / autopilot re-enable) reopens it.
///
/// Like `WorkflowLoopEngineHarnessTests`, each coordinator gets a no-op `workflowAgentLauncher` so a
/// `.launch` runs the engine's bookkeeping without spawning a real Ghostty surface; tests that count
/// launches override it with a recorder.
@MainActor
final class WorkflowCompletionHarnessTests: WorkflowHarnessTestCase {

    override static var tempRootPrefix: String { "clearway-completion-harness" }

    // MARK: - Completion ends the loop

    /// A terminal action's agent wrote `completed: true` (status sits on the terminal slug). The
    /// engine ends the loop: it writes `autopilot: false`, launches nothing, and reports `.completed`.
    func testCompletedOnTerminalActionEndsLoop() throws {
        try writeWorkflow()
        let branch = "complete"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "review", autopilot: true, completed: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("review", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)

        XCTAssertEqual(result, .completed(slug: "review"), "a completed terminal action ends the loop")
        let task = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(task?.autopilot, false, "completion pauses autopilot")
        XCTAssertEqual(task?.completed, true, "the agent-written completion flag is preserved")
    }

    /// A single-action workflow whose `start` action is itself terminal still completes when its
    /// agent writes `completed: true` (criterion 2).
    func testCompletedOnSingleTerminalStartActionEndsLoop() throws {
        try writeWorkflowJSON("""
        {
          "version": 1,
          "start": "ship",
          "actions": { "ship": { "name": "Ship", "instructions": "Ship it." } }
        }
        """)
        let branch = "single"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "ship", autopilot: true, completed: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("ship", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)

        XCTAssertEqual(result, .completed(slug: "ship"), "a terminal start action completes")
        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.autopilot, false)
    }

    /// Once completed, subsequent reloads never relaunch an agent for the worktree (criterion 5):
    /// the short-circuit fires on every later advance, suppressing the idle-launch rule.
    func testCompletedTaskNeverRelaunchesOnReload() throws {
        try writeWorkflow()
        let branch = "no-respawn"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "review", autopilot: true, completed: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        var launches = 0
        coordinator.workflowAgentLauncher = { _, _, _, _ in launches += 1 }
        // Idle (no runningAction) — without the completion guard the idle rule would launch `review`.

        let first = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        let second = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)

        XCTAssertEqual(first, .completed(slug: "review"))
        XCTAssertEqual(second, .completed(slug: "review"), "a completed task stays completed across reloads")
        XCTAssertEqual(launches, 0, "a completed worktree relaunches no agent")
    }

    /// The terminal-only guard: `completed: true` written from a **non-terminal** action is ignored —
    /// the loop advances normally instead of ending. A misbehaving agent can't end the loop early.
    func testCompletedOnNonTerminalActionIsIgnored() throws {
        try writeWorkflow()
        let branch = "early"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true, completed: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        // Idle → the idle rule launches the written action normally (completion not honored).

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)

        XCTAssertEqual(result, .launched(slug: "implement"),
                       "completion on a non-terminal action is ignored — the loop proceeds")
    }

    /// Criterion 4: a terminal action's agent dying **without** writing `completed` (crash / Ctrl-C /
    /// terminal closed) must NOT mark the task completed — it lands in the existing resumable paused
    /// state (`autopilot: false`, no `completed`) via the untouched death-pause path.
    func testTerminalAgentDeathWithoutCompletionDoesNotComplete() throws {
        try writeWorkflow()
        let branch = "crash"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "review", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        let worktreeId = Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached).id

        // The terminal "review" agent died; disk status still reads "review", no completion written.
        coordinator.pauseIfAgentDiedMidStep(worktreeId: worktreeId, clearedAction: "review")

        let task = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(task?.autopilot, false, "a terminal agent dying mid-step pauses the loop")
        XCTAssertNil(task?.completed, "a crash is not a completion — the task is not marked completed")
    }

    // MARK: - Manual re-drive reopens a completed task

    /// A manual status pick on a completed task clears `completed`, reopening it (criterion 6).
    func testManualStatusPickClearsCompleted() throws {
        try writeWorkflow()
        let branch = "reopen-pick"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "review", autopilot: false, completed: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else {
            return XCTFail("task missing")
        }

        coordinator.setWorkflowStatus(task, to: "test")

        let updated = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(updated?.status, "test", "the picked status is written")
        XCTAssertNil(updated?.completed, "a manual pick clears the completion flag")
    }

    /// **Set as current** on the *same* (current terminal) action of a completed task must still clear
    /// `completed`, even though `status` is unchanged — the early no-op return must not skip the clear.
    func testSetCurrentOnCompletedTerminalActionClearsCompleted() throws {
        try writeWorkflow()
        let branch = "reopen-current"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "review", autopilot: false, completed: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else {
            return XCTFail("task missing")
        }

        coordinator.setWorkflowActionCurrent(task, to: "review")

        let updated = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(updated?.status, "review", "status stays on the reopened terminal action")
        XCTAssertNil(updated?.completed, "reopening the current terminal action clears completion")
        XCTAssertEqual(updated?.autopilot, false, "Set as current keeps the loop paused")
    }

    /// Re-enabling autopilot on a completed task clears `completed` and **re-pauses** (autopilot stays
    /// false) without relaunching — the loop is reopened, idle, awaiting a manual pick (criterion 6).
    func testAutopilotReEnableOnCompletedTaskReopensPaused() throws {
        try writeWorkflow()
        let branch = "reopen-enable"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "review", autopilot: true, completed: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.appProvider = { [dummyApp] in dummyApp }
        var launches = 0
        coordinator.workflowAgentLauncher = { _, _, _, _ in launches += 1 }

        // First sight pauses the stale autopilot:true → autopilot:false, lastKnownAutopilot=false.
        coordinator.handleTasksReloaded(branches: [branch])
        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.autopilot, false)

        // User clicks play: the button optimistically writes autopilot:true.
        guard let paused = coordinator.workTaskManager.task(forWorktree: branch) else {
            return XCTFail("task missing")
        }
        coordinator.workTaskManager.setAutopilot(paused, to: true)
        coordinator.handleTasksReloaded(branches: [branch])

        let reopened = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertNil(reopened?.completed, "re-enabling autopilot clears completion")
        XCTAssertEqual(reopened?.autopilot, false, "the engine re-pauses the optimistic enable")
        XCTAssertEqual(launches, 0, "reopening a completed task relaunches nothing")
    }
}
