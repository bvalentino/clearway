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
