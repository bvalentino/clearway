import XCTest
@testable import Clearway

/// Behavioral contract for `WorkTaskCoordinator.startTask`: it resolves the task fresh from disk,
/// stamps the worktree link, and moves the task off its backlog marker onto `in_progress`. Clearway
/// launches no agent of its own, so `in_progress` is the whole of the status advance a start performs.
@MainActor
final class WorkTaskCoordinatorTests: TempRootTestCase {

    // MARK: - Start Now status

    /// Starting a backlog task writes `in_progress` — the status is the user's to drive from there.
    func testStartTaskMovesABacklogTaskToInProgress() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship it") else {
            XCTFail("createTask returned nil"); return
        }
        let result = makeCoordinator(taskManager).startTask(seed)
        guard case .createWorktree = result else {
            XCTFail("expected createWorktree, got \(result)"); return
        }

        XCTAssertEqual(taskManager.freshTask(id: seed.id)?.status, WorkTask.ReservedStatus.inProgress,
                       "Start Now advances a backlog task to in_progress")
    }

    /// Restarting a canceled task counts the attempt and puts it back on `in_progress`.
    /// `attempt` is the sole input to the surviving agent-metadata row, so a lost increment
    /// would silently stop that row rendering.
    func testStartTaskCountsTheAttemptWhenRestartingACanceledTask() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Retry me") else {
            XCTFail("createTask returned nil"); return
        }
        taskManager.updateFields(id: seed.id) { $0.status = WorkTask.ReservedStatus.canceled }
        guard let canceled = taskManager.freshTask(id: seed.id) else {
            XCTFail("task missing after cancel"); return
        }

        guard case .createWorktree = makeCoordinator(taskManager).startTask(canceled) else {
            XCTFail("expected createWorktree"); return
        }

        let restarted = taskManager.freshTask(id: seed.id)
        XCTAssertEqual(restarted?.status, WorkTask.ReservedStatus.inProgress)
        XCTAssertEqual(restarted?.attempt, 1, "a restart counts the attempt")
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
        guard case .createWorktree(let branch) = coordinator.startTask(seed) else {
            XCTFail("expected createWorktree"); return
        }
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

    /// startTask must re-resolve by id so a pre-plan UI snapshot cannot clobber post-plan disk
    /// content before relocate moves the central file into the worktree.
    func testStartTaskUsesFreshDiskContentNotStaleSnapshot() throws {
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

        let result = coordinator.startTask(staleSnapshot)
        guard case .createWorktree(let branch) = result else {
            XCTFail("expected createWorktree, got \(result)"); return
        }

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
