import XCTest
@testable import wtpad

@MainActor
final class WorktreeManagerTests: XCTestCase {

    private let suiteName = "com.wtpad.mac.tests"

    override func setUp() {
        super.setUp()
        // Use a clean defaults domain for each test
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? suiteName)
        UserDefaults.standard.removeObject(forKey: "wtpad.projectPaths")
        UserDefaults.standard.removeObject(forKey: "wtpad.activeProjectPath")
        UserDefaults.standard.removeObject(forKey: "wtpad.projectPath")
    }

    // MARK: - Project Management

    func testAddProject() {
        let manager = WorktreeManager()
        manager.addProject("/tmp/project-a")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-a"])
        XCTAssertEqual(manager.activeProjectPath, "/tmp/project-a")
    }

    func testAddMultipleProjects() {
        let manager = WorktreeManager()
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-b")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-a", "/tmp/project-b"])
        XCTAssertEqual(manager.activeProjectPath, "/tmp/project-b")
    }

    func testAddDuplicateProjectIsNoop() {
        let manager = WorktreeManager()
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-a")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-a"])
    }

    func testRemoveProject() {
        let manager = WorktreeManager()
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-b")
        manager.removeProject("/tmp/project-a")

        XCTAssertEqual(manager.projectPaths, ["/tmp/project-b"])
    }

    func testRemoveActiveProjectSwitchesToFirst() {
        let manager = WorktreeManager()
        manager.addProject("/tmp/project-a")
        manager.addProject("/tmp/project-b")

        // Active is project-b (last added)
        XCTAssertEqual(manager.activeProjectPath, "/tmp/project-b")

        manager.removeProject("/tmp/project-b")
        XCTAssertEqual(manager.activeProjectPath, "/tmp/project-a")
    }

    func testRemoveLastProjectClearsActive() {
        let manager = WorktreeManager()
        manager.addProject("/tmp/project-a")
        manager.removeProject("/tmp/project-a")

        XCTAssertTrue(manager.projectPaths.isEmpty)
        XCTAssertNil(manager.activeProjectPath)
    }

    func testPersistence() {
        // Add projects
        let manager1 = WorktreeManager()
        manager1.addProject("/tmp/project-a")
        manager1.addProject("/tmp/project-b")

        // Read back from defaults
        let paths = UserDefaults.standard.stringArray(forKey: "wtpad.projectPaths")
        let active = UserDefaults.standard.string(forKey: "wtpad.activeProjectPath")

        XCTAssertEqual(paths, ["/tmp/project-a", "/tmp/project-b"])
        XCTAssertEqual(active, "/tmp/project-b")
    }

    func testMigrationFromSingleProjectPath() {
        // Simulate old single-project storage
        UserDefaults.standard.set("/tmp/legacy-project", forKey: "wtpad.projectPath")

        let manager = WorktreeManager()

        XCTAssertEqual(manager.projectPaths, ["/tmp/legacy-project"])
        XCTAssertEqual(manager.activeProjectPath, "/tmp/legacy-project")
        // Old key should be cleaned up
        XCTAssertNil(UserDefaults.standard.string(forKey: "wtpad.projectPath"))
    }

    func testEmptyInitialState() {
        let manager = WorktreeManager()

        XCTAssertTrue(manager.projectPaths.isEmpty)
        XCTAssertNil(manager.activeProjectPath)
        XCTAssertTrue(manager.worktrees.isEmpty)
        XCTAssertFalse(manager.isLoading)
        XCTAssertNil(manager.error)
    }

    // MARK: - Subtitle

    func testSubtitleReturnsTitleWhenAvailable() {
        let manager = WorktreeManager()
        manager.worktreeTitles["/tmp/feature"] = "Fix login bug"
        let wt = makeWorktree(path: "/tmp/feature", isMain: false)

        XCTAssertEqual(manager.subtitle(for: wt), "Fix login bug")
    }

    func testSubtitleReturnsCommitMessageWhenNoTitle() {
        let manager = WorktreeManager()
        let wt = makeWorktree(path: "/tmp/feature", isMain: false, commitMessage: "Add OAuth2")

        XCTAssertEqual(manager.subtitle(for: wt), "Add OAuth2")
    }

    func testSubtitleReturnsNilForMainWithNoTitle() {
        let manager = WorktreeManager()
        let wt = makeWorktree(path: "/tmp/main", isMain: true, commitMessage: "Old commit")

        XCTAssertNil(manager.subtitle(for: wt))
    }

    func testSubtitleReturnsTitleForMainWhenAvailable() {
        let manager = WorktreeManager()
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

        let manager = WorktreeManager()
        manager.worktrees = [makeWorktree(path: tmpDir.path, isMain: false)]
        manager.loadTitles()

        XCTAssertEqual(manager.worktreeTitles[tmpDir.path], "My title")

        try FileManager.default.removeItem(at: tmpDir)
    }

    func testLoadTitlesIgnoresMissingFiles() {
        let manager = WorktreeManager()
        manager.worktrees = [makeWorktree(path: "/tmp/nonexistent-\(UUID().uuidString)", isMain: false)]
        manager.loadTitles()

        XCTAssertTrue(manager.worktreeTitles.isEmpty)
    }

}
