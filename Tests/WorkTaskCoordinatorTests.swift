import XCTest
@testable import Clearway

/// Behavioral contract for the two halves of Start Now. `resolveStart` resolves the task fresh from
/// disk and decides what would happen, writing nothing; `confirmCreate` carries the write, stamping
/// the worktree link and moving the task off its backlog marker onto `in_progress`. Clearway
/// launches no agent of its own, so `in_progress` is the whole of the status advance a start performs.
@MainActor
final class WorkTaskCoordinatorTests: TempRootTestCase {

    // MARK: - Resolving a start

    /// Start Now opens a sheet the operator can cancel, so resolving must leave the task exactly as
    /// it was: the file that comes back from a cancelled start still reads as backlog.
    func testResolveStartWritesNothing() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship it") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)

        guard case .prefill(let prefill) = coordinator.resolveStart(seed) else {
            XCTFail("expected prefill"); return
        }

        XCTAssertEqual(prefill.taskId, seed.id)
        XCTAssertEqual(prefill.title, "Ship it")
        let onDisk = try String(contentsOfFile: taskManager.filePath(for: seed), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("status: \(WorkTask.ReservedStatus.new)"),
                      "resolving leaves the task on its backlog marker")
        XCTAssertFalse(onDisk.contains("worktree:"), "resolving writes no branch link")
        XCTAssertNil(coordinator.pendingCreate, "resolving records nothing to complete")
    }

    /// A task that already names a branch keeps it: the derived name would collide with the branch
    /// the earlier start reserved.
    func testResolveStartPrefersTheTasksSavedBranchOverADerivedOne() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship it") else {
            XCTFail("createTask returned nil"); return
        }
        taskManager.updateFields(id: seed.id) {
            $0.worktree = "kept-branch"
            $0.status = WorkTask.ReservedStatus.canceled
        }
        guard let canceled = taskManager.freshTask(id: seed.id) else {
            XCTFail("task missing after cancel"); return
        }

        guard case .prefill(let prefill) = makeCoordinator(taskManager).resolveStart(canceled) else {
            XCTFail("expected prefill"); return
        }

        XCTAssertEqual(prefill.branch, "kept-branch")
    }

    func testResolveStartDerivesTheBranchWhenTheTaskNamesNone() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship It Now") else {
            XCTFail("createTask returned nil"); return
        }

        guard case .prefill(let prefill) = makeCoordinator(taskManager).resolveStart(seed) else {
            XCTFail("expected prefill"); return
        }

        XCTAssertEqual(prefill.branch, "ship-it-now")
    }

    /// A branch that is already live is focused rather than created a second time.
    func testResolveStartReusesALiveWorktree() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Reuse me") else {
            XCTFail("createTask returned nil"); return
        }
        taskManager.updateFields(id: seed.id) { $0.worktree = "reuse-me" }
        guard let linked = taskManager.freshTask(id: seed.id) else {
            XCTFail("task missing"); return
        }
        let coordinator = makeCoordinator(taskManager)
        let live = makeWorktree(branch: "reuse-me", path: "/tmp/reuse-me")
        coordinator.worktreeManager.worktrees = [live]

        guard case .reuse(let wt) = coordinator.resolveStart(linked) else {
            XCTFail("expected reuse"); return
        }

        XCTAssertEqual(wt, live)
    }

    /// Only a backlog marker starts: an in-progress task's Start Now is a no-op.
    func testResolveStartIgnoresATaskThatIsNeitherNewNorCanceled() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Already running") else {
            XCTFail("createTask returned nil"); return
        }
        taskManager.updateFields(id: seed.id) { $0.status = WorkTask.ReservedStatus.inProgress }
        guard let running = taskManager.freshTask(id: seed.id) else {
            XCTFail("task missing"); return
        }

        guard case .ignored = makeCoordinator(taskManager).resolveStart(running) else {
            XCTFail("expected ignored"); return
        }
    }

    // MARK: - Confirming a create

    /// Create writes `in_progress` and the branch the operator confirmed — which may not be the
    /// branch the prefill proposed.
    func testConfirmCreateWritesTheStatusAndTheConfirmedBranch() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship it") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        let command = agentCommand(text: "claude {{ task_path }}")

        coordinator.confirmCreate(taskId: seed.id, branch: "hand-typed", command: command)

        let written = taskManager.freshTask(id: seed.id)
        XCTAssertEqual(written?.status, WorkTask.ReservedStatus.inProgress)
        XCTAssertEqual(written?.worktree, "hand-typed")
        XCTAssertEqual(
            coordinator.pendingCreate,
            WorkTaskCoordinator.PendingCreate(taskId: seed.id, branch: "hand-typed", command: command)
        )
    }

    /// Restarting a canceled task counts the attempt and puts it back on `in_progress`.
    /// `attempt` is the sole input to the surviving agent-metadata row, so a lost increment
    /// would silently stop that row rendering.
    func testConfirmCreateCountsTheAttemptWhenRestartingACanceledTask() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Retry me") else {
            XCTFail("createTask returned nil"); return
        }
        taskManager.updateFields(id: seed.id) { $0.status = WorkTask.ReservedStatus.canceled }

        makeCoordinator(taskManager).confirmCreate(taskId: seed.id, branch: "retry-me", command: nil)

        let restarted = taskManager.freshTask(id: seed.id)
        XCTAssertEqual(restarted?.status, WorkTask.ReservedStatus.inProgress)
        XCTAssertEqual(restarted?.attempt, 1, "a restart counts the attempt")
    }

    /// The same sheet creates hand-made worktrees, which carry no task to write to.
    func testConfirmCreateWithoutATaskWritesNoTaskFileAndStillRecordsThePendingCreate() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        let coordinator = makeCoordinator(taskManager)

        coordinator.confirmCreate(taskId: nil, branch: "manual", command: nil)

        XCTAssertEqual(
            coordinator.pendingCreate,
            WorkTaskCoordinator.PendingCreate(taskId: nil, branch: "manual", command: nil)
        )
        XCTAssertTrue(taskManager.tasks.isEmpty, "a hand-made worktree creates no task")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: taskManager.tasksDirectory)) ?? []
        XCTAssertTrue(files.filter { $0.hasSuffix(".md") }.isEmpty, "no task file is written")
    }

    // MARK: - Pending create

    /// `completePendingCreate` relocates only for the branch it is holding, and consumes the
    /// pending create so a later worktree creation cannot move the file a second time.
    func testCompletePendingCreateRelocatesOnlyForTheBranchItIsHolding() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Relocate me") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        guard case .prefill(let prefill) = coordinator.resolveStart(seed) else {
            XCTFail("expected prefill"); return
        }
        let branch = prefill.branch
        coordinator.confirmCreate(taskId: prefill.taskId, branch: branch, command: nil)
        let centralPath = taskManager.filePath(for: seed)

        let otherPath = (tempRoot as NSString).appendingPathComponent("wt-other")
        coordinator.completePendingCreate(
            branch: "unrelated",
            worktree: makeWorktree(branch: "unrelated", path: otherPath)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: centralPath),
                      "an unrelated branch must not relocate this task")
        XCTAssertNotNil(coordinator.pendingCreate, "an unrelated branch must not consume the pending create")

        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }
        coordinator.completePendingCreate(
            branch: branch,
            worktree: makeWorktree(branch: branch, path: worktreePath)
        )
        XCTAssertNil(coordinator.pendingCreate, "the matching branch consumes the pending create")
        XCTAssertFalse(FileManager.default.fileExists(atPath: centralPath),
                       "the central file moves into the worktree")
        let taskMd = (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskMd),
                      "the task lands at the worktree's TASK.md")
    }

    /// The command comes back with `{{ task_path }}` pointing at the file the relocation just
    /// wrote, absolute — the agent is handed the brief it is being asked to work from.
    func testCompletePendingCreateResolvesTheTokenToTheRelocatedTaskFile() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Resolve me") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        let branch = "resolve-me"
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }
        coordinator.pendingCreate = WorkTaskCoordinator.PendingCreate(
            taskId: seed.id,
            branch: branch,
            command: agentCommand(text: "plan {{ task_path }} now")
        )

        let resolved = coordinator.completePendingCreate(
            branch: branch,
            worktree: makeWorktree(branch: branch, path: worktreePath)
        )

        let taskMd = (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
        XCTAssertEqual(resolved?.text, "plan \(taskMd) now")
        XCTAssertTrue(taskMd.hasPrefix("/"), "the substituted path is absolute")
    }

    /// A hand-made worktree carries no task, so there is no path to name: the token stays verbatim
    /// rather than becoming a blank argument the agent would read as a malformed path.
    func testCompletePendingCreateWithoutATaskLeavesTheTokenVerbatim() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        let coordinator = makeCoordinator(taskManager)
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-manual")
        coordinator.pendingCreate = WorkTaskCoordinator.PendingCreate(
            taskId: nil,
            branch: "manual",
            command: agentCommand(text: "read {{ task_path }}")
        )

        let resolved = coordinator.completePendingCreate(
            branch: "manual",
            worktree: makeWorktree(branch: "manual", path: worktreePath)
        )

        XCTAssertEqual(resolved?.text, "read {{ task_path }}")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
            ),
            "a pending create with no task relocates nothing"
        )
    }

    /// No command picked means nothing to run — the relocation still happens.
    func testCompletePendingCreateWithoutACommandReturnsNil() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "No command") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        let branch = "no-command"
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }
        coordinator.pendingCreate = WorkTaskCoordinator.PendingCreate(
            taskId: seed.id, branch: branch, command: nil
        )

        let resolved = coordinator.completePendingCreate(
            branch: branch,
            worktree: makeWorktree(branch: branch, path: worktreePath)
        )

        XCTAssertNil(resolved)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
            ),
            "the relocation still runs"
        )
    }

    private func agentCommand(text: String) -> SavedCommand {
        SavedCommand(id: UUID(), name: "Plan", kind: .agent, text: text, agent: "claude", autoRun: true)
    }

    // MARK: - Start Now freshness

    /// `resolveStart` must re-resolve by id so a pre-plan UI snapshot cannot clobber post-plan disk
    /// content before relocate moves the central file into the worktree.
    func testResolveStartUsesFreshDiskContentNotStaleSnapshot() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Pre-plan draft") else {
            XCTFail("createTask returned nil"); return
        }
        taskManager.updateFields(id: seed.id) {
            $0.body = "Short draft"
            $0.status = WorkTask.ReservedStatus.new
        }

        // Whatever ran in the task terminal rewrote the central file.
        var planned = seed
        planned.title = "Post-plan title"
        planned.body = "Full planned brief."
        planned.status = WorkTask.ReservedStatus.new
        try planned.serialized().write(
            toFile: taskManager.filePath(for: seed),
            atomically: true,
            encoding: .utf8
        )
        taskManager.reloadFromDisk()

        let coordinator = makeCoordinator(taskManager)

        // Stale pre-plan snapshot as the UI might still hold.
        var staleSnapshot = seed
        staleSnapshot.title = "Pre-plan draft"
        staleSnapshot.body = "Short draft"
        staleSnapshot.status = WorkTask.ReservedStatus.new

        let result = coordinator.resolveStart(staleSnapshot)
        guard case .prefill(let prefill) = result else {
            XCTFail("expected prefill, got \(result)"); return
        }
        let branch = prefill.branch
        coordinator.confirmCreate(taskId: prefill.taskId, branch: branch, command: nil)

        // Central file after bookkeeping must still carry post-plan content.
        let centralPath = (taskManager.tasksDirectory as NSString)
            .appendingPathComponent("\(seed.id.uuidString).md")
        let central = try String(contentsOfFile: centralPath, encoding: .utf8)
        let reparsed = WorkTask.parse(from: central, id: seed.id, createdAt: seed.createdAt)
        XCTAssertEqual(reparsed?.title, "Post-plan title")
        XCTAssertEqual(reparsed?.body, "Full planned brief.")
        XCTAssertEqual(reparsed?.worktree, branch)
        XCTAssertEqual(reparsed?.status, WorkTask.ReservedStatus.inProgress)

        // Relocate into a worktree and confirm content survives.
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-start")
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }
        taskManager.relocateTaskToWorktree(id: seed.id, worktreePath: worktreePath)
        guard let relocated = taskManager.tasks.first(where: { $0.id == seed.id }) else {
            XCTFail("task missing after relocate"); return
        }
        let moved = try String(contentsOfFile: taskManager.filePath(for: relocated), encoding: .utf8)
        let movedTask = WorkTask.parse(from: moved, id: seed.id, createdAt: seed.createdAt)
        XCTAssertEqual(movedTask?.title, "Post-plan title")
        XCTAssertEqual(movedTask?.body, "Full planned brief.")
    }
}
