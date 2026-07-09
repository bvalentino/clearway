import XCTest
@testable import Clearway

/// Integration tests for the production DispatchSource path (not `reloadFromDisk()`).
///
/// These exercise real file-system events + the 0.3s debounce. They can flake under heavy
/// machine load; a 3s timeout matches `WorktreeGroupStoreTests.testWatcherFiresOnExternalWrite`.
/// Rerun once before treating a timeout as a real failure.
@MainActor
final class WorkTaskManagerWatcherTests: XCTestCase {

    private var tempRoot: String!

    override func setUp() {
        super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-watcher-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root = tempRoot {
            try? FileManager.default.removeItem(atPath: root)
        }
        tempRoot = nil
        super.tearDown()
    }

    /// External atomic rewrite of a central backlog task is adopted without a forced reload.
    func testWatcherAdoptsAtomicCentralRewrite() async throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = manager.createTask(title: "Pre-plan draft") else {
            XCTFail("createTask returned nil"); return
        }
        manager.updateFields(id: seed.id) {
            $0.body = "Short draft"
            $0.status = WorkTask.ReservedStatus.new
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        var planned = seed
        planned.title = "Planned via watcher"
        planned.body = "Agent wrote this atomically."
        planned.status = WorkTask.ReservedStatus.readyToStart
        let path = manager.filePath(for: seed)
        try planned.serialized()
            .data(using: .utf8)!
            .write(to: URL(fileURLWithPath: path), options: .atomic)

        let adopted = await waitUntil(timeout: 3) {
            guard let pool = manager.tasks.first(where: { $0.id == seed.id }) else { return false }
            return pool.title == "Planned via watcher"
                && pool.body == "Agent wrote this atomically."
                && pool.status == WorkTask.ReservedStatus.readyToStart
        }
        XCTAssertTrue(adopted, "pool must adopt atomic central rewrite via watcher (no reloadFromDisk)")
    }

    /// External atomic rewrite of an open worktree TASK.md updates status and notifies the engine.
    func testWatcherAdoptsAtomicWorktreeStatusRewrite() async throws {
        let id = UUID()
        let worktreeTask = WorkTask(id: id, title: "In flight", status: "spec", worktree: "feature/watch")
        let worktreePath = try seedWorktreeTask(dir: "wt-watch", worktreeTask)

        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/watch", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])
        XCTAssertEqual(manager.task(forWorktree: "feature/watch")?.status, "spec")

        var notifiedBranches: [String] = []
        manager.onTasksReloaded = { branches in notifiedBranches = branches }

        try await Task.sleep(nanoseconds: 50_000_000)

        var advanced = worktreeTask
        advanced.status = "work_breakdown"
        advanced.body = "Expanded on disk"
        let path = manager.filePath(for: manager.task(forWorktree: "feature/watch")!)
        try advanced.serialized()
            .data(using: .utf8)!
            .write(to: URL(fileURLWithPath: path), options: .atomic)

        let adopted = await waitUntil(timeout: 3) {
            manager.task(forWorktree: "feature/watch")?.status == "work_breakdown"
        }
        XCTAssertTrue(adopted, "pool must adopt worktree status via watcher")
        XCTAssertEqual(manager.task(forWorktree: "feature/watch")?.body, "Expanded on disk")
        XCTAssertTrue(
            notifiedBranches.contains("feature/watch"),
            "onTasksReloaded must fire so the engine re-evaluates"
        )
    }

    /// After an atomic replace kills the watched inode, a second write must still be seen
    /// (file-watcher re-arm). Regression for dead-watcher after agent rewrite.
    func testWatcherReArmsAfterAtomicReplaceSeesSecondWrite() async throws {
        let id = UUID()
        let worktreeTask = WorkTask(id: id, title: "In flight", status: "spec", worktree: "feature/rearm")
        let worktreePath = try seedWorktreeTask(dir: "wt-rearm", worktreeTask)

        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/rearm", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])

        try await Task.sleep(nanoseconds: 50_000_000)

        let path = manager.filePath(for: manager.task(forWorktree: "feature/rearm")!)

        var first = worktreeTask
        first.status = "work_breakdown"
        try first.serialized()
            .data(using: .utf8)!
            .write(to: URL(fileURLWithPath: path), options: .atomic)

        let firstAdopted = await waitUntil(timeout: 3) {
            manager.task(forWorktree: "feature/rearm")?.status == "work_breakdown"
        }
        XCTAssertTrue(firstAdopted, "first atomic rewrite must land")

        // Let re-arm settle after the reload that followed the first write.
        try await Task.sleep(nanoseconds: 100_000_000)

        var second = first
        second.status = "implement"
        second.body = "Second agent write"
        try second.serialized()
            .data(using: .utf8)!
            .write(to: URL(fileURLWithPath: path), options: .atomic)

        let secondAdopted = await waitUntil(timeout: 3) {
            manager.task(forWorktree: "feature/rearm")?.status == "implement"
                && manager.task(forWorktree: "feature/rearm")?.body == "Second agent write"
        }
        XCTAssertTrue(
            secondAdopted,
            "second atomic rewrite must be seen after inode re-arm (dead-watcher regression)"
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
