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

    /// `hidden: true` must round-trip through serialize → parse so shadow tasks keep their flag.
    func testHiddenRoundTripsWhenTrue() throws {
        var task = WorkTask(id: UUID(), title: "Shadow", status: .new, worktree: "feature/x", body: "")
        task.hidden = true

        let serialized = task.serialized()
        XCTAssertTrue(serialized.contains("hidden: true"), "frontmatter must emit hidden: true when hidden")

        let reparsed = WorkTask.parse(from: serialized, id: task.id, createdAt: task.createdAt)
        XCTAssertEqual(reparsed?.hidden, true)
        XCTAssertEqual(reparsed?.title, "Shadow")
        XCTAssertEqual(reparsed?.worktree, "feature/x")
    }

    /// Default (exposed) tasks must not emit `hidden:` at all — keeps old files diff-clean.
    func testHiddenOmittedFromFrontmatterWhenFalse() throws {
        let task = WorkTask(id: UUID(), title: "Regular", status: .new, worktree: nil, body: "")
        XCTAssertFalse(task.hidden)

        let serialized = task.serialized()
        XCTAssertFalse(serialized.contains("hidden:"), "frontmatter must omit hidden key when false")

        let reparsed = WorkTask.parse(from: serialized, id: task.id, createdAt: task.createdAt)
        XCTAssertEqual(reparsed?.hidden, false)
    }

    /// Creating a shadow task for a branch yields a hidden `.new` task linked to the branch.
    func testCreateShadowTaskCreatesHiddenTaskLinkedToBranch() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        guard let shadow = manager.createShadowTask(forBranch: "feature/alpha") else {
            XCTFail("createShadowTask returned nil")
            return
        }

        XCTAssertTrue(shadow.hidden)
        XCTAssertEqual(shadow.status, .inProgress, ".new / .readyToStart are planning-only; worktree tasks start in-progress")
        XCTAssertEqual(shadow.worktree, "feature/alpha")
        XCTAssertEqual(shadow.title, "feature/alpha")
        XCTAssertTrue(manager.tasks.contains(where: { $0.id == shadow.id }))
    }

    /// createShadowTask is idempotent: if a task already links the branch, return the existing
    /// task rather than creating a duplicate. Task-initiated worktrees must not get a shadow.
    func testCreateShadowTaskReturnsExistingTaskForBranch() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        guard let original = manager.createTask(title: "Real task") else {
            XCTFail("createTask returned nil")
            return
        }
        var updated = original
        updated.worktree = "feature/real"
        manager.updateTask(updated)

        let result = manager.createShadowTask(forBranch: "feature/real")
        XCTAssertEqual(result?.id, original.id)
        XCTAssertEqual(result?.hidden, false, "existing exposed task must not be flipped to hidden")
        XCTAssertEqual(manager.tasks.filter { $0.worktree == "feature/real" }.count, 1)
    }

    /// `expose` flips a hidden task's flag to false and persists through reload.
    func testExposeFlipsHiddenToFalse() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        guard let shadow = manager.createShadowTask(forBranch: "feature/beta") else {
            XCTFail("createShadowTask returned nil")
            return
        }
        XCTAssertTrue(shadow.hidden)

        let exposed = manager.expose(shadow)
        XCTAssertFalse(exposed.hidden)

        guard let reloaded = manager.tasks.first(where: { $0.id == shadow.id }) else {
            XCTFail("Task missing after expose")
            return
        }
        XCTAssertFalse(reloaded.hidden)

        let diskContent = try String(contentsOfFile: manager.filePath(for: reloaded), encoding: .utf8)
        let reparsed = WorkTask.parse(from: diskContent, id: reloaded.id, createdAt: reloaded.createdAt)
        XCTAssertEqual(reparsed?.hidden, false)
    }

    /// The editor buffer never touches `hidden` — it's a system-managed flag like `status` and
    /// `worktree`. A stale buffer saved against a shadow task must not expose it.
    func testApplyEditorBufferPreservesHiddenFlag() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        guard let shadow = manager.createShadowTask(forBranch: "feature/gamma") else {
            XCTFail("createShadowTask returned nil")
            return
        }

        var staleBuffer = shadow
        staleBuffer.hidden = false
        staleBuffer.body = "User edit"
        XCTAssertTrue(manager.applyEditorBuffer(staleBuffer.serialized(), expectedId: shadow.id))

        guard let result = manager.tasks.first(where: { $0.id == shadow.id }) else {
            XCTFail("Task missing after applyEditorBuffer")
            return
        }
        XCTAssertTrue(result.hidden, "hidden must be preserved from the existing task")
        XCTAssertEqual(result.body, "User edit")
    }

    /// Legacy task files on disk (no `hidden` key) must parse as `hidden == false`.
    func testLegacyFileWithoutHiddenKeyParsesAsFalse() throws {
        let legacy = """
        ---
        title: "Legacy"
        status: new
        worktree: null
        ---

        body
        """
        let reparsed = WorkTask.parse(from: legacy, id: UUID(), createdAt: Date())
        XCTAssertEqual(reparsed?.hidden, false)
        XCTAssertEqual(reparsed?.title, "Legacy")
    }

    /// The CTA path: with no task linked to the branch, `createExposedTask` creates a fresh
    /// exposed task (hidden == false) titled after the branch. This is what the aside button
    /// calls when the worktree has no shadow task at all (pre-change worktrees).
    func testCreateExposedTaskCreatesVisibleTaskWhenNoneExists() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        guard let created = manager.createExposedTask(forBranch: "feature/delta") else {
            XCTFail("createExposedTask returned nil")
            return
        }

        XCTAssertFalse(created.hidden)
        XCTAssertEqual(created.status, .inProgress, "worktree-linked tasks start in-progress, not in backlog")
        XCTAssertEqual(created.worktree, "feature/delta")
        XCTAssertEqual(created.title, "feature/delta")
        XCTAssertTrue(manager.tasks.contains(where: { $0.id == created.id }))
    }

    /// The CTA path for worktrees whose shadow was auto-created: `createExposedTask` must
    /// flip the existing hidden task rather than creating a duplicate. Preserving the id is
    /// what lets the task retain any user-written body, tokens, or history.
    func testCreateExposedTaskExposesExistingHiddenShadow() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        guard let shadow = manager.createShadowTask(forBranch: "feature/epsilon") else {
            XCTFail("createShadowTask returned nil")
            return
        }
        XCTAssertTrue(shadow.hidden)

        guard let exposed = manager.createExposedTask(forBranch: "feature/epsilon") else {
            XCTFail("createExposedTask returned nil")
            return
        }
        XCTAssertEqual(exposed.id, shadow.id, "must reuse the shadow task, not create a duplicate")
        XCTAssertFalse(exposed.hidden)
        XCTAssertEqual(manager.tasks.filter { $0.worktree == "feature/epsilon" }.count, 1)
    }

    /// Idempotence: `createExposedTask` against an already-exposed task returns it unchanged.
    /// A rapid double-click on the CTA must not clobber the task's state.
    func testCreateExposedTaskIsNoOpForAlreadyExposedTask() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        guard let first = manager.createExposedTask(forBranch: "feature/zeta") else {
            XCTFail("first createExposedTask returned nil")
            return
        }

        guard let second = manager.createExposedTask(forBranch: "feature/zeta") else {
            XCTFail("second createExposedTask returned nil")
            return
        }
        XCTAssertEqual(second.id, first.id)
        XCTAssertFalse(second.hidden)
        XCTAssertEqual(manager.tasks.filter { $0.worktree == "feature/zeta" }.count, 1)
    }

    /// `titlesByBranch` drives the sidebar's worktree label. Hidden placeholder tasks must be
    /// excluded so a shadow-only worktree shows its branch name instead of the placeholder title.
    func testTitlesByBranchExcludesHiddenTasks() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        _ = manager.createShadowTask(forBranch: "feature/shadow")
        guard let exposed = manager.createTask(title: "Real work") else {
            XCTFail("createTask returned nil")
            return
        }
        var updated = exposed
        updated.worktree = "feature/real"
        manager.updateTask(updated)

        let titles = manager.titlesByBranch
        XCTAssertNil(titles["feature/shadow"], "hidden tasks must not leak titles into the sidebar")
        XCTAssertEqual(titles["feature/real"], "Real work")
    }

    /// Changing status on a placeholder task must persist without flipping `hidden` — the user
    /// can track worktree state without surfacing it in Planning.
    func testSetStatusOnHiddenTaskPreservesHiddenFlag() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        guard let shadow = manager.createShadowTask(forBranch: "feature/state") else {
            XCTFail("createShadowTask returned nil")
            return
        }
        manager.setStatus(shadow, to: .qa)

        guard let reloaded = manager.tasks.first(where: { $0.id == shadow.id }) else {
            XCTFail("Task missing after setStatus")
            return
        }
        XCTAssertEqual(reloaded.status, .qa)
        XCTAssertTrue(reloaded.hidden, "hidden must survive a status change")
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
