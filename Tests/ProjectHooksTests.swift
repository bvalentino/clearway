import XCTest
@testable import Clearway

final class ProjectHooksTests: XCTestCase {

    private let suiteName = "app.getclearway.mac.tests.hooks"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    private let context = ProjectHooks.Context(
        branch: "feature-auth",
        worktreePath: "/Users/dev/project/.worktrees/feature-auth",
        primaryWorktreePath: "/Users/dev/project"
    )

    // MARK: - Interpolation

    func testInterpolatesAllVariables() {
        let hooks = ProjectHooks(
            afterCreate: "echo {{ branch }} {{ worktree_path }} {{ primary_worktree_path }} {{ repo_path }}",
            beforeRemove: ""
        )
        let result = hooks.interpolated(\.afterCreate, context: context)
        XCTAssertEqual(result, "echo 'feature-auth' '/Users/dev/project/.worktrees/feature-auth' '/Users/dev/project' '/Users/dev/project'")
    }

    func testReturnsNilForEmptyHook() {
        let hooks = ProjectHooks(afterCreate: "", beforeRemove: "")
        XCTAssertNil(hooks.interpolated(\.afterCreate, context: context))
    }

    func testReturnsNilForWhitespaceOnlyHook() {
        let hooks = ProjectHooks(afterCreate: "  \n  ", beforeRemove: "")
        XCTAssertNil(hooks.interpolated(\.afterCreate, context: context))
    }

    func testRepoPathAliasesPrimaryWorktreePath() {
        let hooks = ProjectHooks(afterCreate: "cd {{ repo_path }}", beforeRemove: "")
        let result = hooks.interpolated(\.afterCreate, context: context)
        XCTAssertEqual(result, "cd '/Users/dev/project'")
    }

    func testShellEscapesBranchName() {
        let dangerousContext = ProjectHooks.Context(
            branch: "test$(whoami)",
            worktreePath: "/tmp/test",
            primaryWorktreePath: "/tmp"
        )
        let hooks = ProjectHooks(afterCreate: "echo {{ branch }}", beforeRemove: "")
        let result = hooks.interpolated(\.afterCreate, context: dangerousContext)
        XCTAssertEqual(result, "echo 'test$(whoami)'")
    }

    func testShellEscapesSingleQuotesInPath() {
        let contextWithQuote = ProjectHooks.Context(
            branch: "test",
            worktreePath: "/Users/dev/it's a path",
            primaryWorktreePath: "/tmp"
        )
        let hooks = ProjectHooks(afterCreate: "ls {{ worktree_path }}", beforeRemove: "")
        let result = hooks.interpolated(\.afterCreate, context: contextWithQuote)
        XCTAssertEqual(result, "ls '/Users/dev/it'\\''s a path'")
    }

    func testBeforeRemoveHook() {
        let hooks = ProjectHooks(afterCreate: "", beforeRemove: "cleanup {{ branch }}")
        let result = hooks.interpolated(\.beforeRemove, context: context)
        XCTAssertEqual(result, "cleanup 'feature-auth'")
    }

    // MARK: - Persistence

    func testSaveAndLoad() {
        let path = "/tmp/test-project-\(UUID().uuidString)"
        let hooks = ProjectHooks(
            afterCreate: "echo create",
            beforeRemove: "echo remove"
        )
        hooks.save(for: path, defaults: testDefaults)

        let loaded = ProjectHooks.load(for: path, defaults: testDefaults)
        XCTAssertEqual(loaded.afterCreate, "echo create")
        XCTAssertEqual(loaded.beforeRemove, "echo remove")
    }

    func testLoadDefaultsToEmpty() {
        let path = "/tmp/nonexistent-\(UUID().uuidString)"
        let loaded = ProjectHooks.load(for: path, defaults: testDefaults)
        XCTAssertEqual(loaded.afterCreate, "")
        XCTAssertEqual(loaded.beforeRemove, "")
    }
}
