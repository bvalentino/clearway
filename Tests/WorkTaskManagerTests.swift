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

        manager.updateFields(id: seed.id) {
            $0.body = "Original body"
            $0.status = WorkTask.ReservedStatus.inProgress
            $0.worktree = "some-branch"
        }

        let staleTask = WorkTask(
            id: seed.id,
            title: "Original",
            status: WorkTask.ReservedStatus.new,
            worktree: nil,
            body: "User edit"
        )
        XCTAssertTrue(manager.applyEditorBuffer(staleTask.serialized(), expectedId: seed.id))

        guard let result = manager.tasks.first(where: { $0.id == seed.id }) else {
            XCTFail("Task not found in manager.tasks after applyEditorBuffer")
            return
        }
        XCTAssertEqual(result.status, WorkTask.ReservedStatus.inProgress, "status must be preserved by applyEditorBuffer")
        XCTAssertEqual(result.worktree, "some-branch", "worktree must be preserved by applyEditorBuffer")
        XCTAssertEqual(result.body, "User edit", "body must be taken from the editor buffer")
        XCTAssertEqual(result.title, "Original", "title must be taken from the editor buffer")

        let diskContent = try String(contentsOfFile: manager.filePath(for: result), encoding: .utf8)
        let reparsed = WorkTask.parse(from: diskContent, id: result.id, createdAt: result.createdAt)
        XCTAssertEqual(reparsed?.status, WorkTask.ReservedStatus.inProgress)
        XCTAssertEqual(reparsed?.worktree, "some-branch")
        XCTAssertEqual(reparsed?.body, "User edit")
    }

    /// `hidden: true` must round-trip through serialize → parse so shadow tasks keep their flag.
    func testHiddenRoundTripsWhenTrue() throws {
        var task = WorkTask(id: UUID(), title: "Shadow", status: WorkTask.ReservedStatus.new, worktree: "feature/x", body: "")
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
        let task = WorkTask(id: UUID(), title: "Regular", status: WorkTask.ReservedStatus.new, worktree: nil, body: "")
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
        XCTAssertEqual(shadow.status, WorkTask.ReservedStatus.inProgress, ".new / .readyToStart are planning-only; worktree tasks start in-progress")
        XCTAssertEqual(shadow.worktree, "feature/alpha")
        XCTAssertEqual(shadow.title, "", "placeholder tasks have no title until the user fills it in")
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
        manager.updateFields(id: original.id) { $0.worktree = "feature/real" }

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
        XCTAssertEqual(created.status, WorkTask.ReservedStatus.inProgress, "worktree-linked tasks start in-progress, not in backlog")
        XCTAssertEqual(created.worktree, "feature/delta")
        XCTAssertEqual(created.title, "", "CTA-created tasks have no title until the editor fills it in")
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

    /// `titlesByBranch` drives the sidebar's worktree label. Hidden placeholder tasks and
    /// empty-title tasks must be excluded so the sidebar falls back to the branch name.
    func testTitlesByBranchExcludesHiddenAndEmptyTitleTasks() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        _ = manager.createShadowTask(forBranch: "feature/shadow")
        _ = manager.createExposedTask(forBranch: "feature/blank") // exposed, title == ""
        guard let exposed = manager.createTask(title: "Real work") else {
            XCTFail("createTask returned nil")
            return
        }
        manager.updateFields(id: exposed.id) { $0.worktree = "feature/real" }

        let titles = manager.titlesByBranch
        XCTAssertNil(titles["feature/shadow"], "hidden tasks must not leak titles into the sidebar")
        XCTAssertNil(titles["feature/blank"], "empty titles must not replace the branch label with blank")
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
        manager.setStatus(shadow, to: WorkTask.ReservedStatus.qa)

        guard let reloaded = manager.tasks.first(where: { $0.id == shadow.id }) else {
            XCTFail("Task missing after setStatus")
            return
        }
        XCTAssertEqual(reloaded.status, WorkTask.ReservedStatus.qa)
        XCTAssertTrue(reloaded.hidden, "hidden must survive a status change")
    }

    // MARK: - Location-aware filePath routing (Task 2)

    /// A task linked to a live worktree resolves to that worktree's `.clearway/TASK.md`.
    func testFilePathResolvesToWorktreeForLinkedTask() throws {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-alpha")
        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/alpha", path: worktreePath)] }

        let task = WorkTask(id: UUID(), title: "Linked", status: WorkTask.ReservedStatus.inProgress, worktree: "feature/alpha")
        let expected = (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
        XCTAssertEqual(manager.filePath(for: task), expected)
    }

    /// A task with no live worktree (backlog, or branch not currently checked out) resolves to
    /// the central `<UUID>.md`.
    func testFilePathResolvesToCentralWhenNoLiveWorktree() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [] }

        let task = WorkTask(id: UUID(), title: "Backlog", status: WorkTask.ReservedStatus.new, worktree: nil)
        let expected = ((tempRoot as NSString).appendingPathComponent(".clearway/tasks") as NSString)
            .appendingPathComponent("\(task.id.uuidString).md")
        XCTAssertEqual(manager.filePath(for: task), expected)
    }

    /// A novel worktree-linked task (applyEditorBuffer insert) lands in the worktree's `TASK.md`,
    /// not the central dir.
    func testWriteLandsInWorktreeForLinkedTask() throws {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-beta")
        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/beta", path: worktreePath)] }

        let task = WorkTask(id: UUID(), title: "In worktree", status: WorkTask.ReservedStatus.inProgress, worktree: "feature/beta")
        XCTAssertTrue(manager.applyEditorBuffer(task.serialized(), expectedId: task.id))

        let taskMd = (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskMd), "TASK.md must be written into the worktree")
        let centralDir = (tempRoot as NSString).appendingPathComponent(".clearway/tasks")
        let centralFile = (centralDir as NSString).appendingPathComponent("\(task.id.uuidString).md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: centralFile), "no central residue for a worktree-linked task")
    }

    // MARK: - Merge-load (Task 3)

    /// Writes a `TASK.md` into `<tempRoot>/<dir>/.clearway/` and returns the worktree path.
    @discardableResult
    private func seedWorktreeTask(dir: String, _ task: WorkTask) throws -> String {
        let worktreePath = (tempRoot as NSString).appendingPathComponent(dir)
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let taskMd = (clearway as NSString).appendingPathComponent("TASK.md")
        try task.serialized().write(toFile: taskMd, atomically: true, encoding: .utf8)
        return worktreePath
    }

    /// `reload()` merges the central backlog and every live worktree's `TASK.md` into one pool;
    /// `task(forWorktree:)` resolves the worktree copy.
    func testMergeLoadCombinesCentralAndWorktreeTasks() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        guard let backlog = manager.createTask(title: "Backlog item") else {
            XCTFail("createTask returned nil"); return
        }

        let worktreeTask = WorkTask(id: UUID(), title: "Active item", status: WorkTask.ReservedStatus.inProgress, worktree: "feature/active")
        let worktreePath = try seedWorktreeTask(dir: "wt-active", worktreeTask)
        manager.worktreeResolver = { [(branch: "feature/active", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])  // triggers re-merge

        XCTAssertTrue(manager.tasks.contains { $0.id == backlog.id }, "central backlog task must remain in the pool")
        XCTAssertEqual(manager.task(forWorktree: "feature/active")?.id, worktreeTask.id, "worktree task must be loaded and resolvable")
    }

    /// When the same task id exists both centrally and in a worktree (mid-move), the worktree
    /// copy wins so a half-finished move never shows the stale central content.
    func testMergeLoadPrefersWorktreeCopyOnDuplicateId() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        let sharedId = UUID()

        // Stale central copy.
        let central = WorkTask(id: sharedId, title: "Stale central", status: WorkTask.ReservedStatus.new, worktree: "feature/dup")
        let centralDir = (tempRoot as NSString).appendingPathComponent(".clearway/tasks")
        try FileManager.default.createDirectory(atPath: centralDir, withIntermediateDirectories: true)
        try central.serialized().write(
            toFile: (centralDir as NSString).appendingPathComponent("\(sharedId.uuidString).md"),
            atomically: true, encoding: .utf8
        )

        // Fresh worktree copy with the same id.
        let worktreeTask = WorkTask(id: sharedId, title: "Fresh worktree", status: WorkTask.ReservedStatus.inProgress, worktree: "feature/dup")
        let worktreePath = try seedWorktreeTask(dir: "wt-dup", worktreeTask)
        manager.worktreeResolver = { [(branch: "feature/dup", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])

        let matches = manager.tasks.filter { $0.id == sharedId }
        XCTAssertEqual(matches.count, 1, "duplicate ids must dedupe to a single task")
        XCTAssertEqual(matches.first?.title, "Fresh worktree", "the worktree copy must win the dedupe")
    }

    /// `setWatchedWorktrees` re-merges against the current resolver — surfacing worktree tasks.
    func testSetWatchedWorktreesReMerges() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        let worktreeTask = WorkTask(id: UUID(), title: "Surfaced", status: WorkTask.ReservedStatus.inProgress, worktree: "feature/surf")
        let worktreePath = try seedWorktreeTask(dir: "wt-surf", worktreeTask)

        // Before wiring the resolver, the worktree task is invisible.
        XCTAssertFalse(manager.tasks.contains { $0.id == worktreeTask.id })

        manager.worktreeResolver = { [(branch: "feature/surf", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])
        XCTAssertTrue(manager.tasks.contains { $0.id == worktreeTask.id }, "re-merge must surface the worktree task")
    }

    /// A worktree `TASK.md` whose frontmatter carries no `id` is skipped, not loaded under a fresh
    /// random UUID — otherwise its identity would flap on every reload. (The filename `TASK.md`
    /// carries no UUID, so frontmatter is the only identity source.)
    func testWorktreeTaskWithoutFrontmatterIdIsSkipped() throws {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-noid")
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let taskMd = (clearway as NSString).appendingPathComponent("TASK.md")
        // Agent/legacy-written content with no `id:` line.
        let content = """
        ---
        title: "No id"
        status: in_progress
        worktree: feature/noid
        ---

        body
        """
        try content.write(toFile: taskMd, atomically: true, encoding: .utf8)

        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/noid", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])  // triggers re-merge

        XCTAssertNil(manager.task(forWorktree: "feature/noid"), "a worktree TASK.md without an id must be skipped")
        XCTAssertTrue(manager.tasks.isEmpty, "no phantom task should be loaded")
    }

    /// A worktree `TASK.md` *with* a frontmatter `id` keeps that stable identity across reloads —
    /// the complement of the skip case above.
    func testWorktreeTaskKeepsStableIdAcrossReloads() throws {
        let id = UUID()
        let worktreeTask = WorkTask(id: id, title: "Stable", status: WorkTask.ReservedStatus.inProgress, worktree: "feature/stable")
        let worktreePath = try seedWorktreeTask(dir: "wt-stable", worktreeTask)

        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/stable", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])
        XCTAssertEqual(manager.task(forWorktree: "feature/stable")?.id, id)

        manager.setWatchedWorktrees([worktreePath])  // reload again
        XCTAssertEqual(manager.task(forWorktree: "feature/stable")?.id, id, "id must be stable across reloads")
    }

    // MARK: - Shadow/exposed creation routed into the worktree (Task 5)

    /// A shadow task created for a live worktree must land in that worktree's `TASK.md`, not the
    /// central directory — its link + the location-routing in `write` carry it there.
    func testCreateShadowTaskWritesIntoWorktree() throws {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-shadow")
        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/shadow-wt", path: worktreePath)] }

        _ = manager.createShadowTask(forBranch: "feature/shadow-wt")

        let taskMd = ((worktreePath as NSString).appendingPathComponent(".clearway") as NSString)
            .appendingPathComponent("TASK.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskMd), "shadow task must be written into the worktree")
        let centralDir = (tempRoot as NSString).appendingPathComponent(".clearway/tasks")
        let centralCount = (try? FileManager.default.contentsOfDirectory(atPath: centralDir))?.filter { $0.hasSuffix(".md") }.count ?? 0
        XCTAssertEqual(centralCount, 0, "no central residue for a worktree shadow task")
    }

    /// Exposing a worktree shadow keeps the file in the worktree (flips `hidden` in place).
    func testExposeKeepsTaskInWorktree() throws {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-expose")
        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/expose-wt", path: worktreePath)] }

        guard let shadow = manager.createShadowTask(forBranch: "feature/expose-wt") else {
            XCTFail("createShadowTask returned nil"); return
        }
        _ = manager.expose(shadow)

        let taskMd = ((worktreePath as NSString).appendingPathComponent(".clearway") as NSString)
            .appendingPathComponent("TASK.md")
        let content = try String(contentsOfFile: taskMd, encoding: .utf8)
        let reparsed = WorkTask.parse(from: content, id: shadow.id, createdAt: Date())
        XCTAssertEqual(reparsed?.hidden, false, "expose must persist hidden=false into the worktree TASK.md")
    }

    // MARK: - Relocation on worktree creation (Task 4)

    /// Relocating a backlog task moves `<UUID>.md` → `<worktree>/.clearway/TASK.md`: gone
    /// centrally, present in the worktree, identity preserved, no central residue.
    func testRelocateTaskMovesCentralFileIntoWorktree() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        guard let task = manager.createTask(title: "To relocate") else {
            XCTFail("createTask returned nil"); return
        }
        // Link the task to a branch and a live worktree (the state after startTask + createWorktree).
        var linked = task
        linked.worktree = "feature/move"
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-move")
        // Resolver returns the worktree so post-move resolution finds TASK.md.
        manager.worktreeResolver = { [(branch: "feature/move", path: worktreePath)] }
        // updateFields would now write to the worktree; instead simulate the pre-move central file by
        // writing it centrally with the link already set.
        let centralDir = (tempRoot as NSString).appendingPathComponent(".clearway/tasks")
        try FileManager.default.createDirectory(atPath: centralDir, withIntermediateDirectories: true)
        let centralFile = (centralDir as NSString).appendingPathComponent("\(task.id.uuidString).md")
        try linked.serialized().write(toFile: centralFile, atomically: true, encoding: .utf8)

        manager.relocateTaskToWorktree(id: task.id, worktreePath: worktreePath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: centralFile), "central file must be gone after the move")
        let taskMd = ((worktreePath as NSString).appendingPathComponent(".clearway") as NSString)
            .appendingPathComponent("TASK.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskMd), "TASK.md must exist in the worktree")
        XCTAssertEqual(manager.tasks.first(where: { $0.id == task.id })?.worktree, "feature/move", "identity + link preserved")
    }

    /// Relocation is idempotent: a second call with the central file already gone is a no-op and
    /// does not throw or duplicate.
    func testRelocateTaskIsIdempotent() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        guard let task = manager.createTask(title: "Idempotent") else {
            XCTFail("createTask returned nil"); return
        }
        var linked = task
        linked.worktree = "feature/idem"
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-idem")
        manager.worktreeResolver = { [(branch: "feature/idem", path: worktreePath)] }
        let centralDir = (tempRoot as NSString).appendingPathComponent(".clearway/tasks")
        let centralFile = (centralDir as NSString).appendingPathComponent("\(task.id.uuidString).md")
        try linked.serialized().write(toFile: centralFile, atomically: true, encoding: .utf8)

        manager.relocateTaskToWorktree(id: task.id, worktreePath: worktreePath)
        manager.relocateTaskToWorktree(id: task.id, worktreePath: worktreePath)  // no-op

        XCTAssertEqual(manager.tasks.filter { $0.id == task.id }.count, 1)
    }

    /// Fallback path: when no task with expectedId exists on disk/pool, the parsed task is
    /// written as a novel insert and re-merged into the pool.
    func testApplyEditorBufferFallsBackWhenNoExistingTask() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        let novelTask = WorkTask(
            id: UUID(),
            title: "Brand New",
            status: WorkTask.ReservedStatus.readyToStart,
            worktree: nil,
            body: "Fallback body"
        )
        XCTAssertTrue(manager.applyEditorBuffer(novelTask.serialized(), expectedId: novelTask.id))

        let diskPath = manager.filePath(for: novelTask)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diskPath))
        let diskContent = try String(contentsOfFile: diskPath, encoding: .utf8)
        let reparsed = WorkTask.parse(from: diskContent, id: novelTask.id, createdAt: novelTask.createdAt)
        XCTAssertEqual(reparsed?.title, "Brand New")
        XCTAssertEqual(reparsed?.status, WorkTask.ReservedStatus.readyToStart)
        XCTAssertEqual(reparsed?.body, "Fallback body")
    }

    // MARK: - Disk → pool freshness

    /// External rewrite of a central task file is adopted by the pool after reload.
    func testExternalCentralRewriteUpdatesPool() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = manager.createTask(title: "Pre-plan draft") else {
            XCTFail("createTask returned nil"); return
        }
        manager.updateFields(id: seed.id) {
            $0.body = "Short draft"
            $0.status = WorkTask.ReservedStatus.new
        }

        var planned = seed
        planned.title = "Planned title"
        planned.body = "Full planned brief with acceptance criteria."
        planned.status = WorkTask.ReservedStatus.readyToStart
        let path = manager.filePath(for: seed)
        try planned.serialized().write(toFile: path, atomically: true, encoding: .utf8)

        var reloadedCallbacks = 0
        manager.onTasksReloaded = { _ in reloadedCallbacks += 1 }
        manager.reloadFromDisk()

        guard let pool = manager.tasks.first(where: { $0.id == seed.id }) else {
            XCTFail("Task missing after reload"); return
        }
        XCTAssertEqual(pool.title, "Planned title")
        XCTAssertEqual(pool.body, "Full planned brief with acceptance criteria.")
        XCTAssertEqual(pool.status, WorkTask.ReservedStatus.readyToStart)
        // Central-only tasks have no worktree — onTasksReloaded is skipped when branch set is empty.
        XCTAssertEqual(reloadedCallbacks, 0)
    }

    /// Pure no-op reload does not fire onTasksReloaded (no needless engine churn).
    func testReloadNoOpDoesNotFireOnTasksReloaded() throws {
        let worktreeTask = WorkTask(
            id: UUID(),
            title: "Stable",
            status: "spec",
            worktree: "feature/noop"
        )
        let worktreePath = try seedWorktreeTask(dir: "wt-noop", worktreeTask)
        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/noop", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])

        var reloadedCallbacks = 0
        manager.onTasksReloaded = { _ in reloadedCallbacks += 1 }
        manager.reloadFromDisk()
        manager.reloadFromDisk()
        XCTAssertEqual(reloadedCallbacks, 0, "identical pool must not re-notify the engine")
    }

    /// External rewrite of an open worktree TASK.md status is adopted by the pool after reload.
    func testExternalWorktreeStatusRewriteUpdatesPool() throws {
        let id = UUID()
        let worktreeTask = WorkTask(id: id, title: "In flight", status: "spec", worktree: "feature/status")
        let worktreePath = try seedWorktreeTask(dir: "wt-status", worktreeTask)

        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/status", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])
        XCTAssertEqual(manager.task(forWorktree: "feature/status")?.status, "spec")

        var advanced = worktreeTask
        advanced.status = "work_breakdown"
        advanced.body = "Expanded brief"
        guard let pooled = manager.task(forWorktree: "feature/status") else {
            XCTFail("worktree task missing before rewrite"); return
        }
        try advanced.serialized().write(toFile: manager.filePath(for: pooled), atomically: true, encoding: .utf8)

        var reloadedBranches: [String] = []
        manager.onTasksReloaded = { branches in reloadedBranches = branches }
        manager.reloadFromDisk()

        XCTAssertEqual(manager.task(forWorktree: "feature/status")?.status, "work_breakdown")
        XCTAssertEqual(manager.task(forWorktree: "feature/status")?.body, "Expanded brief")
        XCTAssertTrue(reloadedBranches.contains("feature/status"))
    }

    // MARK: - Field writers re-base by id

    /// setAutopilot with a stale full snapshot must not clobber fresher title/body/status on disk.
    func testSetAutopilotWithStaleSnapshotPreservesDiskContent() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = manager.createTask(title: "Original") else {
            XCTFail("createTask returned nil"); return
        }
        manager.updateFields(id: seed.id) {
            $0.title = "Agent expanded title"
            $0.body = "Agent expanded body"
            $0.status = "work_breakdown"
            $0.autopilot = true
        }

        var stale = seed
        stale.title = "Original"
        stale.body = ""
        stale.status = "spec"
        stale.autopilot = true
        manager.setAutopilot(stale, to: false)

        guard let pool = manager.tasks.first(where: { $0.id == seed.id }) else {
            XCTFail("Task missing"); return
        }
        XCTAssertEqual(pool.autopilot, false)
        XCTAssertEqual(pool.title, "Agent expanded title")
        XCTAssertEqual(pool.body, "Agent expanded body")
        XCTAssertEqual(pool.status, "work_breakdown")

        let disk = try String(contentsOfFile: manager.filePath(for: pool), encoding: .utf8)
        let reparsed = WorkTask.parse(from: disk, id: seed.id, createdAt: seed.createdAt)
        XCTAssertEqual(reparsed?.title, "Agent expanded title")
        XCTAssertEqual(reparsed?.status, "work_breakdown")
        XCTAssertEqual(reparsed?.autopilot, false)
    }

    /// setStatus with a stale snapshot only changes status; title/body stay from disk base.
    func testSetStatusWithStaleSnapshotPreservesDiskContent() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = manager.createTask(title: "Original") else {
            XCTFail("createTask returned nil"); return
        }
        manager.updateFields(id: seed.id) {
            $0.title = "Fresh title"
            $0.body = "Fresh body"
            $0.status = WorkTask.ReservedStatus.inProgress
        }

        var stale = seed
        stale.title = "Original"
        stale.body = ""
        stale.status = WorkTask.ReservedStatus.new
        manager.setStatus(stale, to: WorkTask.ReservedStatus.qa)

        guard let pool = manager.tasks.first(where: { $0.id == seed.id }) else {
            XCTFail("Task missing"); return
        }
        XCTAssertEqual(pool.status, WorkTask.ReservedStatus.qa)
        XCTAssertEqual(pool.title, "Fresh title")
        XCTAssertEqual(pool.body, "Fresh body")
    }

    /// applyEditorBuffer re-bases system fields from disk so a lagging pool cannot re-publish
    /// a pre-agent status over a newer file.
    func testApplyEditorBufferRebasesSystemFieldsFromDisk() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = manager.createTask(title: "Title") else {
            XCTFail("createTask returned nil"); return
        }
        // Disk has advanced status; simulate stale pool by patching memory only.
        var onDisk = seed
        onDisk.status = "work_breakdown"
        onDisk.body = "Disk body"
        onDisk.title = "Disk title"
        try onDisk.serialized().write(toFile: manager.filePath(for: seed), atomically: true, encoding: .utf8)
        // Pool still has seed (stale) if we don't reload — force that shape:
        if let index = manager.tasks.firstIndex(where: { $0.id == seed.id }) {
            manager.tasks[index] = seed
        }

        var editor = seed
        editor.title = "User typed title"
        editor.body = "User typed body"
        editor.status = WorkTask.ReservedStatus.new
        XCTAssertTrue(manager.applyEditorBuffer(editor.serialized(), expectedId: seed.id))

        guard let pool = manager.tasks.first(where: { $0.id == seed.id }) else {
            XCTFail("Task missing"); return
        }
        XCTAssertEqual(pool.title, "User typed title")
        XCTAssertEqual(pool.body, "User typed body")
        XCTAssertEqual(pool.status, "work_breakdown", "status must come from disk, not the stale pool/buffer")
    }
}
