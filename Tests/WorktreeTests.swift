import XCTest
@testable import Clearway

final class WorktreeTests: XCTestCase {

    // MARK: - Git Porcelain Parser

    func testParsesBasicPorcelainOutput() {
        let output = """
        worktree /Users/dev/project
        HEAD abc123def456
        branch refs/heads/main

        worktree /Users/dev/project/.worktrees/feature
        HEAD def456abc123
        branch refs/heads/feature

        """

        let worktrees = WorktreeManager.parseWorktreeListOutput(output)

        XCTAssertEqual(worktrees.count, 2)

        XCTAssertEqual(worktrees[0].path, "/Users/dev/project")
        XCTAssertEqual(worktrees[0].branch, "main")
        XCTAssertTrue(worktrees[0].isMain)

        XCTAssertEqual(worktrees[1].path, "/Users/dev/project/.worktrees/feature")
        XCTAssertEqual(worktrees[1].branch, "feature")
        XCTAssertFalse(worktrees[1].isMain)
    }

    func testParsesSingleWorktree() {
        let output = """
        worktree /Users/dev/project
        HEAD abc123
        branch refs/heads/main

        """

        let worktrees = WorktreeManager.parseWorktreeListOutput(output)

        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(worktrees[0].branch, "main")
        XCTAssertTrue(worktrees[0].isMain)
    }

    func testParsesDetachedHead() {
        let output = """
        worktree /Users/dev/project
        HEAD abc123
        branch refs/heads/main

        worktree /Users/dev/project/.worktrees/detached
        HEAD def456
        detached

        """

        let worktrees = WorktreeManager.parseWorktreeListOutput(output)

        XCTAssertEqual(worktrees.count, 2)
        XCTAssertNil(worktrees[1].branch)
        XCTAssertEqual(worktrees[1].displayName, "(detached)")
    }

    func testParsesMultipleWorktrees() {
        let output = """
        worktree /Users/dev/project
        HEAD aaa
        branch refs/heads/main

        worktree /Users/dev/project/.worktrees/feature-a
        HEAD bbb
        branch refs/heads/feature-a

        worktree /Users/dev/project/.worktrees/feature-b
        HEAD ccc
        branch refs/heads/feature-b

        """

        let worktrees = WorktreeManager.parseWorktreeListOutput(output)

        XCTAssertEqual(worktrees.count, 3)
        XCTAssertTrue(worktrees[0].isMain)
        XCTAssertFalse(worktrees[1].isMain)
        XCTAssertFalse(worktrees[2].isMain)
        XCTAssertEqual(worktrees[1].branch, "feature-a")
        XCTAssertEqual(worktrees[2].branch, "feature-b")
    }

    func testParsesEmptyOutput() {
        let worktrees = WorktreeManager.parseWorktreeListOutput("")
        XCTAssertTrue(worktrees.isEmpty)
    }

    func testParsesBranchWithSlashes() {
        let output = """
        worktree /Users/dev/project
        HEAD abc123
        branch refs/heads/feature/auth/oauth2

        """

        let worktrees = WorktreeManager.parseWorktreeListOutput(output)

        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(worktrees[0].branch, "feature/auth/oauth2")
    }

    // MARK: - Computed Properties

    func testId() {
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature")
        XCTAssertEqual(wt.id, "/tmp/feature")
    }

    func testIdFallsToBranchWhenNoPath() {
        let wt = makeWorktree(branch: "orphan", path: nil)
        XCTAssertEqual(wt.id, "orphan")
    }

    func testDisplayName() {
        XCTAssertEqual(makeWorktree(branch: "feature", path: nil).displayName, "feature")
        XCTAssertEqual(makeWorktree(branch: nil, path: "/tmp/x").displayName, "(detached)")
    }

    // MARK: - Sorting

    func testSortingMainFirst() {
        let worktrees = [
            makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false),
            makeWorktree(branch: "main", path: "/tmp/main", isMain: true),
        ]
        let sorted = Worktree.sorted(worktrees, openIds: worktrees.map(\.id))
        XCTAssertEqual(sorted[0].branch, "main")
        XCTAssertEqual(sorted[1].branch, "feature")
    }

    func testSortingOpenBeforeClosed() {
        let worktrees = [
            makeWorktree(branch: "closed", path: "/tmp/closed", isMain: false),
            makeWorktree(branch: "open", path: "/tmp/open", isMain: false),
        ]
        let sorted = Worktree.sorted(worktrees, openIds: ["/tmp/open"])
        XCTAssertEqual(sorted[0].branch, "open")
        XCTAssertEqual(sorted[1].branch, "closed")
    }

}
