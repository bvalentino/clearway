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

    func testSubtitleReturnsNilForMainEvenWithTitle() {
        let manager = WorktreeManager(projectPath: "/tmp/test")
        manager.worktreeTitles["/tmp/main"] = "Main branch title"
        let wt = makeWorktree(path: "/tmp/main", isMain: true)

        XCTAssertNil(manager.subtitle(for: wt))
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

        let worktrees = [makeWorktree(path: worktreePath, isMain: false)]
        let titles = WorktreeManager.fetchTitles(for: worktrees)

        XCTAssertEqual(titles[worktreePath], "My Claude Title")

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

        let worktrees = [makeWorktree(path: worktreePath, isMain: false)]
        let titles = WorktreeManager.fetchTitles(for: worktrees)

        XCTAssertEqual(titles[worktreePath], "Updated Title")

        try fm.removeItem(atPath: projectDir)
    }

    func testLoadTitlesSurvivesLargeSessionFile() throws {
        let fm = FileManager.default
        let worktreePath = "/tmp/test-wt-\(UUID().uuidString)"
        let encodedPath = WorktreeManager.encodePathForClaude(worktreePath)
        let claudeDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let projectDir = (claudeDir as NSString)
            .appendingPathComponent("projects")
            .appending("/\(encodedPath)")
        try fm.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Write a session JSONL where custom-title is near the start, followed by >8KB of data
        // This simulates an active Claude session where tool calls push the title out of an 8KB tail window
        let sessionFile = (projectDir as NSString).appendingPathComponent("test-session.jsonl")
        var jsonl = "{\"type\":\"custom-title\",\"customTitle\":\"Early Title\",\"sessionId\":\"test\"}\n"
        let padding = String(repeating: "x", count: 200)
        for i in 0..<100 {
            jsonl += "{\"type\":\"assistant\",\"message\":\"\(padding)-\(i)\"}\n"
        }

        try jsonl.write(toFile: sessionFile, atomically: true, encoding: .utf8)

        // Verify file is larger than 8KB
        let attrs = try fm.attributesOfItem(atPath: sessionFile)
        let fileSize = attrs[.size] as! UInt64
        XCTAssertGreaterThan(fileSize, 16384, "Test file should be larger than 16KB to exceed head+tail window")

        let worktrees = [makeWorktree(path: worktreePath, isMain: false)]
        let titles = WorktreeManager.fetchTitles(for: worktrees)

        XCTAssertEqual(titles[worktreePath], "Early Title")

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
