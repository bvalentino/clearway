import XCTest
@testable import Clearway

final class TaskEditorBuffersTests: XCTestCase {

    func testAdoptFromPoolReplacesLocalBuffersAndBumpsReloadingCount() {
        let pool = WorkTask(
            id: UUID(),
            title: "From disk",
            status: "work_breakdown",
            body: "Expanded brief"
        )
        var state = TaskEditorBufferState(
            title: "Stale title",
            bodyText: "Stale body",
            editorText: "stale frontmatter",
            frontmatterError: true
        )

        TaskEditorBuffers.adoptFromPool(pool, state: &state, showFrontmatter: true)

        XCTAssertEqual(state.title, "From disk")
        XCTAssertEqual(state.bodyText, "Expanded brief")
        XCTAssertEqual(state.editorText, pool.serialized())
        XCTAssertFalse(state.frontmatterError)
        XCTAssertEqual(state.reloadingCount, 3, "title, body, and frontmatter each suppress one autosave")
    }

    func testAdoptFromPoolSkipsUnchangedBuffers() {
        let pool = WorkTask(id: UUID(), title: "Same", status: "spec", body: "Same body")
        var state = TaskEditorBufferState(
            title: "Same",
            bodyText: "Same body",
            editorText: pool.serialized()
        )

        TaskEditorBuffers.adoptFromPool(pool, state: &state, showFrontmatter: true)

        XCTAssertEqual(state.reloadingCount, 0)
    }

    func testShouldAutosaveConsumesReloadingCount() {
        var reloadingCount = 2
        XCTAssertFalse(TaskEditorBuffers.shouldAutosave(reloadingCount: &reloadingCount))
        XCTAssertEqual(reloadingCount, 1)
        XCTAssertFalse(TaskEditorBuffers.shouldAutosave(reloadingCount: &reloadingCount))
        XCTAssertEqual(reloadingCount, 0)
        XCTAssertTrue(TaskEditorBuffers.shouldAutosave(reloadingCount: &reloadingCount))
    }

    func testIsDirtyBodyMode() {
        let task = WorkTask(id: UUID(), title: "T", status: "new", body: "B")
        let clean = TaskEditorBufferState(title: "T", bodyText: "B")
        let dirty = TaskEditorBufferState(title: "T", bodyText: "edited")
        XCTAssertFalse(TaskEditorBuffers.isDirty(task: task, state: clean, showFrontmatter: false))
        XCTAssertTrue(TaskEditorBuffers.isDirty(task: task, state: dirty, showFrontmatter: false))
    }

    func testLeaveFrontmatterWithInvalidYAMLSetsError() {
        let task = WorkTask(id: UUID(), title: "T", status: "new", body: "B")
        var state = TaskEditorBufferState(
            title: "T",
            bodyText: "B",
            editorText: "---\nbad: [unclosed\n---\nbody"
        )

        let ok = TaskEditorBuffers.setShowFrontmatter(false, task: task, taskId: task.id, state: &state)

        XCTAssertFalse(ok)
        XCTAssertTrue(state.frontmatterError)
        XCTAssertEqual(state.bodyText, "B", "invalid leave must not commit body from the bad buffer")
    }

    @MainActor
    func testSaveBodyModeDoesNotWriteWhileFrontmatterErrorRaised() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-editor-buffers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        let manager = WorkTaskManager(projectPath: root)
        guard let seed = manager.createTask(title: "Original") else {
            XCTFail("createTask returned nil"); return
        }
        manager.updateFields(id: seed.id) { $0.body = "Original body" }

        var state = TaskEditorBufferState(
            title: "Hijacked",
            bodyText: "Should not land",
            frontmatterError: true
        )
        TaskEditorBuffers.save(
            taskId: seed.id,
            existing: manager.tasks.first { $0.id == seed.id }!,
            state: &state,
            showFrontmatter: false,
            manager: manager
        )

