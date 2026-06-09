import XCTest
@testable import Clearway

/// Behavioral contract for `WorkTaskCoordinator.handleWorktreeRemoved` under the location-encoded
/// model: a task's `TASK.md` lives inside the worktree and dies with it. Removing the worktree must
/// tear down the worktree's agent surfaces and write **nothing** back to the central store — the
/// task is gone, not resurrected. (The pre-location-model behavior marked the task done and wrote it
/// back centrally; this locks in the divergence.)
@MainActor
final class WorkTaskCoordinatorTests: XCTestCase {

    private var tempRoot: String!

    override func setUp() {
        super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root = tempRoot {
            try? FileManager.default.removeItem(atPath: root)
        }
        tempRoot = nil
        super.tearDown()
    }

    /// Removing a worktree whose task lives in its `TASK.md` must not create a central `<UUID>.md`
    /// for that task. The task dies with the worktree.
    func testHandleWorktreeRemovedDoesNotResurrectTaskCentrally() throws {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-gone")
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let taskMd = (clearway as NSString).appendingPathComponent("TASK.md")

        let id = UUID()
        let task = WorkTask(id: id, title: "Active", status: .inProgress, worktree: "feature/gone")
        try task.serialized().write(toFile: taskMd, atomically: true, encoding: .utf8)

        let taskManager = WorkTaskManager(projectPath: tempRoot)
        taskManager.worktreeResolver = { [(branch: "feature/gone", path: worktreePath)] }
        taskManager.setWatchedWorktrees([worktreePath])  // load the worktree task into the pool
        XCTAssertEqual(taskManager.task(forWorktree: "feature/gone")?.id, id,
                       "precondition: the task is resolvable from its worktree (so the old write-back path would have fired)")

        let worktreeManager = WorktreeManager(projectPath: tempRoot)
        let coordinator = WorkTaskCoordinator(
            workTaskManager: taskManager,
            terminalManager: TerminalManager(),
            worktreeManager: worktreeManager
        )
        // Present the worktree synchronously so `handleWorktreeRemoved` enters its teardown branch.
        // No `await` follows before the call, so the manager's async `refresh()` can't interleave
        // and wipe this between the assignment and the call.
        worktreeManager.worktrees = [
            Worktree(branch: "feature/gone", path: worktreePath, isMain: false, headStatus: .attached)
        ]

        coordinator.handleWorktreeRemoved(branch: "feature/gone")

        let centralFile = (((tempRoot as NSString).appendingPathComponent(".clearway/tasks")) as NSString)
            .appendingPathComponent("\(id.uuidString).md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: centralFile),
                       "removing the worktree must not write the task back to the central store")
    }
}
