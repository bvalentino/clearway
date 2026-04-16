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

    // MARK: - parseSymbolicRefOutput

    func testParseSymbolicRefOutput_stripsOriginPrefix() {
        XCTAssertEqual(WorktreeManager.parseSymbolicRefOutput("origin/main\n"), "main")
        XCTAssertEqual(WorktreeManager.parseSymbolicRefOutput("origin/master\n"), "master")
        XCTAssertEqual(WorktreeManager.parseSymbolicRefOutput("origin/release/v1\n"), "release/v1")
    }

    func testParseSymbolicRefOutput_returnsNilForEmpty() {
        XCTAssertNil(WorktreeManager.parseSymbolicRefOutput(""))
        XCTAssertNil(WorktreeManager.parseSymbolicRefOutput("   "))
        XCTAssertNil(WorktreeManager.parseSymbolicRefOutput("\n"))
    }

    func testParseSymbolicRefOutput_leavesUnprefixedInput() {
        XCTAssertEqual(WorktreeManager.parseSymbolicRefOutput("main\n"), "main")
    }

    // MARK: - stableDisplayName

    func testStableDisplayName_mainUsesDefaultBranch() {
        let manager = WorktreeManager(projectPath: "/tmp/test-project")
        manager.defaultBranchName = "master"

        let mainWorktree = Worktree(branch: "feature-x", path: "/tmp/main", isMain: true)
        XCTAssertEqual(manager.stableDisplayName(for: mainWorktree), "master")
    }

    func testStableDisplayName_nonMainUsesDisplayName() {
        let manager = WorktreeManager(projectPath: "/tmp/test-project")
        manager.defaultBranchName = "master"

        let nonMainWorktree = Worktree(branch: "feature-x", path: "/tmp/feature-x", isMain: false)
        XCTAssertEqual(manager.stableDisplayName(for: nonMainWorktree), "feature-x")
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
