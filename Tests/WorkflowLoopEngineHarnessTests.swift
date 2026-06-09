import CryptoKit
import XCTest
import GhosttyKit
@testable import Clearway

/// Harness tests for the stateful `WorkTaskCoordinator` side of the `WORKFLOW.json` loop engine:
/// the `start` seed, trust gating, and the watcher-driven advance/halt decisions.
///
/// These exercise everything *except* the actual Ghostty surface launch, which needs a live
/// `ghostty_app_t`. To stay surface-free the fixture workflow is left **untrusted**, so a `.launch`
/// decision short-circuits to `.needsTrust` *before* any surface is created — letting us assert the
/// engine reached a launch decision (legal advance, terminal end) without spawning a terminal. The
/// pure routing/validation logic itself is covered exhaustively in `WorkflowLoopEngineTests`.
@MainActor
final class WorkflowLoopEngineHarnessTests: XCTestCase {

    private var tempRoot: String!

    /// A non-null placeholder `ghostty_app_t` (`void*`). Never dereferenced: every assertion here
    /// drives a path that returns before `launchWorkflowAgent` would touch it.
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 0x1)!

    override func setUp() {
        super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-loop-harness-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root = tempRoot {
            // Clear any trust approval this test minted so runs stay independent.
            UserDefaults.standard.removeObject(forKey: trustDefaultsKey(forProject: root))
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

    /// Writes `.clearway/WORKFLOW.json` into the project root.
    private func writeWorkflow() throws {
        let clearway = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let path = (clearway as NSString).appendingPathComponent("WORKFLOW.json")
        try Self.workflowJSON.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Writes a worktree `TASK.md` with the given status and returns the worktree path.
    @discardableResult
    private func writeWorktreeTask(branch: String, status: String, id: UUID = UUID()) throws -> String {
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearway, withIntermediateDirectories: true)
        let taskMd = (clearway as NSString).appendingPathComponent("TASK.md")
        let task = WorkTask(id: id, title: "Task", status: status, worktree: branch)
        try task.serialized().write(toFile: taskMd, atomically: true, encoding: .utf8)
        return worktreePath
    }

    /// Builds a coordinator wired to a manager + worktree manager scoped to `tempRoot`, with one
    /// live worktree on `branch` at `worktreePath`.
    private func makeCoordinator(branch: String, worktreePath: String) -> WorkTaskCoordinator {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }
        taskManager.setWatchedWorktrees([worktreePath])

        let worktreeManager = WorktreeManager(projectPath: tempRoot)
        worktreeManager.worktrees = [
            Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached),
        ]
        return WorkTaskCoordinator(
            workTaskManager: taskManager,
            terminalManager: TerminalManager(),
            worktreeManager: worktreeManager
        )
    }

    /// Mirrors `WorkflowDefinition`'s private trust key so the test can clear it in `tearDown`.
    private func trustDefaultsKey(forProject projectPath: String) -> String {
        let hash = SHA256Hex(projectPath)
        return "clearway.workflow.json.trusted.\(hash)"
    }

    // MARK: - Seed

    func testSeedWritesStartStatus() throws {
        try writeWorkflow()
        let branch = "seed"
        let worktreePath = try writeWorktreeTask(branch: branch, status: WorkTask.ReservedStatus.inProgress)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.seedWorkflowStatus(forBranch: branch)

        let task = coordinator.workTaskManager.task(forWorktree: branch)
        XCTAssertEqual(task?.status, "implement", "seed writes the workflow's start slug")
    }

    func testSeedIsNoOpWithoutJSONWorkflow() throws {
        // No WORKFLOW.json written — legacy project, seed must not touch status.
        let branch = "legacy"
        let worktreePath = try writeWorktreeTask(branch: branch, status: WorkTask.ReservedStatus.inProgress)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.seedWorkflowStatus(forBranch: branch)

        XCTAssertEqual(coordinator.workTaskManager.task(forWorktree: branch)?.status,
                       WorkTask.ReservedStatus.inProgress,
                       "a project without WORKFLOW.json is untouched by the seed")
    }

    // MARK: - Trust gating

    func testUntrustedWorkflowDoesNotLaunch() throws {
        try writeWorkflow()
        let branch = "trust"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .needsTrust,
                       "executable WORKFLOW.json must not run until approved — it surfaces instead")
    }

    func testTrustGateClearsAfterApproval() throws {
        try writeWorkflow()
        let branch = "trust2"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        coordinator.approveJSONWorkflowTrust()
        // Now a legal launch decision would proceed to a real surface, which the harness can't
        // create — so we only assert the gate itself flipped, via the model API.
        XCTAssertTrue(WorkflowDefinition.isTrusted(projectPath: tempRoot),
                      "approval marks the current WORKFLOW.json bytes trusted")
    }

    // MARK: - Advance / halt (untrusted → launch short-circuits to needsTrust)

    func testLegalAdvanceReachesLaunchDecision() throws {
        try writeWorkflow()
        let branch = "advance"
        // Running `implement`; agent wrote `test` (a legal route). Untrusted → needsTrust proves the
        // decision was `.launch` (an illegal value would have returned `.halted` regardless of trust).
        let worktreePath = try writeWorktreeTask(branch: branch, status: "test")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .needsTrust, "a legal advance reaches the (trust-gated) launch path")
    }

    func testIllegalValueHalts() throws {
        try writeWorkflow()
        let branch = "illegal"
        // Running `implement`; agent wrote `review` — a real action but not reachable from implement.
        let worktreePath = try writeWorktreeTask(branch: branch, status: "review")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        guard case .halted = result else { return XCTFail("expected halt, got \(result)") }
        XCTAssertNotNil(coordinator.workTaskManager.task(forWorktree: branch)?.errorMessage,
                        "halt surfaces an errorMessage on the task")
    }

    func testUnknownSlugHalts() throws {
        try writeWorkflow()
        let branch = "unknown"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "frobnicate")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        guard case .halted = result else { return XCTFail("expected halt, got \(result)") }
    }

    func testSameStatusAsRunningIsIgnored() throws {
        try writeWorkflow()
        let branch = "idem"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        coordinator.setRunningActionForTesting("implement", branch: branch, worktreePath: worktreePath)

        let result = coordinator.advanceWorkflow(forBranch: branch, app: dummyApp)
        XCTAssertEqual(result, .ignored, "a write equal to the running action is idempotently ignored")
    }
}

/// SHA-256 hex prefix matching `WorkflowDefinition`'s trust-key derivation (test-local helper).
private func SHA256Hex(_ string: String) -> String {
    let digest = SHA256.hash(data: Data(string.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}
