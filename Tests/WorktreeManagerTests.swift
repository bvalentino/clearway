import XCTest
@testable import wtpad

@MainActor
final class ProjectListManagerTests: XCTestCase {

    private let suiteName = "com.wtpad.mac.tests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? suiteName)
        UserDefaults.standard.removeObject(forKey: "wtpad.projectPaths")
        UserDefaults.standard.removeObject(forKey: "wtpad.activeProjectPath")
        UserDefaults.standard.removeObject(forKey: "wtpad.projectPath")
    }

    // MARK: - Project Management

    func testAddProject() {
        let manager = ProjectListManager()
        manager.addProject("/tmp/project-a")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-a"])
        XCTAssertEqual(manager.lastActiveProjectPath, "/tmp/project-a")
    }

    func testAddMultipleProjects() {
        let manager = ProjectListManager()
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-b")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-a", "/tmp/project-b"])
        XCTAssertEqual(manager.lastActiveProjectPath, "/tmp/project-b")
    }

    func testAddDuplicateProjectIsNoop() {
        let manager = ProjectListManager()
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-a")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-a"])
    }

    func testRemoveProject() {
        let manager = ProjectListManager()
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-b")
        manager.removeProject("/tmp/project-a")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-b"])
    }

    func testRemoveActiveProjectSwitchesToFirst() {
        let manager = ProjectListManager()
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-b")

        XCTAssertEqual(manager.lastActiveProjectPath, "/tmp/project-b")

        manager.removeProject("/tmp/project-b")
        XCTAssertEqual(manager.lastActiveProjectPath, "/tmp/project-a")
    }

    func testRemoveLastProjectClearsActive() {
        let manager = ProjectListManager()
        manager.addProject("/tmp/project-a")
        manager.removeProject("/tmp/project-a")

        XCTAssertTrue(manager.projectPaths.isEmpty)
        XCTAssertNil(manager.lastActiveProjectPath)
    }

    func testPersistence() {
        let manager = ProjectListManager()
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-b")

        let paths = UserDefaults.standard.stringArray(forKey: "wtpad.projectPaths")
        let active = UserDefaults.standard.string(forKey: "wtpad.activeProjectPath")

        XCTAssertEqual(paths, ["/tmp/project-a", "/tmp/project-b"])
        XCTAssertEqual(active, "/tmp/project-b")
    }

    func testMigrationFromSingleProjectPath() {
        UserDefaults.standard.set("/tmp/legacy-project", forKey: "wtpad.projectPath")

        let manager = ProjectListManager()

        XCTAssertEqual(manager.projectPaths, ["/tmp/legacy-project"])
        XCTAssertEqual(manager.lastActiveProjectPath, "/tmp/legacy-project")
        XCTAssertNil(UserDefaults.standard.string(forKey: "wtpad.projectPath"))
    }

    func testEmptyInitialState() {
        let manager = ProjectListManager()

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

    // MARK: - Subtitle

    func testSubtitleReturnsTitleWhenAvailable() {
        let manager = WorktreeManager(projectPath: "/tmp/test")
        manager.worktreeTitles["/tmp/feature"] = "Fix login bug"
        let wt = makeWorktree(path: "/tmp/feature", isMain: false)

        XCTAssertEqual(manager.subtitle(for: wt), "Fix login bug")
    }

    func testSubtitleReturnsCommitMessageWhenNoTitle() {
        let manager = WorktreeManager(projectPath: "/tmp/test")
        let wt = makeWorktree(path: "/tmp/feature", isMain: false, commitMessage: "Add OAuth2")

        XCTAssertEqual(manager.subtitle(for: wt), "Add OAuth2")
    }

    func testSubtitleReturnsNilForMainWithNoTitle() {
        let manager = WorktreeManager(projectPath: "/tmp/test")
        let wt = makeWorktree(path: "/tmp/main", isMain: true, commitMessage: "Old commit")

        XCTAssertNil(manager.subtitle(for: wt))
    }

    func testSubtitleReturnsTitleForMainWhenAvailable() {
        let manager = WorktreeManager(projectPath: "/tmp/test")
        manager.worktreeTitles["/tmp/main"] = "Main branch title"
        let wt = makeWorktree(path: "/tmp/main", isMain: true)

        XCTAssertEqual(manager.subtitle(for: wt), "Main branch title")
    }

    // MARK: - Load Titles

    func testLoadTitlesReadsFromFiles() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let wtpadDir = tmpDir.appendingPathComponent(".wtpad")
        try FileManager.default.createDirectory(at: wtpadDir, withIntermediateDirectories: true)
        try "My title\n".write(to: wtpadDir.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)

        let manager = WorktreeManager(projectPath: "/tmp/test")
        manager.worktrees = [makeWorktree(path: tmpDir.path, isMain: false)]
        manager.loadTitles()

        XCTAssertEqual(manager.worktreeTitles[tmpDir.path], "My title")

        try FileManager.default.removeItem(at: tmpDir)
    }

    func testLoadTitlesIgnoresMissingFiles() {
        let manager = WorktreeManager(projectPath: "/tmp/test")
        manager.worktrees = [makeWorktree(path: "/tmp/nonexistent-\(UUID().uuidString)", isMain: false)]
        manager.loadTitles()

        XCTAssertTrue(manager.worktreeTitles.isEmpty)
    }

}

// MARK: - WorktreeError Tests

final class WorktreeErrorTests: XCTestCase {

    func testCommandNotFoundError() {
        let error = WorktreeManager.WorktreeError.commandFailed("wt list", stderr: "env: wt: command not found")
        let message = error.errorDescription ?? ""

        XCTAssertTrue(message.contains("Could not find 'wt' command"))
        XCTAssertTrue(message.contains("PATH"))
    }

    func testStderrShownDirectly() {
        let stderr = "fatal: not a git repository (or any of the parent directories): .git"
        let error = WorktreeManager.WorktreeError.commandFailed("wt list", stderr: stderr)

        XCTAssertEqual(error.errorDescription, stderr)
    }

    func testEmptyStderrFallsBackToGeneric() {
        let error = WorktreeManager.WorktreeError.commandFailed("wt list", stderr: "")
        let message = error.errorDescription ?? ""

        XCTAssertEqual(message, "Command failed: wt list")
    }

}
