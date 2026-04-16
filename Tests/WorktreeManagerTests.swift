import XCTest
@testable import Clearway

@MainActor
final class ProjectListManagerTests: XCTestCase {

    private let suiteName = "app.getclearway.mac.tests"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Project Management

    func testAddProject() {
        let manager = ProjectListManager(defaults: testDefaults)
        manager.addProject("/tmp/project-a")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-a"])
        XCTAssertEqual(manager.lastActiveProjectPath, "/tmp/project-a")
    }

    func testAddMultipleProjects() {
        let manager = ProjectListManager(defaults: testDefaults)
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-b")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-a", "/tmp/project-b"])
        XCTAssertEqual(manager.lastActiveProjectPath, "/tmp/project-b")
    }

    func testAddDuplicateProjectIsNoop() {
        let manager = ProjectListManager(defaults: testDefaults)
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-a")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-a"])
    }

    func testRemoveProject() {
        let manager = ProjectListManager(defaults: testDefaults)
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-b")
        manager.removeProject("/tmp/project-a")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-b"])
    }

    func testRemoveActiveProjectSwitchesToFirst() {
        let manager = ProjectListManager(defaults: testDefaults)
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-b")

        XCTAssertEqual(manager.lastActiveProjectPath, "/tmp/project-b")

        manager.removeProject("/tmp/project-b")
        XCTAssertEqual(manager.lastActiveProjectPath, "/tmp/project-a")
    }

    func testRemoveLastProjectClearsActive() {
        let manager = ProjectListManager(defaults: testDefaults)
        manager.addProject("/tmp/project-a")
        manager.removeProject("/tmp/project-a")

        XCTAssertTrue(manager.projectPaths.isEmpty)
        XCTAssertNil(manager.lastActiveProjectPath)
    }

    func testPersistence() {
        let manager = ProjectListManager(defaults: testDefaults)
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-b")

        let restored = ProjectListManager(defaults: testDefaults)
        XCTAssertEqual(restored.projectPaths, ["/tmp/project-a", "/tmp/project-b"])
        XCTAssertEqual(restored.lastActiveProjectPath, "/tmp/project-b")
    }

    func testMigrationFromSingleProjectPath() {
        testDefaults.set("/tmp/legacy-project", forKey: "clearway.projectPath")

        let manager = ProjectListManager(defaults: testDefaults)

        XCTAssertEqual(manager.projectPaths, ["/tmp/legacy-project"])
        XCTAssertEqual(manager.lastActiveProjectPath, "/tmp/legacy-project")
        XCTAssertNil(testDefaults.string(forKey: "clearway.projectPath"))
    }

    func testEmptyInitialState() {
        let manager = ProjectListManager(defaults: testDefaults)

        XCTAssertTrue(manager.projectPaths.isEmpty)
        XCTAssertNil(manager.lastActiveProjectPath)
    }
}

@MainActor
final class WorktreeManagerTests: XCTestCase {

    func testInitWithProjectPath() {
        let manager = WorktreeManager(projectPath: "/tmp/test-project")

        XCTAssertEqual(manager.projectPath, "/tmp/test-project")
        XCTAssertNil(manager.error)
    }

    // MARK: - Background Refresh Removal

    func testNoBackgroundRefreshProperties() {
        // After removing background PR refresh, WorktreeManager must not have
        // backgroundRefreshTask or any background-refresh-related stored properties.
        let manager = WorktreeManager(projectPath: "/tmp/test-project")
        let mirror = Mirror(reflecting: manager)
        let propertyNames = mirror.children.compactMap(\.label)

        let removedNames = ["backgroundRefreshTask"]
        for name in removedNames {
            XCTAssertFalse(
                propertyNames.contains(name),
                "\(name) property should be removed from WorktreeManager"
            )
        }
    }

    // MARK: - PR Status (preserved behavior)

    func testPrunePRStatusesRemovesStaleEntries() {
        let manager = WorktreeManager(projectPath: "/tmp/test-project")
        manager.worktreePRStates["wt-a"] = .result(PRStatus(number: 1, title: "PR A", url: "https://example.com/1"))
        manager.worktreePRStates["wt-b"] = .result(PRStatus(number: 2, title: "PR B", url: "https://example.com/2"))
        manager.worktreePRStates["wt-c"] = .loading

        manager.prunePRStatuses(keeping: ["wt-a"])

        XCTAssertNotNil(manager.worktreePRStates["wt-a"])
        XCTAssertNil(manager.worktreePRStates["wt-b"])
        XCTAssertNil(manager.worktreePRStates["wt-c"])
    }

    func testPrunePRStatusesKeepsAllWhenAllValid() {
        let manager = WorktreeManager(projectPath: "/tmp/test-project")
        manager.worktreePRStates["wt-a"] = .loading
        manager.worktreePRStates["wt-b"] = .result(nil)

        manager.prunePRStatuses(keeping: ["wt-a", "wt-b"])

        XCTAssertEqual(manager.worktreePRStates.count, 2)
    }

    func testCheckPRSkipsUnknownWorktree() {
        let manager = WorktreeManager(projectPath: "/tmp/test-project")
        // No worktrees loaded — checkPR should be a no-op.
        manager.checkPR(for: "nonexistent")

        XCTAssertTrue(manager.worktreePRStates.isEmpty)
    }

    func testCheckPRSkipsWhenAlreadyLoading() {
        let manager = WorktreeManager(projectPath: "/tmp/test-project")
        let wt = Worktree(branch: "feature", path: "/tmp/feature", isMain: false)
        manager.worktrees = [wt]
        manager.worktreePRStates[wt.id] = .loading

        // Should not reset or double-load.
        manager.checkPR(for: wt.id)

        XCTAssertEqual(manager.worktreePRStates[wt.id], .loading)
    }

    func testCheckPRSetsLoadingForKnownWorktree() {
        let manager = WorktreeManager(projectPath: "/tmp/test-project")
        let wt = Worktree(branch: "feature", path: "/tmp/feature", isMain: false)
        manager.worktrees = [wt]

        manager.checkPR(for: wt.id)

        XCTAssertEqual(manager.worktreePRStates[wt.id], .loading)
    }

    func testCheckPRSkipsDetachedWorktree() {
        let manager = WorktreeManager(projectPath: "/tmp/test-project")
        let wt = Worktree(branch: nil, path: "/tmp/detached", isMain: false)
        manager.worktrees = [wt]

        manager.checkPR(for: wt.id)

        // Detached worktrees have no branch — checkPR guard should reject.
        XCTAssertNil(manager.worktreePRStates[wt.id])
    }

}

// MARK: - WorktreeError Tests

final class WorktreeErrorTests: XCTestCase {

    func testStderrShownDirectly() {
        let stderr = "fatal: not a git repository (or any of the parent directories): .git"
        let error = WorktreeManager.WorktreeError.commandFailed("git worktree list", stderr: stderr)

        XCTAssertEqual(error.errorDescription, stderr)
    }

    func testEmptyStderrFallsBackToGeneric() {
        let error = WorktreeManager.WorktreeError.commandFailed("git worktree list", stderr: "")
        let message = error.errorDescription ?? ""

        XCTAssertEqual(message, "Command failed: git worktree list")
    }

}
