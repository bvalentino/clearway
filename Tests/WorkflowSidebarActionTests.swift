import XCTest
import GhosttyKit
@testable import Clearway

/// Harness tests for the sidebar action cards' coordinator operations — **Set as current** and the
/// two **Run** variants. Each pauses autopilot (manual per-card control and the loop are mutually
/// exclusive) and steers `status` to the picked action. The Ghostty paste delivery needs a live app,
/// so the harness builds a real `TerminalManager` with no app and asserts the observable pool state;
/// paste delivery is left to the manual checklist.
@MainActor
final class WorkflowSidebarActionTests: WorkflowHarnessTestCase {

    // MARK: - Set as current

    /// **Set as current** moves `status` to the picked action and pauses autopilot.
    func testSetActionCurrentPausesAndSetsStatus() throws {
        try writeWorkflow()
        let branch = "set-current"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else {
            return XCTFail("task missing")
        }

        coordinator.setWorkflowActionCurrent(task, to: "review")

        let updated = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(updated?.status, "review", "set-as-current moves status to the picked action")
        XCTAssertEqual(updated?.autopilot, false, "set-as-current pauses autopilot")
    }

    /// The pause fires even when the picked slug already equals the current status — the status
    /// write is a no-op (`setWorkflowStatus` skips it), but handing control to the user is not.
    func testSetActionCurrentPausesEvenWhenSlugUnchanged() throws {
        try writeWorkflow()
        let branch = "set-current-noop"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else {
            return XCTFail("task missing")
        }

        coordinator.setWorkflowActionCurrent(task, to: "implement")

        let updated = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(updated?.status, "implement")
        XCTAssertEqual(updated?.autopilot, false, "a no-op status write still pauses autopilot")
    }

    // MARK: - Run in current / new terminal

    /// **Run in current terminal** sets the picked action as current and pauses autopilot. The
    /// harness has no Ghostty app, so the paste delivery is skipped — we assert the observable pool
    /// state (paste delivery is covered by the manual checklist).
    func testRunActionInCurrentTerminalPausesAndSetsCurrent() throws {
        try writeWorkflow()
        let branch = "run-current"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.runWorkflowAction(forBranch: branch, slug: "test", inNewTerminal: false)

        let updated = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(updated?.status, "test", "running an action sets it as current")
        XCTAssertEqual(updated?.autopilot, false, "running an action pauses autopilot")
    }

    /// **Run in new terminal** likewise sets the picked action as current and pauses autopilot.
    func testRunActionInNewTerminalPausesAndSetsCurrent() throws {
        try writeWorkflow()
        let branch = "run-new"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.runWorkflowAction(forBranch: branch, slug: "review", inNewTerminal: true)

        let updated = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(updated?.status, "review", "running an action in a new terminal sets it as current")
        XCTAssertEqual(updated?.autopilot, false, "running an action pauses autopilot")
    }

    // MARK: - Countdown the card consumes

    /// The aside resolves the worktree's pending countdown by branch (the card then renders it only on
    /// the matching `.current` action). No countdown scheduled → nothing to surface.
    func testWorkflowCountdownNilWhenNoneScheduled() throws {
        try writeWorkflow()
        let branch = "no-countdown"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        XCTAssertNil(coordinator.workflowCountdown(forBranch: branch),
                     "no scheduled countdown means the card shows none")
    }

    /// Once an agent-driven hand-off schedules a countdown, the aside exposes it for the imminent
    /// action's slug — the data the current card turns into its depleting ring + Pause.
    func testWorkflowCountdownExposedForScheduledBranch() throws {
        try writeWorkflow()
        let branch = "has-countdown"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        coordinator.workflowCountdownScheduler = { _ in }

        XCTAssertEqual(coordinator.advanceWorkflow(forBranch: branch, app: dummyApp, gracePeriod: true),
                       .deferred(slug: "test"))

        XCTAssertEqual(coordinator.workflowCountdown(forBranch: branch)?.slug, "test",
                       "the pending countdown is exposed for the imminent action's card")
    }

    /// The card's Pause closure routes to `pauseFromCountdown`, which cancels the countdown and pauses
    /// autopilot — identical to pressing the toolbar pause at that instant.
    func testPauseFromCountdownCancelsAndPauses() throws {
        try writeWorkflow()
        let branch = "card-pause"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        coordinator.workflowCountdownScheduler = { _ in }
        _ = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp, gracePeriod: true)

        coordinator.pauseFromCountdown(forBranch: branch)

        XCTAssertNil(coordinator.workflowCountdown(forBranch: branch), "Pause cancels the countdown")
        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.autopilot, false,
                       "Pause pauses autopilot via the existing pause path")
    }
}
