import XCTest
import GhosttyKit
@testable import Clearway

/// Harness tests for the **launch-generation guard** (`isLaunchCurrent`) — what stops a launch that
/// is still awaiting its resolved PATH from spawning a second agent into a worktree that has since
/// been relaunched on the *same* action. The slug half of the guard can't tell the two apart, so the
/// generation is what does.
///
/// The reachable path to a same-slug relaunch is a manual status pick: `setWorkflowStatus` clears
/// `runningAction` with no live surface, and a later play makes `relaunchCurrentAction` restart the
/// action the worktree still sits on.
@MainActor
final class WorkflowAgentSupersedeHarnessTests: WorkflowHarnessTestCase {

    /// A status pick away and back, then a play, relaunches the action the worktree still sits on, so
    /// the launch left awaiting the PATH would read *its own slug* back and spawn a second agent into
    /// the worktree — two agents editing one `TASK.md`, which is the tangle the steering paths exist
    /// to prevent. The launch generation is what tells the two apart.
    func testAStatusPickThenPlaySupersedesTheLaunchStillAwaitingItsPath() throws {
        try writeWorkflow()
        let branch = "supersede"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        let worktreeId = worktreeId(branch: branch, path: worktreePath)

        // `implement` is launched and still awaiting the resolved PATH.
        let awaiting = coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        XCTAssertTrue(coordinator.isLaunchCurrent(awaiting, forWorktree: worktreeId))

        // A manual pick steers away and back — each pick clears the running pointer. The round-trip is
        // what lands the worktree back on `implement`: picking the current slug would early-return.
        let task = try XCTUnwrap(coordinator.workTaskManager.task(forWorktree: branch))
        coordinator.setWorkflowStatus(task, to: "test")
        let steered = try XCTUnwrap(coordinator.workTaskManager.task(forWorktree: branch))
        coordinator.setWorkflowStatus(steered, to: "implement")
        // The reload that follows records the first-sight pause.
        _ = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)

        // The user presses play: the engine relaunches the action the worktree still sits on.
        let paused = try XCTUnwrap(coordinator.workTaskManager.task(forWorktree: branch))
        coordinator.workTaskManager.setAutopilot(paused, to: true)
        _ = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)

        XCTAssertEqual(coordinator.runningAction[worktreeId], "implement",
                       "the play relaunches the action the worktree sits on")
        XCTAssertFalse(coordinator.isLaunchCurrent(awaiting, forWorktree: worktreeId),
                       "the superseded launch must abandon itself rather than spawn a second agent")
    }
}
