import XCTest
import GhosttyKit
@testable import Clearway

func makeWorktree(
    branch: String? = "test",
    path: String? = "/tmp/test",
    isMain: Bool = false,
    headStatus: HeadStatus = .attached
) -> Worktree {
    Worktree(
        branch: branch,
        path: path,
        isMain: isMain,
        headStatus: headStatus
    )
}

/// Shared scaffolding for the `WORKFLOW.json` loop-engine harness tests: a scratch project root, the
/// standard implement→test→review workflow fixture, and a coordinator wired surface-free. Subclasses
/// drive the coordinator and assert its observable state. The real Ghostty surface launch is replaced
/// by a no-op `workflowAgentLauncher`, so launches run the engine's bookkeeping without a terminal.
@MainActor
class WorkflowHarnessTestCase: XCTestCase {

    var tempRoot: String!

    /// A non-null placeholder `ghostty_app_t` (`void*`). Never dereferenced: the no-op launcher seam
    /// stands in for the real surface spawn, so `app` is only ever passed around, never touched.
    let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 0x1)!

    override func setUp() {
        super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-workflow-harness-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root = tempRoot {
            try? FileManager.default.removeItem(atPath: root)
        }
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Fixture builders

    static let workflowJSON = """
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

    /// Writes `.clearway/WORKFLOW.json` into the project root.
    func writeWorkflow() throws {
        try writeWorkflowJSON(Self.workflowJSON)
    }

    /// Writes arbitrary `.clearway/WORKFLOW.json` content into the project root.
    func writeWorkflowJSON(_ json: String) throws {
        let clearway = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let path = (clearway as NSString).appendingPathComponent("WORKFLOW.json")
        try json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Writes a worktree `TASK.md` with the given status (and optional autopilot) and returns the
    /// worktree path.
    @discardableResult
    func writeWorktreeTask(
        branch: String,
        status: String,
        autopilot: Bool? = nil,
        title: String = "Task",
        hidden: Bool = false,
        id: UUID = UUID()
    ) throws -> String {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let taskMd = (clearway as NSString).appendingPathComponent("TASK.md")
        var task = WorkTask(id: id, title: title, status: status, worktree: branch)
        task.autopilot = autopilot
        task.hidden = hidden
        try task.serialized().write(toFile: taskMd, atomically: true, encoding: .utf8)
        return worktreePath
    }

    /// Builds a coordinator wired to a manager + worktree manager scoped to `tempRoot`, with one live
    /// worktree on `branch` at `worktreePath`. Installs a no-op launcher so any launch the test drives
    /// stays surface-free; tests that need to observe launches override it with a recorder.
    func makeCoordinator(branch: String, worktreePath: String) -> WorkTaskCoordinator {
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

    /// Temporarily sets Main Terminal on `UserDefaults.standard` (what `resolveAgentCommand` reads)
    /// and restores the prior value. Isolated suites cannot be used here: production resolution
    /// always goes through `.standard`.
    func withMainTerminalCommand(_ command: String?, _ body: () throws -> Void) rethrows {
        let key = SettingsKey.mainTerminalCommand
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let command {
            UserDefaults.standard.set(command, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try body()
    }

    /// The worktree id (its path) the coordinator keys engine state by.
    func worktreeId(branch: String, path: String) -> String {
        Worktree(branch: branch, path: path, isMain: false, headStatus: .attached).id
    }

    /// Advances a worktree parked on `implement` into `test` under `mainTerminal`, and returns the
    /// command the launcher seam received. The workflow JSON must already be written.
    @MainActor
    func capturedLaunchCommand(
        branch: String,
        mainTerminal: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String? {
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        var captured: String?
        withMainTerminalCommand(mainTerminal) {
            coordinator.workflowAgentLauncher = { _, command, _, _ in captured = command }
            XCTAssertEqual(coordinator.advanceWorkflow(forBranch: branch, app: dummyApp),
                           .launched(slug: "test"), file: file, line: line)
        }
        return captured
    }

    /// Runs `slug` in a new terminal under `mainTerminal`, and returns the command stamped onto the
    /// launcher tab. The workflow JSON must already be written.
    @MainActor
    func stampedLauncherCommand(branch: String, slug: String, mainTerminal: String) throws -> String? {
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.appProvider = { [dummyApp] in dummyApp }

        var stamped: String?
        coordinator.launcherTabAppender = { _, command in stamped = command }

        withMainTerminalCommand(mainTerminal) {
            coordinator.runWorkflowAction(forBranch: branch, slug: slug, inNewTerminal: true)
        }
        return stamped
    }
}
