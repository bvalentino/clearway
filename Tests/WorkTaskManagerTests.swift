import XCTest
@testable import Clearway

@MainActor
final class WorkTaskManagerTests: XCTestCase {

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

    /// Regression lock: applying a stale editor buffer must preserve system-managed fields
    /// (status, worktree) and only update editor-owned fields (title, body).
    func testApplyEditorBufferPreservesSystemFields() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        guard let seed = manager.createTask(title: "Original") else {
            XCTFail("createTask returned nil")
            return
        }

        var mutated = seed
        mutated.body = "Original body"
        mutated.status = .inProgress
        mutated.worktree = "some-branch"
        manager.updateTask(mutated)

        let staleTask = WorkTask(
            id: seed.id,
            title: "Original",
            status: .new,
            worktree: nil,
            body: "User edit"
        )
        XCTAssertTrue(manager.applyEditorBuffer(staleTask.serialized(), expectedId: seed.id))

        guard let result = manager.tasks.first(where: { $0.id == seed.id }) else {
            XCTFail("Task not found in manager.tasks after applyEditorBuffer")
            return
        }
        XCTAssertEqual(result.status, .inProgress, "status must be preserved by applyEditorBuffer")
        XCTAssertEqual(result.worktree, "some-branch", "worktree must be preserved by applyEditorBuffer")
        XCTAssertEqual(result.body, "User edit", "body must be taken from the editor buffer")
        XCTAssertEqual(result.title, "Original", "title must be taken from the editor buffer")

        let diskContent = try String(contentsOfFile: manager.filePath(for: result), encoding: .utf8)
        let reparsed = WorkTask.parse(from: diskContent, id: result.id, createdAt: result.createdAt)
        XCTAssertEqual(reparsed?.status, .inProgress)
        XCTAssertEqual(reparsed?.worktree, "some-branch")
        XCTAssertEqual(reparsed?.body, "User edit")
    }

    /// Fallback path: when no task with expectedId exists in memory, the parsed task is
    /// written wholesale to disk. We verify the disk file (the authoritative store) because
    /// `updateTask` only updates the in-memory array for ids already present.
    func testApplyEditorBufferFallsBackWhenNoExistingTask() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        let novelTask = WorkTask(
            id: UUID(),
            title: "Brand New",
            status: .readyToStart,
            worktree: nil,
            body: "Fallback body"
        )
        XCTAssertTrue(manager.applyEditorBuffer(novelTask.serialized(), expectedId: novelTask.id))

        let diskPath = manager.filePath(for: novelTask)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diskPath))
        let diskContent = try String(contentsOfFile: diskPath, encoding: .utf8)
        let reparsed = WorkTask.parse(from: diskContent, id: novelTask.id, createdAt: novelTask.createdAt)
        XCTAssertEqual(reparsed?.title, "Brand New")
        XCTAssertEqual(reparsed?.status, .readyToStart)
        XCTAssertEqual(reparsed?.body, "Fallback body")
    }
}
