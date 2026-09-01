import XCTest
import GhosttyKit
@testable import Clearway

/// The step-tagging seam behind the tab strip's workflow badge: which slug a newly opened tab is
/// stamped with. Split from `WorkflowLoopEngineHarnessTests` to keep both files under SwiftLint's
/// 700-line `file_length` limit.
@MainActor
final class WorkflowStepTaggingHarnessTests: WorkflowHarnessTestCase {

    /// A coordinator over one worktree, plus the id the step lookup is keyed by. `appProvider` is
    /// wired so `seedWorkflowStatus` runs its trailing advance — the half of the seed that decides
    /// whether anything launches, and which an unwired provider silently skips.
    private func harness(
        branch: String,
        status: String,
        title: String = "Task",
        hidden: Bool = false,
        withWorkflow: Bool = true
    ) throws -> (coordinator: WorkTaskCoordinator, worktreeId: String) {
        if withWorkflow { try writeWorkflow() }
        let path = try writeWorktreeTask(branch: branch, status: status, title: title, hidden: hidden)
        let coordinator = makeCoordinator(branch: branch, worktreePath: path)
        coordinator.appProvider = { [dummyApp] in dummyApp }
        return (coordinator, worktreeId(branch: branch, path: path))
    }

    /// The seam `ContentView` installs reads the task's status, so a tab opened by hand while the
    /// task sits on a step gets badged — the case `runningAction` missed, since it is empty for the
    /// whole of manual use.
    func testCurrentWorkflowStepFollowsTheTaskStatus() throws {
        let (coordinator, worktreeId) = try harness(branch: "tagging", status: "implement")

        XCTAssertEqual(coordinator.currentWorkflowStep(forWorktree: worktreeId), "implement")
        XCTAssertTrue(coordinator.runningAction.isEmpty,
                      "and it does so with no agent running — the bug this replaced")
    }

    /// The user-reported flow: open a worktree (autopilot pauses, nothing runs), pick a different
    /// step, open a tab. The picked step must reach the badge even though the pick clears
    /// `runningAction`.
    func testCurrentWorkflowStepTracksAManualStepPick() throws {
        let (coordinator, worktreeId) = try harness(branch: "picked", status: "implement")

        let task = try XCTUnwrap(coordinator.workTaskManager.task(forWorktree: "picked"))
        coordinator.setWorkflowActionCurrent(task, to: "review")

        XCTAssertTrue(coordinator.runningAction.isEmpty, "a manual pick clears the running pointer")
        XCTAssertEqual(coordinator.currentWorkflowStep(forWorktree: worktreeId), "review")
    }

    func testCurrentWorkflowStepIgnoresStatesThatAreNotActions() throws {
        let (coordinator, worktreeId) = try harness(branch: "reserved", status: WorkTask.ReservedStatus.new)

        XCTAssertNil(coordinator.currentWorkflowStep(forWorktree: worktreeId),
                     "a backlog marker is not an action and must not badge")

        let task = try XCTUnwrap(coordinator.workTaskManager.task(forWorktree: "reserved"))
        coordinator.workTaskManager.updateFields(id: task.id) { $0.status = WorkTask.ReservedStatus.inProgress }
        XCTAssertNil(coordinator.currentWorkflowStep(forWorktree: worktreeId),
                     "nor is a legacy fixed state")
    }

    /// No `WORKFLOW.json` → no cached definition → nothing ever badges, with no caller branching
    /// on `isWorkflowJSONProject`.
    func testCurrentWorkflowStepIsNilWithoutAJSONWorkflow() throws {
        let (coordinator, worktreeId) = try harness(branch: "legacy", status: "implement", withWorkflow: false)

        XCTAssertNil(coordinator.currentWorkflowStep(forWorktree: worktreeId))
    }

    func testCurrentWorkflowStepIsNilForAnUnknownWorktree() throws {
        let (coordinator, _) = try harness(branch: "known", status: "implement")

        XCTAssertNil(coordinator.currentWorkflowStep(forWorktree: "/nope"))
    }

