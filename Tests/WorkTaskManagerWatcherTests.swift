import XCTest
@testable import Clearway

/// Integration tests for the production DispatchSource path (not `reloadFromDisk()`).
///
/// These exercise real file-system events + the 0.3s debounce. They can flake under heavy
/// machine load; rerun once before treating a 3s timeout as a real failure.
@MainActor
final class WorkTaskManagerWatcherTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-watcher-tests" }

    /// External atomic rewrite of a central backlog task is adopted without a forced reload.
    func testWatcherAdoptsAtomicCentralRewrite() async throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = manager.createTask(title: "Pre-plan draft") else {
            XCTFail("createTask returned nil"); return
        }
        manager.updateFields(id: seed.id) { $0.body = "Short draft" }

        try await Task.sleep(nanoseconds: 50_000_000)

        var planned = seed
        planned.title = "Planned via watcher"
        planned.body = "Agent wrote this atomically."
        let path = manager.filePath(for: seed)
        try planned.serialized()
            .data(using: .utf8)!
            .write(to: URL(fileURLWithPath: path), options: .atomic)

        let adopted = await waitUntil(timeout: 3) {
            guard let pool = manager.tasks.first(where: { $0.id == seed.id }) else { return false }
            return pool.title == "Planned via watcher"
                && pool.body == "Agent wrote this atomically."
        }
        XCTAssertTrue(adopted, "pool must adopt atomic central rewrite via watcher (no reloadFromDisk)")
    }

    /// External atomic rewrite of an open worktree TASK.md updates the pool's title and body.
    func testWatcherAdoptsAtomicWorktreeRewrite() async throws {
        let id = UUID()
        let worktreeTask = WorkTask(id: id, title: "In flight", worktree: "feature/watch")
        let worktreePath = try seedWorktreeTask(dir: "wt-watch", worktreeTask)

        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/watch", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])
        XCTAssertEqual(manager.task(forWorktree: "feature/watch")?.title, "In flight")

        try await Task.sleep(nanoseconds: 50_000_000)

        var advanced = worktreeTask
        advanced.title = "Broken down"
        advanced.body = "Expanded on disk"
        let path = manager.filePath(for: manager.task(forWorktree: "feature/watch")!)
        try advanced.serialized()
            .data(using: .utf8)!
            .write(to: URL(fileURLWithPath: path), options: .atomic)

        let adopted = await waitUntil(timeout: 3) {
            manager.task(forWorktree: "feature/watch")?.title == "Broken down"
        }
        XCTAssertTrue(adopted, "pool must adopt worktree title via watcher")
        XCTAssertEqual(manager.task(forWorktree: "feature/watch")?.body, "Expanded on disk")
    }

    /// After an atomic replace kills the watched inode, a second write must still be seen
    /// (file-watcher re-arm). Regression for dead-watcher after agent rewrite.
    func testWatcherReArmsAfterAtomicReplaceSeesSecondWrite() async throws {
        let id = UUID()
        let worktreeTask = WorkTask(id: id, title: "In flight", worktree: "feature/rearm")
        let worktreePath = try seedWorktreeTask(dir: "wt-rearm", worktreeTask)

        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/rearm", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])

        try await Task.sleep(nanoseconds: 50_000_000)

        let path = manager.filePath(for: manager.task(forWorktree: "feature/rearm")!)

        var first = worktreeTask
        first.title = "Broken down"
        try first.serialized()
            .data(using: .utf8)!
            .write(to: URL(fileURLWithPath: path), options: .atomic)

        let firstAdopted = await waitUntil(timeout: 3) {
            manager.task(forWorktree: "feature/rearm")?.title == "Broken down"
        }
        XCTAssertTrue(firstAdopted, "first atomic rewrite must land")

        // Let re-arm settle after the reload that followed the first write.
        try await Task.sleep(nanoseconds: 100_000_000)

        var second = first
        second.title = "Implementing"
        second.body = "Second agent write"
        try second.serialized()
            .data(using: .utf8)!
            .write(to: URL(fileURLWithPath: path), options: .atomic)

        let secondAdopted = await waitUntil(timeout: 3) {
            manager.task(forWorktree: "feature/rearm")?.title == "Implementing"
                && manager.task(forWorktree: "feature/rearm")?.body == "Second agent write"
        }
        XCTAssertTrue(
            secondAdopted,
            "second atomic rewrite must be seen after inode re-arm (dead-watcher regression)"
        )
    }

    func testWatcherSeesBacklogTaskWrittenWhenTasksDirectoryWasMissingAtLaunch() async throws {
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        let manager = WorkTaskManager(projectPath: tempRoot)
        let tasksDirectory = TaskFiles.tasksDirectory(inProject: tempRoot)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tasksDirectory, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let attributes = try? FileManager.default.attributesOfItem(atPath: tasksDirectory)
        let permissions = attributes?[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o700)

        let task = WorkTask(title: "Written by the CLI")
        try TaskFiles.write(task, toPath: TaskFiles.centralPath(for: task.id, tasksDirectory: tasksDirectory))

        let adopted = await waitUntil(timeout: 3) {
            manager.tasks.contains { $0.id == task.id && $0.title == "Written by the CLI" }
        }
        XCTAssertTrue(adopted, "backlog watcher must be armed even when .clearway/tasks was missing at init")
    }

    func testInitDoesNotRecreateAMissingProjectDirectory() {
        let movedProject = (tempRoot as NSString).appendingPathComponent("moved-away")
        _ = WorkTaskManager(projectPath: movedProject)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: movedProject),
            "opening a project whose folder was moved or deleted must not recreate it"
        )
    }

    // MARK: - Helpers

    private func seedWorktreeTask(dir: String, _ task: WorkTask) throws -> String {
        let worktreePath = (tempRoot as NSString).appendingPathComponent(dir)
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let taskMd = (clearway as NSString).appendingPathComponent("TASK.md")
        try task.serialized().write(toFile: taskMd, atomically: true, encoding: .utf8)
        return worktreePath
    }

    /// Poll until `condition` is true or `timeout` elapses. Returns whether it became true.
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}
