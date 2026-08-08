import XCTest
import GhosttyKit
@testable import Clearway

/// Harness tests for the **manual kill** — the pause-and-interrupt path, distinct from an autopilot
/// pause (which never interrupts a running agent). Exercises the halves that need no live Ghostty
/// surface: the `autopilot = false` write, the `shouldTerminateOnManualKill` decision, and the
/// running-pointer cleanup. Split from `WorkflowLoopEngineHarnessTests` to keep both files readable.
@MainActor
final class WorkflowManualKillHarnessTests: WorkflowHarnessTestCase {

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

    /// A kill landing while `launchWorkflowAgent` awaits the PATH finds a running action but no
    /// surface. Nothing will exit later to clear `P`, so the kill must clear it itself — otherwise the
    /// worktree reads as running forever and `relaunchCurrentAction` can never restart it.
    func testManualKillClearsARunningActionThatHasNoSurfaceYet() throws {
        try writeWorkflow()
        let branch = "kill-mid-launch"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        let worktreeId = Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached).id
        let awaiting = coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        coordinator.manualKill(forBranch: branch)

        XCTAssertNil(coordinator.runningAction[worktreeId],
                     "a kill mid-launch must clear the running action no surface exit will ever clear")
        XCTAssertFalse(coordinator.isAgentRunning(forWorktree: worktreeId),
                       "the worktree must not read as running after the kill")
        XCTAssertFalse(coordinator.isLaunchCurrent(awaiting, forWorktree: worktreeId),
                       "the killed launch must abandon itself when it resumes")
    }

    /// A kill followed by a play relaunches the action the worktree still sits on, so the launch
    /// left awaiting the PATH would read *its own slug* back and spawn a second agent into the
    /// worktree — two agents editing one `TASK.md`, which is the tangle the steering paths exist to
    /// prevent. The launch generation is what tells the two apart.
    func testAKillThenPlaySupersedesTheLaunchStillAwaitingItsPath() throws {
        try writeWorkflow()
        let branch = "supersede"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        let worktreeId = worktreeId(branch: branch, path: worktreePath)

        // `implement` is launched and still awaiting the resolved PATH.
        let awaiting = coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        XCTAssertTrue(coordinator.isLaunchCurrent(awaiting, forWorktree: worktreeId))

        // The kill lands in that window, and the reload that follows records the pause.
        coordinator.manualKill(forBranch: branch)
        _ = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)

        // The user presses play: the engine relaunches the same action.
        let paused = try XCTUnwrap(coordinator.workTaskManager.task(forWorktree: branch))
        coordinator.workTaskManager.setAutopilot(paused, to: true)
        _ = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)

        XCTAssertEqual(coordinator.runningAction[worktreeId], "implement",
                       "the play relaunches the action the worktree sits on")
        XCTAssertFalse(coordinator.isLaunchCurrent(awaiting, forWorktree: worktreeId),
                       "the superseded launch must abandon itself rather than spawn a second agent")
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
}
