import XCTest
import GhosttyKit
@testable import Clearway

/// Harness tests for the grace-period countdown — the visible, interruptible window before an
/// agent-driven mid-loop hand-off auto-launches the next action. Exercises the coordinator plumbing
/// (`advanceWorkflow(gracePeriod:)`, the scheduler seam, fire/cancel) without a live Ghostty surface,
/// mirroring `WorkflowLoopEngineHarnessTests`: a no-op `workflowAgentLauncher` keeps launches
/// surface-free and the `workflowCountdownScheduler` seam captures the fire closure for synchronous
/// invocation.
@MainActor
final class WorkflowCountdownHarnessTests: WorkflowHarnessTestCase {

    // MARK: - Defer / fire

    /// The watch-path advance (grace period on) for a legal agent-driven hand-off does **not** launch
    /// immediately: it schedules a countdown and returns `.deferred`, leaving the previous running
    /// action in place until the countdown fires.
    func testWatchPathDefersLaunchWithCountdown() throws {
        try writeWorkflow()
        let branch = "defer"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        let wtId = worktreeId(branch: branch, path: worktreePath)
        var capturedFire: (() -> Void)?
        coordinator.workflowCountdownScheduler = { fire in capturedFire = fire }

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp, gracePeriod: true)

        XCTAssertEqual(result, .deferred(slug: "test"), "a grace-period legal advance defers the launch")
        XCTAssertEqual(coordinator.workflowCountdowns[wtId]?.slug, "test", "a countdown is scheduled for the imminent action")
        XCTAssertEqual(coordinator.runningAction[wtId], "implement", "deferring launches nothing — the prior action stays")
        XCTAssertNotNil(capturedFire, "the scheduler seam captured the fire closure")
    }

    /// When the countdown fires it performs the deferred launch (re-running the immediate advance) and
    /// clears the countdown state.
    func testCountdownFireLaunchesDeferredAction() throws {
        try writeWorkflow()
        let branch = "fire"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        coordinator.appProvider = { [dummyApp] in dummyApp }
        let wtId = worktreeId(branch: branch, path: worktreePath)
        var launches = 0
        coordinator.workflowAgentLauncher = { _, _, _, _ in launches += 1 }
        var capturedFire: (() -> Void)?
        coordinator.workflowCountdownScheduler = { fire in capturedFire = fire }

        XCTAssertEqual(coordinator.advanceWorkflow(forBranch: branch, app: dummyApp, gracePeriod: true),
                       .deferred(slug: "test"))
        capturedFire?()

        XCTAssertEqual(coordinator.runningAction[wtId], "test", "the fire launches the deferred action")
        XCTAssertEqual(launches, 1, "exactly one agent launch on fire")
        XCTAssertNil(coordinator.workflowCountdowns[wtId], "firing clears the countdown state")
    }

    /// Pausing during the window cancels the countdown and pauses autopilot. Even a stray fire after
    /// the pause launches nothing — the immediate advance re-reads the pause gate and is suppressed.
    func testPauseDuringCountdownSuppressesLaunch() throws {
        try writeWorkflow()
        let branch = "pause-window"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        coordinator.appProvider = { [dummyApp] in dummyApp }
        let wtId = worktreeId(branch: branch, path: worktreePath)
        var launches = 0
        coordinator.workflowAgentLauncher = { _, _, _, _ in launches += 1 }
        var capturedFire: (() -> Void)?
        coordinator.workflowCountdownScheduler = { fire in capturedFire = fire }

        XCTAssertEqual(coordinator.advanceWorkflow(forBranch: branch, app: dummyApp, gracePeriod: true),
                       .deferred(slug: "test"))

        coordinator.pauseFromCountdown(forBranch: branch)

        XCTAssertNil(coordinator.workflowCountdowns[wtId], "pause cancels the pending countdown")
        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.autopilot, false,
                       "pause writes autopilot = false, reusing the existing pause path")
        // A late fire (race) still launches nothing — the pause gate suppresses it.
        capturedFire?()
        XCTAssertEqual(launches, 0, "no launch after pause, even on a stray fire")
        XCTAssertEqual(coordinator.runningAction[wtId], "implement", "the prior action is untouched")
    }

    /// The seed launches its first action immediately — no countdown. The grace period is for
    /// agent-driven mid-loop hand-offs only, not the initial launch on worktree creation.
    func testSeedLaunchesImmediatelyWithoutCountdown() throws {
        try writeWorkflow()
        let branch = "seed-immediate"
        let worktreePath = try writeWorktreeTask(branch: branch, status: WorkTask.ReservedStatus.new, title: "Has content")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.appProvider = { [dummyApp] in dummyApp }
        let wtId = worktreeId(branch: branch, path: worktreePath)
        var scheduled = 0
        coordinator.workflowCountdownScheduler = { _ in scheduled += 1 }

        coordinator.seedWorkflowStatus(forBranch: branch)

        XCTAssertEqual(coordinator.runningAction[wtId], "implement", "the seed launches the start action at once")
        XCTAssertEqual(scheduled, 0, "the seed schedules no countdown")
        XCTAssertNil(coordinator.workflowCountdowns[wtId])
    }

    /// A repeated watch advance for the same pending action (debounced double reload) keeps the
    /// original countdown rather than rescheduling — idempotent per worktree+slug.
    func testGracePeriodAdvanceIsIdempotentForSameSlug() throws {
        try writeWorkflow()
        let branch = "idem-countdown"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        let wtId = worktreeId(branch: branch, path: worktreePath)
        var scheduleCount = 0
        coordinator.workflowCountdownScheduler = { _ in scheduleCount += 1 }

        XCTAssertEqual(coordinator.advanceWorkflow(forBranch: branch, app: dummyApp, gracePeriod: true),
                       .deferred(slug: "test"))
        let firstDeadline = coordinator.workflowCountdowns[wtId]?.deadline
        XCTAssertEqual(coordinator.advanceWorkflow(forBranch: branch, app: dummyApp, gracePeriod: true),
                       .deferred(slug: "test"))
        let secondDeadline = coordinator.workflowCountdowns[wtId]?.deadline

        XCTAssertEqual(scheduleCount, 1, "the same pending slug is not rescheduled")
        XCTAssertEqual(firstDeadline, secondDeadline, "the original deadline is preserved")
    }

    // MARK: - Steer / kill cancel the countdown

    /// A manual status pick mid-countdown cancels the pending auto-launch — steering overrides it.
    func testManualStatusPickCancelsCountdown() throws {
        try writeWorkflow()
        let branch = "steer-cancel"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        let wtId = worktreeId(branch: branch, path: worktreePath)
        coordinator.workflowCountdownScheduler = { _ in }

        XCTAssertEqual(coordinator.advanceWorkflow(forBranch: branch, app: dummyApp, gracePeriod: true),
                       .deferred(slug: "test"))
        XCTAssertNotNil(coordinator.workflowCountdowns[wtId])

        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else { return XCTFail("task missing") }
        coordinator.setWorkflowStatus(task, to: "review")

        XCTAssertNil(coordinator.workflowCountdowns[wtId], "a manual status pick cancels the pending countdown")
    }

    /// The manual kill cancels the pending auto-launch alongside pausing the loop.
    func testManualKillCancelsCountdown() throws {
        try writeWorkflow()
        let branch = "kill-cancel"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        let wtId = worktreeId(branch: branch, path: worktreePath)
        coordinator.workflowCountdownScheduler = { _ in }

        XCTAssertEqual(coordinator.advanceWorkflow(forBranch: branch, app: dummyApp, gracePeriod: true),
                       .deferred(slug: "test"))

        coordinator.manualKill(forBranch: branch)

        XCTAssertNil(coordinator.workflowCountdowns[wtId], "the manual kill cancels the pending countdown")
        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.autopilot, false)
    }

    /// A halt while a countdown is armed (the agent writes an illegal slug after a prior legal advance)
    /// cancels the pending auto-launch — the halted loop won't perform it, so the card must stop
    /// counting down to it.
    func testHaltCancelsArmedCountdown() throws {
        try writeWorkflow()
        let branch = "halt-cancel"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        let wtId = worktreeId(branch: branch, path: worktreePath)
        coordinator.workflowCountdownScheduler = { _ in }

        // A legal hand-off (implement→test) arms a countdown for "test".
        XCTAssertEqual(coordinator.advanceWorkflow(forBranch: branch, app: dummyApp, gracePeriod: true),
                       .deferred(slug: "test"))
        XCTAssertNotNil(coordinator.workflowCountdowns[wtId])

        // The agent then writes "review" — not a legal route out of the still-running "implement".
        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else { return XCTFail("task missing") }
        coordinator.workTaskManager.setStatus(task, to: "review")
        guard case .halted = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp, gracePeriod: true) else {
            return XCTFail("an illegal mid-step advance should halt")
        }

        XCTAssertNil(coordinator.workflowCountdowns[wtId], "the halt cancels the armed countdown")
    }

    /// The toolbar Pause has no synchronous cancel of its own: it writes `autopilot = false`, and the
    /// resulting reload observes the true→false flip. That flip must cancel an armed hand-off countdown
    /// so the card stops counting down to a launch the user just suppressed.
    func testToolbarPauseFlipCancelsCountdown() throws {
        try writeWorkflow()
        let branch = "toolbar-pause"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.appProvider = { [dummyApp] in dummyApp }
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)
        let wtId = worktreeId(branch: branch, path: worktreePath)
        coordinator.workflowCountdownScheduler = { _ in }

        // First reload records autopilot = true and arms the hand-off countdown for "test".
        coordinator.handleTasksReloaded(branches: [branch])
        XCTAssertNotNil(coordinator.workflowCountdowns[wtId], "the hand-off arms a countdown")

        // The toolbar Pause writes autopilot = false; the resulting reload sees the true→false flip.
        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else { return XCTFail("task missing") }
        coordinator.workTaskManager.setAutopilot(task, to: false)
        coordinator.handleTasksReloaded(branches: [branch])

        XCTAssertNil(coordinator.workflowCountdowns[wtId],
                     "the autopilot true→false flip cancels the armed countdown")
    }
}