        let pool = manager.tasks.first { $0.id == seed.id }
        XCTAssertEqual(pool?.title, "Original")
        XCTAssertEqual(pool?.body, "Original body")
    }

    @MainActor
    func testSaveBodyModeWritesTitleAndBodyViaRebase() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-editor-buffers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        let manager = WorkTaskManager(projectPath: root)
        guard let seed = manager.createTask(title: "Original") else {
            XCTFail("createTask returned nil"); return
        }
        manager.updateFields(id: seed.id) {
            $0.body = "Original body"
            $0.status = "work_breakdown"
        }

        var state = TaskEditorBufferState(title: "Edited title", bodyText: "Edited body")
        TaskEditorBuffers.save(
            taskId: seed.id,
            existing: manager.tasks.first { $0.id == seed.id }!,
            state: &state,
            showFrontmatter: false,
            manager: manager
        )

        let pool = manager.tasks.first { $0.id == seed.id }
        XCTAssertEqual(pool?.title, "Edited title")
        XCTAssertEqual(pool?.body, "Edited body")
        XCTAssertEqual(pool?.status, "work_breakdown", "body save must not clobber status")
    }

    /// Late autosave after an external agent rewrite must not stamp pre-agent title/body onto
    /// the fresher disk document (ghost-clobber). Simulates: pool still holds the pre-agent
    /// snapshot, buffers still hold pre-agent content, disk already has the agent write.
    @MainActor
    func testSaveBodyModeAbortsWhenDiskTitleBodyMovedUnderPendingSave() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-editor-buffers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        let manager = WorkTaskManager(projectPath: root)
        guard let seed = manager.createTask(title: "Pre-plan title") else {
            XCTFail("createTask returned nil"); return
        }
        manager.updateFields(id: seed.id) {
            $0.body = "Pre-plan draft"
            $0.status = "spec"
        }

        let stalePool = try XCTUnwrap(manager.tasks.first { $0.id == seed.id })
        var agent = stalePool
        agent.title = "Planned title"
        agent.body = "Expanded brief from agent"
        agent.status = "work_breakdown"
        try agent.serialized().write(
            toFile: manager.filePath(for: stalePool),
            atomically: true,
            encoding: .utf8
        )

        // Dirty relative to the stale pool (as a pending autosave would be), while disk
        // already holds the agent rewrite — without CAS this would clobber the agent doc.
        var state = TaskEditorBufferState(
            title: "Local buffer title",
            bodyText: "Local buffer body"
        )
        TaskEditorBuffers.save(
            taskId: seed.id,
            existing: stalePool,
            state: &state,
            showFrontmatter: false,
            manager: manager
        )

        let onDisk = try XCTUnwrap(manager.freshTask(id: seed.id))
        XCTAssertEqual(onDisk.title, "Planned title")
        XCTAssertEqual(onDisk.body, "Expanded brief from agent")
        XCTAssertEqual(onDisk.status, "work_breakdown")
        XCTAssertEqual(state.title, "Planned title", "buffers adopt disk on CAS abort")
        XCTAssertEqual(state.bodyText, "Expanded brief from agent")
        XCTAssertGreaterThan(state.reloadingCount, 0, "adopt must suppress follow-on autosave")
    }

    /// Status-only disk advance must not block a legitimate title/body save (CAS keys only
    /// on editor-owned fields).
    @MainActor
    func testSaveBodyModeAllowsWriteWhenOnlyStatusMovedOnDisk() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-editor-buffers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        let manager = WorkTaskManager(projectPath: root)
        guard let seed = manager.createTask(title: "Title") else {
            XCTFail("createTask returned nil"); return
        }
        manager.updateFields(id: seed.id) {
            $0.body = "Body"
            $0.status = "spec"
        }

        let poolBase = try XCTUnwrap(manager.tasks.first { $0.id == seed.id })
        var advanced = poolBase
        advanced.status = "work_breakdown"
        try advanced.serialized().write(
            toFile: manager.filePath(for: poolBase),
            atomically: true,
            encoding: .utf8
        )

        var state = TaskEditorBufferState(title: "User title", bodyText: "User body")
        TaskEditorBuffers.save(
            taskId: seed.id,
            existing: poolBase,
            state: &state,
            showFrontmatter: false,
            manager: manager
        )

        let onDisk = try XCTUnwrap(manager.freshTask(id: seed.id))
        XCTAssertEqual(onDisk.title, "User title")
        XCTAssertEqual(onDisk.body, "User body")
        XCTAssertEqual(onDisk.status, "work_breakdown", "status from disk must survive body save")
    }

    @MainActor
    func testSaveFrontmatterModeAbortsWhenDiskTitleBodyMovedUnderPendingSave() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-editor-buffers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        let manager = WorkTaskManager(projectPath: root)
        guard let seed = manager.createTask(title: "Pre-plan title") else {
            XCTFail("createTask returned nil"); return
        }
        manager.updateFields(id: seed.id) {
            $0.body = "Pre-plan draft"
            $0.status = "spec"
        }

        let stalePool = try XCTUnwrap(manager.tasks.first { $0.id == seed.id })
        var agent = stalePool
        agent.title = "Planned title"
        agent.body = "Expanded brief from agent"
        agent.status = "work_breakdown"
        try agent.serialized().write(
            toFile: manager.filePath(for: stalePool),
            atomically: true,
            encoding: .utf8
        )

        var staleBuffer = stalePool
        staleBuffer.title = "Stale buffer title"
        staleBuffer.body = "Stale buffer body"
        var state = TaskEditorBufferState(
            title: staleBuffer.title,
            bodyText: staleBuffer.body,
            editorText: staleBuffer.serialized()
        )
        TaskEditorBuffers.save(
            taskId: seed.id,
            existing: stalePool,
            state: &state,
            showFrontmatter: true,
            manager: manager
        )

        let onDisk = try XCTUnwrap(manager.freshTask(id: seed.id))
        XCTAssertEqual(onDisk.title, "Planned title")
        XCTAssertEqual(onDisk.body, "Expanded brief from agent")
        XCTAssertEqual(onDisk.status, "work_breakdown")
        XCTAssertEqual(state.editorText, agent.serialized())
    }
}
