import XCTest
import GhosttyKit
@testable import Clearway

/// Tests for auto-mode dispatch. These exercise `handleTasksPublish` / `tryAutoDispatch`
/// through the publicly observable surface: setting `autoDispatchHook` and mutating the
/// task via `WorkTaskManager.updateTask`, which fires the `@Published` diff.
@MainActor
final class WorkTaskCoordinatorTests: XCTestCase {

    private var tempRoot: String!
    private var workTaskManager: WorkTaskManager!
    private var terminalManager: TerminalManager!
    private var worktreeManager: WorktreeManager!
    private var coordinator: WorkTaskCoordinator!

    override func setUp() {
        super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-auto-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        workTaskManager = WorkTaskManager(projectPath: tempRoot)
        terminalManager = TerminalManager()
        // WorktreeManager shells out to `git worktree list`; for these tests we bypass
        // refresh entirely by writing the in-memory `worktrees` array directly.
        worktreeManager = WorktreeManager(projectPath: tempRoot)
        worktreeManager.worktrees = []
        coordinator = WorkTaskCoordinator(
            workTaskManager: workTaskManager,
            terminalManager: terminalManager,
            worktreeManager: worktreeManager
        )
    }

    override func tearDown() {
        coordinator = nil
        worktreeManager = nil
        terminalManager = nil
        workTaskManager = nil
        if let root = tempRoot {
            try? FileManager.default.removeItem(atPath: root)
        }
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Install a trusted WORKFLOW.md with an explicit `state_commands.qa` so auto
    /// dispatch has something to fire on.
    private func installTrustedWorkflow() -> WorkflowConfig {
        let content = """
        ---
        state_commands:
          qa: run tests for {{ task.worktree }}
          in_progress: work on {{ task.worktree }}
        ---
        """
        let path = (tempRoot as NSString).appendingPathComponent("WORKFLOW.md")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        guard let config = WorkflowConfig.load(projectPath: tempRoot) else {
            XCTFail("WorkflowConfig.load returned nil")
            return WorkflowConfig(promptTemplate: "")
        }
        config.markTrusted(forProject: tempRoot)
        coordinator.startWatching()
        return config
    }

    private func registerWorktree(branch: String) -> Worktree {
        let worktreePath = (tempRoot as NSString).appendingPathComponent(".worktrees/\(branch)")
        try? FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)
        let wt = Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached)
        worktreeManager.worktrees.append(wt)
        return wt
    }

    /// Seeds `tasks` directly so the `@Published` publish fires and subsequent
    /// `updateTask` calls can diff — `updateTask` alone won't append a brand-new task.
    @discardableResult
    private func createTask(branch: String,
                            auto: Bool = true,
                            status: WorkTask.Status = .inProgress) -> WorkTask {
        var task = WorkTask(title: "T", status: status, worktree: branch)
        task.auto = auto
        task.hidden = false
        workTaskManager.tasks.append(task)
        return task
    }

    // MARK: - Dispatch conditions

    /// Qualifying transition: task.auto == true, trusted WORKFLOW.md, explicit command,
    /// worktree present → exactly one dispatch.
    func test_autoDispatch_firesOnceOnQualifyingTransition() {
        _ = installTrustedWorkflow()
        _ = registerWorktree(branch: "feature/a")
        let task = createTask(branch: "feature/a")

        var calls: [(Worktree, String, String)] = []
        coordinator.autoDispatchHook = { wt, cmd, prompt in calls.append((wt, cmd, prompt)) }

        var moved = task
        moved.status = .qa
        workTaskManager.updateTask(moved)

        XCTAssertEqual(calls.count, 1, "qualifying transition must dispatch exactly once")
        XCTAssertEqual(calls.first?.0.branch, "feature/a")
        XCTAssertEqual(calls.first?.2, "run tests for feature/a",
                       "the explicit command must be template-interpolated before dispatch")
    }

    /// task.auto == false → no dispatch.
    func test_autoDispatch_skipsWhenAutoFalse() {
        _ = installTrustedWorkflow()
        _ = registerWorktree(branch: "feature/b")

        let task = createTask(branch: "feature/b", auto: false)

        var calls = 0
        coordinator.autoDispatchHook = { _, _, _ in calls += 1 }

        var moved = task
        moved.status = .qa
        workTaskManager.updateTask(moved)

        XCTAssertEqual(calls, 0, "auto == false must never dispatch")
    }

    /// Explicit command missing for the target status → no dispatch, even when auto == true
    /// and WORKFLOW.md has other explicit commands.
    func test_autoDispatch_skipsWhenNoExplicitCommandForStatus() {
        _ = installTrustedWorkflow()
        _ = registerWorktree(branch: "feature/c")
        let task = createTask(branch: "feature/c")

        var calls = 0
        coordinator.autoDispatchHook = { _, _, _ in calls += 1 }

        var moved = task
        moved.status = .done  // WORKFLOW.md above has no state_commands.done
        workTaskManager.updateTask(moved)

        XCTAssertEqual(calls, 0, "no explicit command for .done → no dispatch")
    }

    /// Untrusted WORKFLOW.md → no dispatch, even though the command exists.
    func test_autoDispatch_skipsWhenConfigUntrusted() {
        let content = """
        ---
        state_commands:
          qa: "run tests"
        ---
        """
        let path = (tempRoot as NSString).appendingPathComponent("WORKFLOW.md")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        coordinator.startWatching()
        // Deliberately do NOT call markTrusted.

        _ = registerWorktree(branch: "feature/d")
        let task = createTask(branch: "feature/d")

        var calls = 0
        coordinator.autoDispatchHook = { _, _, _ in calls += 1 }

        var moved = task
        moved.status = .qa
        workTaskManager.updateTask(moved)

        XCTAssertEqual(calls, 0, "untrusted config must never dispatch silently")
    }

    /// Task has no worktree in the WorktreeManager → no dispatch (would target nothing).
    func test_autoDispatch_skipsWhenWorktreeMissing() {
        _ = installTrustedWorkflow()
        // No registerWorktree call.
        let task = createTask(branch: "feature/missing")

        var calls = 0
        coordinator.autoDispatchHook = { _, _, _ in calls += 1 }

        var moved = task
        moved.status = .qa
        workTaskManager.updateTask(moved)

        XCTAssertEqual(calls, 0, "absent worktree must never dispatch")
    }

    /// Only-promptTemplate fallback: `.inProgress` has no explicit frontmatter entry
    /// so auto dispatch stays silent even though `hasStateCommand(.inProgress)` is true.
    func test_autoDispatch_ignoresPromptTemplateFallback() {
        let content = """
        ---
        ---
        Work on {{ task.title }}
        """
        let path = (tempRoot as NSString).appendingPathComponent("WORKFLOW.md")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        guard let cfg = WorkflowConfig.load(projectPath: tempRoot) else {
            XCTFail("workflow load failed")
            return
        }
        cfg.markTrusted(forProject: tempRoot)
        coordinator.startWatching()
        _ = registerWorktree(branch: "feature/e")

        let task = createTask(branch: "feature/e", auto: true, status: .readyToStart)

        var calls = 0
        coordinator.autoDispatchHook = { _, _, _ in calls += 1 }

        var moved = task
        moved.status = .inProgress
        workTaskManager.updateTask(moved)

        XCTAssertEqual(calls, 0, "body-only fallback must not trigger auto dispatch")
    }

    // MARK: - Transition cadence

    /// With no external suppression, each qualifying transition dispatches. The
    /// `suppressNextAutoDispatch` set is only populated by `startTask`/`continueTask`
    /// (which need `ghostty_app_t` and aren't reachable here); the unit assertion is
    /// that absent that seed, sequential transitions each fire.
    func test_autoDispatch_firesOnEverySubsequentTransition() {
        _ = installTrustedWorkflow()
        _ = registerWorktree(branch: "feature/g")
        let task = createTask(branch: "feature/g")

        var calls = 0
        coordinator.autoDispatchHook = { _, _, _ in calls += 1 }

        var qa = task
        qa.status = .qa
        workTaskManager.updateTask(qa)
        XCTAssertEqual(calls, 1, "first qualifying transition dispatches")

        var back = qa
        back.status = .inProgress
        workTaskManager.updateTask(back)
        XCTAssertEqual(calls, 2, "second qualifying transition dispatches")
    }

    // MARK: - startTask suppression

    /// `startTask` inserts the task into `suppressNextAutoDispatch` before calling
    /// `updateTask` so the resulting `.readyToStart → .inProgress` publish is
    /// swallowed by auto mode — otherwise auto would pile a second agent tab on
    /// top of the one `launchClaudeCode` already opened. We exercise this via the
    /// `.beforeRunHook` return path (hook present in WORKFLOW.md) which captures
    /// the `ghostty_app_t` in a closure but never dereferences it, so a fake
    /// pointer is safe.
    func test_autoDispatch_startTaskSuppressesInitialInProgressTransition() {
        let content = """
        ---
        hooks:
          before_run: "echo before"
        state_commands:
          in_progress: "run for {{ task.worktree }}"
        ---
        """
        let path = (tempRoot as NSString).appendingPathComponent("WORKFLOW.md")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        guard let cfg = WorkflowConfig.load(projectPath: tempRoot) else {
            XCTFail("workflow load failed")
            return
        }
        cfg.markTrusted(forProject: tempRoot)
        coordinator.startWatching()
        _ = registerWorktree(branch: "feature/start")

        let task = createTask(branch: "feature/start", auto: true, status: .readyToStart)

        var calls = 0
        coordinator.autoDispatchHook = { _, _, _ in calls += 1 }

        // Fake, never-dereferenced app pointer — the `.beforeRunHook` path only
        // stores it in an un-invoked closure.
        let fakeApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 0x1)!
        let result = coordinator.startTask(task, app: fakeApp)

        guard case .beforeRunHook = result else {
            XCTFail("expected .beforeRunHook return path, got \(result)")
            return
        }
        XCTAssertEqual(calls, 0,
            "startTask-induced .readyToStart → .inProgress transition must be suppressed")
    }

    // MARK: - setAutoEnabled

    /// Disabling auto never requires trust, persists immediately — even when the
    /// WORKFLOW.md is present but un-trusted (which would block a set-to-true).
    func test_setAutoEnabled_disablingPersistsWithoutTrust() {
        let content = """
        ---
        state_commands:
          qa: "x"
        ---
        """
        let path = (tempRoot as NSString).appendingPathComponent("WORKFLOW.md")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        coordinator.startWatching()
        // Deliberately do NOT markTrusted — the config is present but un-trusted.

        let task = createTask(branch: "feature/h")

        let result = coordinator.setAutoEnabled(false, for: task)
        switch result {
        case .set:
            let reloaded = workTaskManager.tasks.first(where: { $0.id == task.id })
            XCTAssertEqual(reloaded?.auto, false)
        case .needsTrust:
            XCTFail("disabling must never require trust")
        }
    }

    /// Enabling on an untrusted config returns `.needsTrust` without persisting.
    func test_setAutoEnabled_enablingOnUntrustedReturnsNeedsTrust() {
        let content = """
        ---
        state_commands:
          qa: "x"
        ---
        """
        let path = (tempRoot as NSString).appendingPathComponent("WORKFLOW.md")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        coordinator.startWatching()
        // Deliberately do NOT markTrusted.

        _ = registerWorktree(branch: "feature/i")
        let task = createTask(branch: "feature/i", auto: false)

        let result = coordinator.setAutoEnabled(true, for: task)
        switch result {
        case .needsTrust:
            let reloaded = workTaskManager.tasks.first(where: { $0.id == task.id })
            XCTAssertEqual(reloaded?.auto, false, "untrusted enable must not persist")
        case .set:
            XCTFail("enabling on untrusted must return .needsTrust")
        }
    }

    /// Enabling on a trusted config persists immediately.
    func test_setAutoEnabled_enablingOnTrustedPersists() {
        _ = installTrustedWorkflow()
        _ = registerWorktree(branch: "feature/j")

        let task = createTask(branch: "feature/j", auto: false)

        let result = coordinator.setAutoEnabled(true, for: task)
        switch result {
        case .set:
            let reloaded = workTaskManager.tasks.first(where: { $0.id == task.id })
            XCTAssertEqual(reloaded?.auto, true)
        case .needsTrust:
            XCTFail("enabling on trusted must persist")
        }
    }
}
