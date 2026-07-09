import XCTest
import GhosttyKit
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
        let task = WorkTask(id: id, title: "Active", status: WorkTask.ReservedStatus.inProgress, worktree: "feature/gone")
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

    // MARK: - Raw workflow definition cache (planning)

    /// Writes `.clearway/WORKFLOW.json` with the given JSON and returns a coordinator scoped to it.
    private func makeCoordinator(workflowJSON: String) throws -> WorkTaskCoordinator {
        let clearway = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let path = (clearway as NSString).appendingPathComponent("WORKFLOW.json")
        try workflowJSON.write(toFile: path, atomically: true, encoding: .utf8)

        return WorkTaskCoordinator(
            workTaskManager: WorkTaskManager(projectPath: tempRoot),
            terminalManager: TerminalManager(),
            worktreeManager: WorktreeManager(projectPath: tempRoot)
        )
    }

    /// A planning-only file decodes into the raw cache but fails validation, so the validated cache
    /// and the JSON-workflow gate both stay off — planning works without enabling autopilot.
    func testRawCacheHoldsPlanningWithoutEnablingGate() throws {
        let coordinator = try makeCoordinator(workflowJSON: """
        { "planning": { "instructions": "Plan it." } }
        """)

        XCTAssertFalse(coordinator.isWorkflowJSONProject, "a planning-only file keeps the JSON gate off")
        XCTAssertNil(coordinator.workflowDefinition, "the validated cache stays nil for a planning-only file")
        XCTAssertEqual(coordinator.rawWorkflowDefinition?.planning?.instructions, "Plan it.",
                       "the raw cache exposes the planning instructions")
    }

    /// A valid workflow populates both caches and enables the gate.
    func testRawAndValidatedCacheBothPresentForRealWorkflow() throws {
        let coordinator = try makeCoordinator(workflowJSON: """
        {
          "version": 1,
          "start": "implement",
          "actions": { "implement": { "name": "Implement", "instructions": "Do it." } }
        }
        """)

        XCTAssertTrue(coordinator.isWorkflowJSONProject)
        XCTAssertNotNil(coordinator.workflowDefinition, "a valid workflow populates the validated cache")
        XCTAssertNotNil(coordinator.rawWorkflowDefinition, "a valid workflow also populates the raw cache")
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
            $0.status = WorkTask.ReservedStatus.readyToStart
        }

        // Plan agent rewrote the central file.
        var planned = seed
        planned.title = "Post-plan title"
        planned.body = "Full planned brief."
        planned.status = WorkTask.ReservedStatus.readyToStart
        try planned.serialized().write(
            toFile: taskManager.filePath(for: seed),
            atomically: true,
            encoding: .utf8
        )
        taskManager.reloadFromDisk()

        let worktreeManager = WorktreeManager(projectPath: tempRoot)
        let coordinator = WorkTaskCoordinator(
            workTaskManager: taskManager,
            terminalManager: TerminalManager(),
            worktreeManager: worktreeManager
        )

        // Stale pre-plan snapshot as the UI might still hold.
        var staleSnapshot = seed
        staleSnapshot.title = "Pre-plan draft"
        staleSnapshot.body = "Short draft"
        staleSnapshot.status = WorkTask.ReservedStatus.readyToStart

        // ghostty_app_t is unused on the create path; never dereferenced.
        let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 0x1)!
        let result = coordinator.startTask(staleSnapshot, app: dummyApp)
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
        XCTAssertEqual(reparsed?.status, WorkTask.ReservedStatus.readyToStart)

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
