import XCTest
import GhosttyKit
@testable import Clearway

/// Harness tests for the sidebar action cards' coordinator operations — **Set as current** and the
/// two **Run** variants. Each pauses autopilot (manual per-card control and the loop are mutually
/// exclusive) and steers `status` to the picked action. The Ghostty paste delivery needs a live app,
/// so the harness builds a real `TerminalManager` with no app and asserts the observable pool state;
/// paste delivery is left to the manual checklist.
@MainActor
final class WorkflowSidebarActionTests: XCTestCase {

    private var tempRoot: String!

    override func setUp() {
        super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-sidebar-action-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root = tempRoot {
            try? FileManager.default.removeItem(atPath: root)
        }
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Fixture builders

    private static let workflowJSON = """
    {
      "version": 1,
      "start": "implement",
      "actions": {
        "implement": { "name": "Implement", "instructions": "Implement.", "routes": { "success": "test" } },
        "test": { "name": "Test", "instructions": "Test.", "routes": { "success": "review" } },
        "review": { "name": "Review", "instructions": "Review." }
      }
    }
    """

    private func writeWorkflow() throws {
        let clearway = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let path = (clearway as NSString).appendingPathComponent("WORKFLOW.json")
        try Self.workflowJSON.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func writeWorktreeTask(branch: String, status: String, autopilot: Bool? = nil) throws -> String {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let taskMd = (clearway as NSString).appendingPathComponent("TASK.md")
        var task = WorkTask(id: UUID(), title: "Task", status: status, worktree: branch)
        task.autopilot = autopilot
        try task.serialized().write(toFile: taskMd, atomically: true, encoding: .utf8)
        return worktreePath
    }

    private func makeCoordinator(branch: String, worktreePath: String) -> WorkTaskCoordinator {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }
        taskManager.setWatchedWorktrees([worktreePath])

        let worktreeManager = WorktreeManager(projectPath: tempRoot)
        worktreeManager.worktrees = [
            Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached),
        ]
        let coordinator = WorkTaskCoordinator(
            workTaskManager: taskManager,
            terminalManager: TerminalManager(),
            worktreeManager: worktreeManager
        )
        coordinator.workflowAgentLauncher = { _, _, _, _ in }
        return coordinator
    }

    // MARK: - Set as current

    /// **Set as current** moves `status` to the picked action and pauses autopilot.
    func testSetActionCurrentPausesAndSetsStatus() throws {
        try writeWorkflow()
        let branch = "set-current"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else {
            return XCTFail("task missing")
        }

        coordinator.setWorkflowActionCurrent(task, to: "review")

        let updated = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(updated?.status, "review", "set-as-current moves status to the picked action")
        XCTAssertEqual(updated?.autopilot, false, "set-as-current pauses autopilot")
    }

    /// The pause fires even when the picked slug already equals the current status — the status
    /// write is a no-op (`setWorkflowStatus` skips it), but handing control to the user is not.
    func testSetActionCurrentPausesEvenWhenSlugUnchanged() throws {
        try writeWorkflow()
        let branch = "set-current-noop"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        guard let task = coordinator.workTaskManager.task(forWorktree: branch) else {
            return XCTFail("task missing")
        }

        coordinator.setWorkflowActionCurrent(task, to: "implement")

        let updated = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(updated?.status, "implement")
        XCTAssertEqual(updated?.autopilot, false, "a no-op status write still pauses autopilot")
    }

    // MARK: - Run in current / new terminal

    /// **Run in current terminal** sets the picked action as current and pauses autopilot. The
    /// harness has no Ghostty app, so the paste delivery is skipped — we assert the observable pool
    /// state (paste delivery is covered by the manual checklist).
    func testRunActionInCurrentTerminalPausesAndSetsCurrent() throws {
        try writeWorkflow()
        let branch = "run-current"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.runWorkflowAction(forBranch: branch, slug: "test", inNewTerminal: false)

        let updated = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(updated?.status, "test", "running an action sets it as current")
        XCTAssertEqual(updated?.autopilot, false, "running an action pauses autopilot")
    }

    /// **Run in new terminal** likewise sets the picked action as current and pauses autopilot.
    func testRunActionInNewTerminalPausesAndSetsCurrent() throws {
        try writeWorkflow()
        let branch = "run-new"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", autopilot: true)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.runWorkflowAction(forBranch: branch, slug: "review", inNewTerminal: true)

        let updated = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(updated?.status, "review", "running an action in a new terminal sets it as current")
        XCTAssertEqual(updated?.autopilot, false, "running an action pauses autopilot")
    }
}
