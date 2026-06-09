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
        var updated = exposed
        updated.worktree = "feature/real"
        manager.updateTask(updated)

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
        manager.setStatus(shadow, to: .qa)

        guard let reloaded = manager.tasks.first(where: { $0.id == shadow.id }) else {
            XCTFail("Task missing after setStatus")
            return
        }
        XCTAssertEqual(reloaded.status, .qa)
        XCTAssertTrue(reloaded.hidden, "hidden must survive a status change")
    }

    // MARK: - Location-aware filePath routing (Task 2)

    /// A task linked to a live worktree resolves to that worktree's `.clearway/TASK.md`.
    func testFilePathResolvesToWorktreeForLinkedTask() throws {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-alpha")
        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/alpha", path: worktreePath)] }

        let task = WorkTask(id: UUID(), title: "Linked", status: .inProgress, worktree: "feature/alpha")
        let expected = (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
        XCTAssertEqual(manager.filePath(for: task), expected)
    }

    /// A task with no live worktree (backlog, or branch not currently checked out) resolves to
    /// the central `<UUID>.md`.
    func testFilePathResolvesToCentralWhenNoLiveWorktree() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [] }

        let task = WorkTask(id: UUID(), title: "Backlog", status: .new, worktree: nil)
        let expected = ((tempRoot as NSString).appendingPathComponent(".clearway/tasks") as NSString)
            .appendingPathComponent("\(task.id.uuidString).md")
        XCTAssertEqual(manager.filePath(for: task), expected)
    }

    /// `updateTask` writes a worktree-linked task into the worktree's `TASK.md`, not the central dir.
    func testWriteLandsInWorktreeForLinkedTask() throws {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-beta")
        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/beta", path: worktreePath)] }

        let task = WorkTask(id: UUID(), title: "In worktree", status: .inProgress, worktree: "feature/beta")
        manager.updateTask(task)

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

        let worktreeTask = WorkTask(id: UUID(), title: "Active item", status: .inProgress, worktree: "feature/active")
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
        let central = WorkTask(id: sharedId, title: "Stale central", status: .new, worktree: "feature/dup")
        let centralDir = (tempRoot as NSString).appendingPathComponent(".clearway/tasks")
        try FileManager.default.createDirectory(atPath: centralDir, withIntermediateDirectories: true)
        try central.serialized().write(
            toFile: (centralDir as NSString).appendingPathComponent("\(sharedId.uuidString).md"),
            atomically: true, encoding: .utf8
        )

        // Fresh worktree copy with the same id.
        let worktreeTask = WorkTask(id: sharedId, title: "Fresh worktree", status: .inProgress, worktree: "feature/dup")
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
        let worktreeTask = WorkTask(id: UUID(), title: "Surfaced", status: .inProgress, worktree: "feature/surf")
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
        let worktreeTask = WorkTask(id: id, title: "Stable", status: .inProgress, worktree: "feature/stable")
        let worktreePath = try seedWorktreeTask(dir: "wt-stable", worktreeTask)

        let manager = WorkTaskManager(projectPath: tempRoot)
        manager.worktreeResolver = { [(branch: "feature/stable", path: worktreePath)] }
        manager.setWatchedWorktrees([worktreePath])
        XCTAssertEqual(manager.task(forWorktree: "feature/stable")?.id, id)

        manager.setWatchedWorktrees([worktreePath])  // reload again
        XCTAssertEqual(manager.task(forWorktree: "feature/stable")?.id, id, "id must be stable across reloads")
    }

    // MARK: - Migration (Task 10)

    /// Writes a task as a central `<UUID>.md` and returns its path.
    @discardableResult
    private func seedCentralTask(_ task: WorkTask) throws -> String {
        let centralDir = (tempRoot as NSString).appendingPathComponent(".clearway/tasks")
        try FileManager.default.createDirectory(atPath: centralDir, withIntermediateDirectories: true)
        let path = (centralDir as NSString).appendingPathComponent("\(task.id.uuidString).md")
        try task.serialized().write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Migration relocates a central task whose worktree is live into that worktree, leaves
    /// backlog tasks central, and trashes legacy done/canceled orphans — converging the central
    /// directory on backlog-only.
    func testMigrationRelocatesActiveTrashesOrphansKeepsBacklog() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)

        // (a) Active central task whose worktree is live → relocate.
        let active = WorkTask(id: UUID(), title: "Active", status: .inProgress, worktree: "feature/live")
        let activePath = try seedCentralTask(active)
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-live")

        // (b) Legacy terminal-status orphan with no live worktree → Trash.
        let orphan = WorkTask(id: UUID(), title: "Old done", status: .done, worktree: "feature/gone")
        let orphanPath = try seedCentralTask(orphan)

        // (c) Backlog task → stays central.
        guard let backlog = manager.createTask(title: "Still backlog") else {
            XCTFail("createTask returned nil"); return
        }
        let backlogPath = manager.filePath(for: backlog)

        manager.worktreeResolver = { [(branch: "feature/live", path: worktreePath)] }
        manager.migrateCentralTasks()

        // (a) relocated
        XCTAssertFalse(FileManager.default.fileExists(atPath: activePath), "active central file must be relocated")
        let taskMd = ((worktreePath as NSString).appendingPathComponent(".clearway") as NSString)
            .appendingPathComponent("TASK.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskMd), "active task must now live in its worktree")
        // (b) trashed (gone from central)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanPath), "terminal-status orphan must be trashed")
        // (c) backlog stays
        XCTAssertTrue(FileManager.default.fileExists(atPath: backlogPath), "backlog task must remain central")
    }

    /// Migration is idempotent — a second run after convergence changes nothing.
    func testMigrationIsIdempotent() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        let orphan = WorkTask(id: UUID(), title: "Canceled", status: .canceled, worktree: nil)
        _ = try seedCentralTask(orphan)
        guard manager.createTask(title: "Backlog") != nil else { XCTFail("createTask returned nil"); return }

        // A loaded worktree set always contains at least main; an empty resolver means "not loaded
        // yet" and migration defers. Use a non-matching live worktree to model "no worktree owns
        // this orphan" realistically.
        manager.worktreeResolver = { [(branch: "main", path: (self.tempRoot as NSString).appendingPathComponent("wt-main"))] }
        manager.migrateCentralTasks()
        let centralDir = (tempRoot as NSString).appendingPathComponent(".clearway/tasks")
        let afterFirst = (try? FileManager.default.contentsOfDirectory(atPath: centralDir))?.filter { $0.hasSuffix(".md") }.sorted()

        manager.migrateCentralTasks()
        let afterSecond = (try? FileManager.default.contentsOfDirectory(atPath: centralDir))?.filter { $0.hasSuffix(".md") }.sorted()

        XCTAssertEqual(afterFirst, afterSecond, "second migration run must be a no-op")
        XCTAssertEqual(afterFirst?.count, 1, "only the backlog task remains central after convergence")
    }

    /// Migration converges a legacy phantom — a central, non-terminal task linked to a branch with
    /// no live worktree — by clearing the stale link so it returns to Planning (central,
    /// `worktree == nil`) instead of lingering forever as an "active" task pointing at a dead
    /// branch. The file stays central and its body is preserved.
    func testMigrationClearsStaleLinkOnActivePhantom() throws {
        let manager = WorkTaskManager(projectPath: tempRoot)
        let phantom = WorkTask(id: UUID(), title: "Phantom active", status: .inProgress, worktree: "feature/dead", body: "keep me")
        let phantomPath = try seedCentralTask(phantom)

        // Live set is loaded (contains main) but nothing owns "feature/dead".
        manager.worktreeResolver = { [(branch: "main", path: (self.tempRoot as NSString).appendingPathComponent("wt-main"))] }
        manager.migrateCentralTasks()

        XCTAssertTrue(FileManager.default.fileExists(atPath: phantomPath), "phantom stays central (same <UUID>.md)")
        let reloaded = manager.tasks.first { $0.id == phantom.id }
        XCTAssertNotNil(reloaded, "phantom must remain in the pool")
        XCTAssertNil(reloaded?.worktree, "stale worktree link must be cleared so the task converges to Planning")
        XCTAssertEqual(reloaded?.body, "keep me", "body must be preserved")
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

        // Once the set loads, the deferred migration runs and trashes the terminal orphan.
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
        // updateTask would now write to the worktree; instead simulate the pre-move central file by
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
