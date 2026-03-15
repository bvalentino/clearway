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

    func testSubtitleReturnsNilWhenNoTitle() {
        let manager = WorktreeManager(projectPath: "/tmp/test")
        let wt = makeWorktree(path: "/tmp/feature", isMain: false)

        XCTAssertNil(manager.subtitle(for: wt))
    }

    func testSubtitleReturnsNilForMainWithNoTitle() {
        let manager = WorktreeManager(projectPath: "/tmp/test")
        let wt = makeWorktree(path: "/tmp/main", isMain: true)

        XCTAssertNil(manager.subtitle(for: wt))
    }

    func testSubtitleReturnsTitleForMainWhenAvailable() {
        let manager = WorktreeManager(projectPath: "/tmp/test")
        manager.worktreeTitles["/tmp/main"] = "Main branch title"
        let wt = makeWorktree(path: "/tmp/main", isMain: true)

        XCTAssertEqual(manager.subtitle(for: wt), "Main branch title")
    }

    // MARK: - Load Titles (Claude Code sessions)

    func testLoadTitlesReadsFromClaudeSession() throws {
        let fm = FileManager.default
        // Create a fake worktree path and its Claude Code session directory
        let worktreePath = "/tmp/test-wt-\(UUID().uuidString)"
        let encodedPath = WorktreeManager.encodePathForClaude(worktreePath)
        let claudeDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let projectDir = (claudeDir as NSString)
            .appendingPathComponent("projects")
            .appending("/\(encodedPath)")
        try fm.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Write a session JSONL with a custom-title entry
        let sessionFile = (projectDir as NSString).appendingPathComponent("test-session.jsonl")
        let jsonl = "{\"type\":\"custom-title\",\"customTitle\":\"My Claude Title\",\"sessionId\":\"test\"}\n"
        try jsonl.write(toFile: sessionFile, atomically: true, encoding: .utf8)

        let manager = WorktreeManager(projectPath: "/tmp/test")
        manager.worktrees = [makeWorktree(path: worktreePath, isMain: false)]
        manager.loadTitles()

        XCTAssertEqual(manager.worktreeTitles[worktreePath], "My Claude Title")

        try fm.removeItem(atPath: projectDir)
    }

    func testLoadTitlesUsesLastCustomTitle() throws {
        let fm = FileManager.default
        let worktreePath = "/tmp/test-wt-\(UUID().uuidString)"
        let encodedPath = WorktreeManager.encodePathForClaude(worktreePath)
        let claudeDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let projectDir = (claudeDir as NSString)
            .appendingPathComponent("projects")
            .appending("/\(encodedPath)")
        try fm.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Write a session JSONL with multiple custom-title entries (last wins)
        let sessionFile = (projectDir as NSString).appendingPathComponent("test-session.jsonl")
        let jsonl = """
        {"type":"custom-title","customTitle":"First Title","sessionId":"test"}
        {"type":"user","message":"hello"}
        {"type":"custom-title","customTitle":"Updated Title","sessionId":"test"}
        """
        try jsonl.write(toFile: sessionFile, atomically: true, encoding: .utf8)

        let manager = WorktreeManager(projectPath: "/tmp/test")
        manager.worktrees = [makeWorktree(path: worktreePath, isMain: false)]
        manager.loadTitles()

        XCTAssertEqual(manager.worktreeTitles[worktreePath], "Updated Title")

        try fm.removeItem(atPath: projectDir)
    }

    func testLoadTitlesIgnoresMissingSessions() {
        let manager = WorktreeManager(projectPath: "/tmp/test")
        manager.worktrees = [makeWorktree(path: "/tmp/nonexistent-\(UUID().uuidString)", isMain: false)]
        manager.loadTitles()

        XCTAssertTrue(manager.worktreeTitles.isEmpty)
    }

    func testEncodePathForClaude() {
        XCTAssertEqual(
            WorktreeManager.encodePathForClaude("/Users/foo/bar"),
            "-Users-foo-bar"
        )
        XCTAssertEqual(
            WorktreeManager.encodePathForClaude("/Users/foo/.worktrees/my-branch"),
            "-Users-foo--worktrees-my-branch"
        )
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
