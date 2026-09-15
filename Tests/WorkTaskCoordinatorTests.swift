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

        // Plan agent rewrote the central file.
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
