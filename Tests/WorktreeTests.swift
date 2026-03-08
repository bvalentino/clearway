import XCTest
@testable import wtpad

final class WorktreeTests: XCTestCase {

    // MARK: - JSON Decoding

    func testDecodesMinimalWorktree() throws {
        let json = """
        {
            "branch": "main",
            "path": "/tmp/project",
            "kind": "worktree",
            "commit": {
                "sha": "abc123def456",
                "short_sha": "abc123d",
                "message": "Initial commit",
                "timestamp": 1700000000
            },
            "working_tree": {
                "staged": false,
                "modified": false,
                "untracked": false
            },
            "main_state": "is_main",
            "worktree": {
                "detached": false
            },
            "is_main": true,
            "is_current": true,
            "is_previous": false
        }
        """

        let wt = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))

        XCTAssertEqual(wt.branch, "main")
        XCTAssertEqual(wt.path, "/tmp/project")
        XCTAssertEqual(wt.kind, "worktree")
        XCTAssertEqual(wt.commit.sha, "abc123def456")
        XCTAssertEqual(wt.commit.shortSha, "abc123d")
        XCTAssertEqual(wt.commit.message, "Initial commit")
        XCTAssertEqual(wt.commit.timestamp, 1700000000)
        XCTAssertEqual(wt.mainState, "is_main")
        XCTAssertTrue(wt.isMain)
        XCTAssertTrue(wt.isCurrent)
        XCTAssertFalse(wt.isPrevious)
        XCTAssertEqual(wt.workingTree?.staged, false)
        XCTAssertEqual(wt.workingTree?.modified, false)
        XCTAssertNil(wt.ci)
        XCTAssertNil(wt.main)
        XCTAssertNil(wt.remote)
    }

    func testDecodesFullWorktree() throws {
        let json = """
        {
            "branch": "feature-auth",
            "path": "/tmp/project-feature-auth",
            "kind": "worktree",
            "commit": {
                "sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                "short_sha": "deadbee",
                "message": "Add OAuth2 support",
                "timestamp": 1700001000
            },
            "working_tree": {
                "staged": true,
                "modified": true,
                "untracked": false,
                "renamed": false,
                "deleted": true,
                "diff": { "added": 120, "deleted": 30 }
            },
            "main_state": "ahead",
            "integration_reason": null,
            "operation_state": null,
            "main": { "ahead": 5, "behind": 2, "diff": { "added": 200, "deleted": 50 } },
            "remote": { "name": "origin", "branch": "feature-auth", "ahead": 1, "behind": 0 },
            "worktree": { "detached": false },
            "ci": { "status": "passed", "source": "pr", "stale": false, "url": "https://github.com/org/repo/pull/42" },
            "is_main": false,
            "is_current": false,
            "is_previous": true,
            "symbols": "+!↑|"
        }
        """

        let wt = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))

        XCTAssertEqual(wt.branch, "feature-auth")
        XCTAssertFalse(wt.isMain)
        XCTAssertFalse(wt.isCurrent)
        XCTAssertTrue(wt.isPrevious)

        // Working tree
        XCTAssertEqual(wt.workingTree?.staged, true)
        XCTAssertEqual(wt.workingTree?.modified, true)
        XCTAssertEqual(wt.workingTree?.deleted, true)
        XCTAssertEqual(wt.workingTree?.diff?.added, 120)
        XCTAssertEqual(wt.workingTree?.diff?.deleted, 30)

        // Main divergence
        XCTAssertEqual(wt.main?.ahead, 5)
        XCTAssertEqual(wt.main?.behind, 2)
        XCTAssertEqual(wt.main?.diff?.added, 200)

        // Remote
        XCTAssertEqual(wt.remote?.name, "origin")
        XCTAssertEqual(wt.remote?.branch, "feature-auth")
        XCTAssertEqual(wt.remote?.ahead, 1)
        XCTAssertEqual(wt.remote?.behind, 0)

        // CI
        XCTAssertEqual(wt.ci?.status, "passed")
        XCTAssertEqual(wt.ci?.source, "pr")
        XCTAssertEqual(wt.ci?.stale, false)
        XCTAssertEqual(wt.ci?.url, "https://github.com/org/repo/pull/42")

        // Symbols
        XCTAssertEqual(wt.symbols, "+!↑|")
    }

    func testDecodesRealWtListOutput() throws {
        // Real output from `wt list --format json` captured during development
        let json = """
        [
          {
            "branch": "main",
            "path": "/Users/dev/project",
            "kind": "worktree",
            "commit": {
              "sha": "e47392438fdb8b75cb7569147095440646a2329a",
              "short_sha": "e473924",
              "message": "Initial commit: native macOS terminal app with libghostty",
              "timestamp": 1772935383
            },
            "working_tree": {
              "staged": false,
              "modified": true,
              "untracked": true,
              "renamed": false,
              "deleted": false,
              "diff": { "added": 56, "deleted": 15 }
            },
            "main_state": "is_main",
            "remote": {
              "name": "origin",
              "branch": "main",
              "ahead": 0,
              "behind": 0
            },
            "worktree": { "detached": false },
            "is_main": true,
            "is_current": true,
            "is_previous": false,
            "statusline": "main  !?^|",
            "symbols": "!?^|"
          }
        ]
        """

        let worktrees = try JSONDecoder().decode([Worktree].self, from: Data(json.utf8))
        XCTAssertEqual(worktrees.count, 1)

        let wt = worktrees[0]
        XCTAssertEqual(wt.branch, "main")
        XCTAssertTrue(wt.isMain)
        XCTAssertTrue(wt.isCurrent)
        XCTAssertEqual(wt.workingTree?.diff?.added, 56)
        XCTAssertEqual(wt.remote?.ahead, 0)
    }

    func testDecodesWorktreeArray() throws {
        let json = """
        [
          {
            "branch": "main",
            "path": "/tmp/main",
            "kind": "worktree",
            "commit": { "sha": "aaa", "short_sha": "aaa", "message": "init", "timestamp": 1 },
            "worktree": { "detached": false },
            "main_state": "is_main",
            "is_main": true,
            "is_current": true,
            "is_previous": false
          },
          {
            "branch": "feature",
            "path": "/tmp/feature",
            "kind": "worktree",
            "commit": { "sha": "bbb", "short_sha": "bbb", "message": "feat", "timestamp": 2 },
            "worktree": { "detached": false },
            "main_state": "ahead",
            "main": { "ahead": 3, "behind": 0 },
            "is_main": false,
            "is_current": false,
            "is_previous": false
          }
        ]
        """

        let worktrees = try JSONDecoder().decode([Worktree].self, from: Data(json.utf8))
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertEqual(worktrees[0].branch, "main")
        XCTAssertEqual(worktrees[1].branch, "feature")
        XCTAssertEqual(worktrees[1].main?.ahead, 3)
    }

    func testDecodesBranchWithoutWorktree() throws {
        let json = """
        {
            "branch": "stale-branch",
            "kind": "branch",
            "commit": { "sha": "ccc", "short_sha": "ccc", "message": "old", "timestamp": 1 },
            "main_state": "integrated",
            "integration_reason": "ancestor",
            "is_main": false,
            "is_current": false,
            "is_previous": false
        }
        """

        let wt = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))
        XCTAssertEqual(wt.branch, "stale-branch")
        XCTAssertNil(wt.path)
        XCTAssertEqual(wt.kind, "branch")
        XCTAssertEqual(wt.mainState, "integrated")
        XCTAssertEqual(wt.integrationReason, "ancestor")
    }

    func testDecodesConflictState() throws {
        let json = """
        {
            "branch": "conflict-branch",
            "path": "/tmp/conflict",
            "kind": "worktree",
            "commit": { "sha": "ddd", "short_sha": "ddd", "message": "wip", "timestamp": 1 },
            "worktree": { "detached": false },
            "main_state": "would_conflict",
            "operation_state": "conflicts",
            "is_main": false,
            "is_current": false,
            "is_previous": false
        }
        """

        let wt = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))
        XCTAssertEqual(wt.operationState, "conflicts")
        XCTAssertTrue(wt.hasConflicts)
        XCTAssertFalse(wt.isRebase)
    }

    func testDecodesRebaseState() throws {
        let json = """
        {
            "branch": "rebase-branch",
            "path": "/tmp/rebase",
            "kind": "worktree",
            "commit": { "sha": "eee", "short_sha": "eee", "message": "rebasing", "timestamp": 1 },
            "worktree": { "detached": false },
            "main_state": "behind",
            "operation_state": "rebase",
            "is_main": false,
            "is_current": false,
            "is_previous": false
        }
        """

        let wt = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))
        XCTAssertTrue(wt.isRebase)
        XCTAssertFalse(wt.hasConflicts)
    }

    // MARK: - Computed Properties

    func testId() throws {
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature")
        XCTAssertEqual(wt.id, "/tmp/feature")
    }

    func testIdFallsToBranchWhenNoPath() throws {
        let wt = makeWorktree(branch: "orphan", path: nil)
        XCTAssertEqual(wt.id, "orphan")
    }

    func testDisplayName() {
        XCTAssertEqual(makeWorktree(branch: "feature", path: nil).displayName, "feature")
        XCTAssertEqual(makeWorktree(branch: nil, path: "/tmp/x").displayName, "(detached)")
    }

    func testIsDimmed() {
        XCTAssertTrue(makeWorktree(mainState: "integrated").isDimmed)
        XCTAssertTrue(makeWorktree(mainState: "empty").isDimmed)
        XCTAssertFalse(makeWorktree(mainState: "ahead").isDimmed)
        XCTAssertFalse(makeWorktree(mainState: "is_main").isDimmed)
        XCTAssertFalse(makeWorktree(mainState: nil).isDimmed)
    }

    func testCiStatusColor() {
        XCTAssertEqual(Worktree.CI(status: "passed", source: nil, stale: nil, url: nil).statusColor, .green)
        XCTAssertEqual(Worktree.CI(status: "running", source: nil, stale: nil, url: nil).statusColor, .blue)
        XCTAssertEqual(Worktree.CI(status: "failed", source: nil, stale: nil, url: nil).statusColor, .red)
        XCTAssertEqual(Worktree.CI(status: "conflicts", source: nil, stale: nil, url: nil).statusColor, .yellow)
        XCTAssertEqual(Worktree.CI(status: "no-ci", source: nil, stale: nil, url: nil).statusColor, .gray)
        XCTAssertEqual(Worktree.CI(status: "error", source: nil, stale: nil, url: nil).statusColor, .orange)
        XCTAssertEqual(Worktree.CI(status: "unknown", source: nil, stale: nil, url: nil).statusColor, .gray)
    }

    func testCiStatusLabel() {
        XCTAssertEqual(Worktree.CI(status: "passed", source: nil, stale: nil, url: nil).statusLabel, "CI passed")
        XCTAssertEqual(Worktree.CI(status: "failed", source: nil, stale: nil, url: nil).statusLabel, "CI failed")
        XCTAssertEqual(Worktree.CI(status: "unknown", source: nil, stale: nil, url: nil).statusLabel, "unknown")
    }

}
