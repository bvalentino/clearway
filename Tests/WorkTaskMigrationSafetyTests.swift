import XCTest
@testable import Clearway

/// Data-safety tests for the task-file location migration: migration must defer until the worktree
/// set is loaded, must preserve identity when adopting legacy files, and must never delete a central
/// task to win a worktree-slot collision.
@MainActor
final class WorkTaskMigrationSafetyTests: XCTestCase {

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

    /// Writes a task as a central `<UUID>.md` and returns its path.
    @discardableResult
    private func seedCentralTask(_ task: WorkTask) throws -> String {
        let centralDir = (tempRoot as NSString).appendingPathComponent(".clearway/tasks")
        try FileManager.default.createDirectory(atPath: centralDir, withIntermediateDirectories: true)
        let path = (centralDir as NSString).appendingPathComponent("\(task.id.uuidString).md")
        try task.serialized().write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Migration defers (does not consume its one-shot) while the live worktree set is empty —
    /// i.e. not loaded yet — so it can still run once worktrees appear. Guards against destructively
    /// reconciling against a not-yet-loaded set.
    func testMigrationDefersUntilWorktreeSetLoaded() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        let orphan = WorkTask(id: UUID(), title: "Old done", status: .done, worktree: nil)
        let orphanPath = try seedCentralTask(orphan)

        manager.worktreeResolver = { [] }  // worktrees not loaded yet
        manager.migrateCentralTasks()
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanPath), "migration must not act before the worktree set loads")

        // Once the set loads, the deferred migration runs and archives the terminal orphan.
        manager.worktreeResolver = { [(branch: "main", path: (self.tempRoot as NSString).appendingPathComponent("wt-main"))] }
        manager.migrateCentralTasks()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanPath), "deferred migration must run once worktrees are known")
    }

    /// Relocating a legacy central file (filename UUID, NO frontmatter `id`) injects that UUID into
    /// the moved `TASK.md`, so identity survives the rename and reload doesn't skip the id-less file.
    func testRelocatePreservesIdentityForLegacyFileWithoutFrontmatterId() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        let id = UUID()
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-legacy")
        manager.worktreeResolver = { [(branch: "feature/legacy", path: worktreePath)] }

        let centralDir = (tempRoot as NSString).appendingPathComponent(".clearway/tasks")
        try FileManager.default.createDirectory(atPath: centralDir, withIntermediateDirectories: true)
        let legacy = """
        ---
        title: "Legacy"
        status: in_progress
        worktree: "feature/legacy"
        ---

        legacy body
        """
        let centralFile = (centralDir as NSString).appendingPathComponent("\(id.uuidString).md")
        try legacy.write(toFile: centralFile, atomically: true, encoding: .utf8)

        manager.relocateTaskToWorktree(id: id, worktreePath: worktreePath)

        let taskMd = ((worktreePath as NSString).appendingPathComponent(".clearway") as NSString)
            .appendingPathComponent("TASK.md")
        let content = try String(contentsOfFile: taskMd, encoding: .utf8)
        XCTAssertTrue(content.contains("id: \(id.uuidString)"), "filename UUID must be injected as the frontmatter id")
        let reloaded = manager.tasks.first { $0.id == id }
        XCTAssertNotNil(reloaded, "relocated legacy task must remain in the pool (not skipped as id-less)")
        XCTAssertEqual(reloaded?.worktree, "feature/legacy", "link preserved")
        XCTAssertEqual(reloaded?.body, "legacy body", "body preserved")
    }

    /// Data-safety guarantee: relocation must NEVER delete the central task to win a collision.
    /// If the worktree slot already holds a (different) `TASK.md` — e.g. a leftover empty shadow —
    /// the central file is left intact, so the user never loses a real task to an empty placeholder.
    func testRelocateNeverDeletesCentralWhenWorktreeSlotOccupied() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        let id = UUID()
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-collide")
        manager.worktreeResolver = { [(branch: "feature/collide", path: worktreePath)] }

        // Real central task linked to the branch.
        let centralDir = (tempRoot as NSString).appendingPathComponent(".clearway/tasks")
        try FileManager.default.createDirectory(atPath: centralDir, withIntermediateDirectories: true)
        let real = WorkTask(id: id, title: "Real", status: .inProgress, worktree: "feature/collide", body: "real body")
        let centralFile = (centralDir as NSString).appendingPathComponent("\(id.uuidString).md")
        try real.serialized().write(toFile: centralFile, atomically: true, encoding: .utf8)

        // A different, pre-existing empty shadow already occupies the worktree slot.
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let taskMd = (clearway as NSString).appendingPathComponent("TASK.md")
        var shadow = WorkTask(title: "", status: .inProgress, worktree: "feature/collide")
        shadow.hidden = true
        try shadow.serialized().write(toFile: taskMd, atomically: true, encoding: .utf8)
        let shadowBefore = try String(contentsOfFile: taskMd, encoding: .utf8)

        manager.relocateTaskToWorktree(id: id, worktreePath: worktreePath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: centralFile), "central task must NOT be deleted on collision")
        XCTAssertEqual(manager.tasks.first { $0.id == id }?.body, "real body", "real task content must survive")
        XCTAssertEqual(try String(contentsOfFile: taskMd, encoding: .utf8), shadowBefore, "existing worktree TASK.md untouched")
    }
}