    func testWorkflowActionNameReadsTheCachedDefinition() throws {
        let (coordinator, _) = try harness(branch: "names", status: "implement")

        XCTAssertEqual(coordinator.workflowActionName("implement"), "Implement")
        XCTAssertNil(coordinator.workflowActionName("nonexistent"))
    }

    // MARK: - No task associated → no step

    /// A manually-created worktree's shadow task (`hidden`) means no task is associated yet, so the
    /// seed leaves `status` alone and the worktree has no current step to badge tabs with.
    func testSeedGivesAHiddenShadowTaskNoStep() throws {
        let (coordinator, worktreeId) = try harness(
            branch: "manual",
            status: WorkTask.ReservedStatus.inProgress,
            title: "",
            hidden: true
        )

        coordinator.seedWorkflowStatus(forBranch: "manual")

        let task = coordinator.workTaskManager.task(forWorktree: "manual")
        XCTAssertEqual(task?.status, WorkTask.ReservedStatus.inProgress, "the shadow keeps its state")
        XCTAssertEqual(task?.autopilot, false, "autopilot is still written, so a nil never reads as on")
        XCTAssertNil(coordinator.currentWorkflowStep(forWorktree: worktreeId),
                     "and a tab opened in it carries no badge")
        XCTAssertTrue(coordinator.runningAction.isEmpty, "nothing launches")
        XCTAssertNil(task?.errorMessage,
                     "the status the seed deliberately left alone is not an agent's bad write")
        XCTAssertFalse(coordinator.engineHalted.contains("manual"),
                       "and it must not halt the branch, which would swallow every later advance")
    }

    /// The watcher reaches the same un-stepped shadow on every `TASK.md` reload, so the engine has to
    /// ignore it there too — gating only the seed would halt on the very next reload.
    func testTheWatcherIgnoresAnUnassociatedWorktree() throws {
        let (coordinator, _) = try harness(
            branch: "manual",
            status: WorkTask.ReservedStatus.inProgress,
            title: "",
            hidden: true
        )
        coordinator.seedWorkflowStatus(forBranch: "manual")

        coordinator.handleTasksReloaded(branches: ["manual"])

        XCTAssertNil(coordinator.workTaskManager.task(forWorktree: "manual")?.errorMessage)
        XCTAssertFalse(coordinator.engineHalted.contains("manual"))
        XCTAssertTrue(coordinator.runningAction.isEmpty)
    }

    /// Create Task associates the task and seeds in one call — that is when the worktree gains its
    /// first step.
    func testExposingTheTaskSeedsTheFirstStep() throws {
        let (coordinator, worktreeId) = try harness(
            branch: "exposed",
            status: WorkTask.ReservedStatus.inProgress,
            title: "",
            hidden: true
        )
        coordinator.seedWorkflowStatus(forBranch: "exposed")

        let shadow = try XCTUnwrap(coordinator.workTaskManager.task(forWorktree: "exposed"))
        coordinator.exposeTask(shadow, forBranch: "exposed")

        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: "exposed")?.status, "implement")
        XCTAssertEqual(coordinator.currentWorkflowStep(forWorktree: worktreeId), "implement")
        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: "exposed")?.autopilot, false,
                       "exposing an empty task must not resume autopilot — the user still presses play")
    }

    /// A worktree started from a planned task arrives with a visible task, so it seeds and launches
    /// exactly as before — the gate must not touch this path.
    func testAPlannedTasksWorktreeStillSeedsAndLaunches() throws {
        let (coordinator, worktreeId) = try harness(
            branch: "planned",
            status: WorkTask.ReservedStatus.new,
            title: "Add dark mode"
        )

        coordinator.seedWorkflowStatus(forBranch: "planned")

        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: "planned")?.status, "implement")
        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: "planned")?.autopilot, true)
        XCTAssertEqual(coordinator.currentWorkflowStep(forWorktree: worktreeId), "implement")
        XCTAssertEqual(coordinator.runningAction[worktreeId], "implement",
                       "and the seed's trailing advance really does launch the first step")
    }
}
