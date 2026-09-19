import XCTest
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

/// Base for tests that need a scratch project root, created per test and removed on teardown.
@MainActor
class TempRootTestCase: XCTestCase {

    /// Directory-name prefix for the scratch root; subclasses override it to stay distinguishable
    /// in `NSTemporaryDirectory()` when a run leaves one behind.
    class var tempRootPrefix: String { "clearway-tests" }

    var tempRoot: String!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(Self.tempRootPrefix)-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let root = tempRoot {
            try? FileManager.default.removeItem(atPath: root)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    /// A coordinator scoped to the scratch root, over a fresh manager unless one is supplied.
    func makeCoordinator(_ taskManager: WorkTaskManager? = nil) -> WorkTaskCoordinator {
        WorkTaskCoordinator(
            workTaskManager: taskManager ?? WorkTaskManager(projectPath: tempRoot),
            terminalManager: TerminalManager(),
            worktreeManager: WorktreeManager(projectPath: tempRoot)
        )
    }
}

/// A throwaway git repository for the suites that must prove behaviour against real git.
///
/// Shells out to `/usr/bin/git` directly with `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` pointed
/// at `/dev/null`, so the developer's own git config cannot change a result, and resolves symlinks
/// in every path it hands back — a temp root under `/var/folders` is a symlink to `/private/var/…`
/// and `git worktree list` reports the resolved form.
struct GitRepoFixture {

    struct Failure: Error {
        let command: String
        let status: Int32
        let stderr: String
    }

    let root: String

    static func make(at root: String) throws -> GitRepoFixture {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        try git(["init", "-q", "."], in: resolved)
        try git(
            [
                "-c", "user.name=Clearway Tests",
                "-c", "user.email=tests@example.com",
                "commit", "-q", "--allow-empty", "-m", "init"
            ],
            in: resolved
        )
        return GitRepoFixture(root: resolved)
    }

    func addWorktree(branch: String) throws -> String {
        let path = (root as NSString).appendingPathComponent(".worktrees/\(branch)")
        try Self.git(["worktree", "add", "-q", path, "-b", branch], in: root)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func removeWorktree(at path: String) throws {
        try Self.git(["worktree", "remove", "--force", path], in: root)
    }

    /// The value stored against one worktree, or nil when the key is absent — `--get` exits 1 for
    /// a missing key and the whole command fails on a worktree with no `config.worktree` yet.
    func value(ofKey key: String, atWorktree path: String) throws -> String? {
        let result = try Self.capture(["-C", path, "config", "--worktree", "--get", key], in: root)
        guard result.status == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enables the extension the way `WorktreeConfigStore`'s bootstrap does, for the tests that
    /// seed worktree config directly instead of going through the store.
    func enableWorktreeConfig() throws {
        let worktreeConfig = (root as NSString).appendingPathComponent(".git/config.worktree")
        if let bare = try value(ofLocalKey: "core.bare") {
            try Self.git(["config", "--file", worktreeConfig, "core.bare", bare], in: root)
        }
        try Self.git(["config", "--local", "extensions.worktreeConfig", "true"], in: root)
        _ = try Self.capture(["config", "--local", "--unset", "core.bare"], in: root)
    }

    func setValue(_ value: String, ofKey key: String, atWorktree path: String) throws {
        try Self.git(["-C", path, "config", "--worktree", key, value], in: root)
    }

    func unsetValue(ofKey key: String, atWorktree path: String) throws {
        try Self.git(["-C", path, "config", "--worktree", "--unset", key], in: root)
    }

    func value(ofLocalKey key: String) throws -> String? {
        let result = try Self.capture(["config", "--local", "--get", key], in: root)
        guard result.status == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func mainWorktreeConfigContents() throws -> String {
        try String(
            contentsOfFile: (root as NSString).appendingPathComponent(".git/config.worktree"),
            encoding: .utf8
        )
    }

    /// Whether git can still operate in the given worktree — the end-state check the extension
    /// bootstrap has to survive in both the main and a linked worktree.
    func statusSucceeds(in path: String) throws -> Bool {
        try Self.capture(["-C", path, "status", "--porcelain"], in: root).status == 0
    }

    @discardableResult
    static func git(_ args: [String], in directory: String) throws -> String {
        let result = try capture(args, in: directory)
        guard result.status == 0 else {
            throw Failure(command: args.joined(separator: " "), status: result.status, stderr: result.stderr)
        }
        return result.stdout
    }

    static func capture(_ args: [String], in directory: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout, encoding: .utf8) ?? "",
            String(data: stderr, encoding: .utf8) ?? ""
        )
    }
}

/// Base for the `WorktreeGroupManager` suites. Every value the manager owns is kept in git
/// config, so the scratch root is a repository before the manager is built over it.
class WorktreeGroupManagerGitTestCase: TempRootTestCase {

    override class var tempRootPrefix: String { "clearway-manager-tests" }

    var repo: GitRepoFixture!
    var manager: WorktreeGroupManager!

    override func setUp() async throws {
        try await super.setUp()
        repo = try GitRepoFixture.make(at: tempRoot)
        manager = WorktreeGroupManager(projectPath: tempRoot)
        // The manager's `init` load runs on its own Task and republishes everything it reads from
        // git config, so a mutation a test body makes before it lands is overwritten.
        await manager.loadTask?.value
    }

    override func tearDown() async throws {
        manager = nil
        repo = nil
        try await super.tearDown()
    }

    /// Replaces `manager` with a fresh one over the same root and waits for its load — the
    /// relaunch every persistence assertion is really about.
    ///
    /// Also the only way a test that enables `extensions.worktreeConfig` behind the manager's back
    /// is seen: `WorktreeConfigStore` memoises a probe that found the extension off, and the load
    /// runs one before any test body does.
    func restartManager() async {
        manager = WorktreeGroupManager(projectPath: tempRoot)
        await manager.loadTask?.value
    }

    /// Polls rather than sleeping a fixed span: a config write is a git subprocess, behind the
    /// extension bootstrap on its first call.
    func waitFor<Value: Equatable>(
        _ expected: Value,
        describing subject: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        reading read: () throws -> Value
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last = try read()
        while last != expected, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            last = try read()
        }
        XCTAssertEqual(last, expected, subject, file: file, line: line)
    }

    /// The `clearway.*` value git has on disk for one worktree, once the write lands.
    func waitForStoredValue(
        _ expected: String?,
        ofKey key: String,
        at path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitFor(expected, describing: "\(key) at \(path)", file: file, line: line) {
            try self.repo.value(ofKey: key, atWorktree: path)
        }
    }
}
