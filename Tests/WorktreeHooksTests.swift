import XCTest
@testable import Clearway

final class WorktreeHooksTests: XCTestCase {

    private let suiteName = "app.getclearway.mac.tests.hooks"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    private let context = WorktreeHooks.Context(
        branch: "feature-auth",
        worktreePath: "/Users/dev/project/.worktrees/feature-auth",
        primaryWorktreePath: "/Users/dev/project"
    )

    // MARK: - Interpolation

    func testInterpolatesAllVariables() {
        let hooks = WorktreeHooks(
            afterCreate: "echo {{ branch }} {{ worktree_path }} {{ primary_worktree_path }} {{ repo_path }}",
            beforeRemove: ""
        )
        let result = hooks.interpolated(\.afterCreate, context: context)
        XCTAssertEqual(result, "echo 'feature-auth' '/Users/dev/project/.worktrees/feature-auth' '/Users/dev/project' '/Users/dev/project'")
    }

    func testReturnsNilForEmptyHook() {
        let hooks = WorktreeHooks(afterCreate: "", beforeRemove: "")
        XCTAssertNil(hooks.interpolated(\.afterCreate, context: context))
    }

    func testReturnsNilForWhitespaceOnlyHook() {
        let hooks = WorktreeHooks(afterCreate: "  \n  ", beforeRemove: "")
        XCTAssertNil(hooks.interpolated(\.afterCreate, context: context))
    }

    func testRepoPathAliasesPrimaryWorktreePath() {
        let hooks = WorktreeHooks(afterCreate: "cd {{ repo_path }}", beforeRemove: "")
        let result = hooks.interpolated(\.afterCreate, context: context)
        XCTAssertEqual(result, "cd '/Users/dev/project'")
    }

    func testShellEscapesBranchName() {
        let dangerousContext = WorktreeHooks.Context(
            branch: "test$(whoami)",
            worktreePath: "/tmp/test",
            primaryWorktreePath: "/tmp"
        )
        let hooks = WorktreeHooks(afterCreate: "echo {{ branch }}", beforeRemove: "")
        let result = hooks.interpolated(\.afterCreate, context: dangerousContext)
        XCTAssertEqual(result, "echo 'test$(whoami)'")
    }

    func testShellEscapesSingleQuotesInPath() {
        let contextWithQuote = WorktreeHooks.Context(
            branch: "test",
            worktreePath: "/Users/dev/it's a path",
            primaryWorktreePath: "/tmp"
        )
        let hooks = WorktreeHooks(afterCreate: "ls {{ worktree_path }}", beforeRemove: "")
        let result = hooks.interpolated(\.afterCreate, context: contextWithQuote)
        XCTAssertEqual(result, "ls '/Users/dev/it'\\''s a path'")
    }

    func testBeforeRemoveHook() {
        let hooks = WorktreeHooks(afterCreate: "", beforeRemove: "cleanup {{ branch }}")
        let result = hooks.interpolated(\.beforeRemove, context: context)
        XCTAssertEqual(result, "cleanup 'feature-auth'")
    }

    // MARK: - Hook chaining

    func testChainCommandsBothPresent() {
        XCTAssertEqual(
            WorktreeHooks.chainCommands("echo project", "echo workflow"),
            "(echo project) && (echo workflow)"
        )
    }

    func testChainCommandsFirstOnly() {
        XCTAssertEqual(WorktreeHooks.chainCommands("echo project", nil), "echo project")
    }

    func testChainCommandsSecondOnly() {
        XCTAssertEqual(WorktreeHooks.chainCommands(nil, "echo workflow"), "echo workflow")
    }

    func testChainCommandsNeitherReturnsNil() {
        XCTAssertNil(WorktreeHooks.chainCommands(nil, nil))
    }

    // MARK: - Persistence

    func testSaveAndLoad() {
        let path = "/tmp/test-project-\(UUID().uuidString)"
        let hooks = WorktreeHooks(
            afterCreate: "echo create",
            beforeRemove: "echo remove"
        )
        hooks.save(for: path, defaults: testDefaults)

        let loaded = WorktreeHooks.load(for: path, defaults: testDefaults)
        XCTAssertEqual(loaded.afterCreate, "echo create")
        XCTAssertEqual(loaded.beforeRemove, "echo remove")
    }

    func testLoadDefaultsToEmpty() {
        let path = "/tmp/nonexistent-\(UUID().uuidString)"
        let loaded = WorktreeHooks.load(for: path, defaults: testDefaults)
        XCTAssertEqual(loaded.afterCreate, "")
        XCTAssertEqual(loaded.beforeRemove, "")
    }
}
