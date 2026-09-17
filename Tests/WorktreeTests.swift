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

    // MARK: - Visibility

    private func makeDetached(path: String, isMain: Bool = false) -> Worktree {
        makeWorktree(branch: nil, path: path, isMain: isMain, headStatus: .detached)
    }

    func testVisibilityHidesClosedDetachedWorktree() {
        let visible = Worktree.visible(
            [makeDetached(path: "/tmp/detached")],
            showingDetached: false,
            openIds: []
        )
        XCTAssertTrue(visible.isEmpty)
    }

    func testVisibilityKeepsRebasingWorktree() {
        let rebasing = makeWorktree(branch: "feature", path: "/tmp/rebasing", headStatus: .rebasing)
        let visible = Worktree.visible([rebasing], showingDetached: false, openIds: [])
        XCTAssertEqual(visible.map(\.id), ["/tmp/rebasing"])
    }

    func testVisibilityKeepsBisectingWorktree() {
        let bisecting = makeWorktree(branch: "feature", path: "/tmp/bisecting", headStatus: .bisecting)
        let visible = Worktree.visible([bisecting], showingDetached: false, openIds: [])
        XCTAssertEqual(visible.map(\.id), ["/tmp/bisecting"])
    }

    func testVisibilityKeepsWorktreeWithOperationInProgress() {
        let inProgress = makeWorktree(branch: nil, path: "/tmp/cherry-picking", headStatus: .inProgress)
        let visible = Worktree.visible([inProgress], showingDetached: false, openIds: [])
        XCTAssertEqual(visible.map(\.id), ["/tmp/cherry-picking"])
    }

    func testVisibilityKeepsOpenDetachedWorktree() {
        let visible = Worktree.visible(
            [makeDetached(path: "/tmp/detached")],
            showingDetached: false,
            openIds: ["/tmp/detached"]
        )
        XCTAssertEqual(visible.map(\.id), ["/tmp/detached"])
    }

    func testVisibilityKeepsDetachedMainWorktree() {
        let visible = Worktree.visible(
            [makeDetached(path: "/tmp/main", isMain: true)],
            showingDetached: false,
            openIds: []
        )
        XCTAssertEqual(visible.map(\.id), ["/tmp/main"])
    }

    /// Every case above passes a one-element list, so none of them asks the filter to keep and
    /// drop within a single call.
    func testVisibilityKeepsEveryExemptShapeInOneCall() {
        let worktrees = [
            makeDetached(path: "/tmp/main", isMain: true),
            makeDetached(path: "/tmp/open"),
            makeDetached(path: "/tmp/stray"),
            makeWorktree(branch: "rebasing", path: "/tmp/rebasing", headStatus: .rebasing),
            makeWorktree(branch: "bisecting", path: "/tmp/bisecting", headStatus: .bisecting),
            makeWorktree(branch: "feature", path: "/tmp/feature"),
        ]

        let visible = Worktree.visible(worktrees, showingDetached: false, openIds: ["/tmp/open"])

        XCTAssertEqual(
            visible.map(\.id),
            ["/tmp/main", "/tmp/open", "/tmp/rebasing", "/tmp/bisecting", "/tmp/feature"],
            "only the closed non-main bare-detached worktree is dropped, and order is preserved"
        )
    }

    func testVisibilityPassesWholeListThroughWhenShowingDetached() {
        let worktrees = [
            makeDetached(path: "/tmp/detached"),
            makeWorktree(branch: "main", path: "/tmp/main", isMain: true),
            makeWorktree(branch: "feature", path: "/tmp/feature"),
        ]
        let visible = Worktree.visible(worktrees, showingDetached: true, openIds: [])
        XCTAssertEqual(visible.map(\.id), ["/tmp/detached", "/tmp/main", "/tmp/feature"])
    }

    // MARK: - Gitdir Resolver

    var tempDir: URL?

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    override func tearDown() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        super.tearDown()
    }

    func testGitdirReturnsDirectoryPathForMainWorktree() throws {
        let tmp = try XCTUnwrap(tempDir)
        let dotGit = tmp.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
        XCTAssertEqual(WorktreeManager.gitdir(forWorktreeAt: tmp.path), dotGit.path)
    }

    func testGitdirResolvesAbsoluteGitdirFile() throws {
        let tmp = try XCTUnwrap(tempDir)
        let dotGit = tmp.appendingPathComponent(".git")
        let contents = "gitdir: /absolute/path/to/gitdir\n"
        FileManager.default.createFile(atPath: dotGit.path, contents: contents.data(using: .utf8))
        XCTAssertEqual(WorktreeManager.gitdir(forWorktreeAt: tmp.path), "/absolute/path/to/gitdir")
    }

    func testGitdirResolvesRelativeGitdirFile() throws {
        let tmp = try XCTUnwrap(tempDir)
        let linked = tmp.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        let contents = "gitdir: ../main/.git/worktrees/x\n"
        FileManager.default.createFile(
            atPath: linked.appendingPathComponent(".git").path,
            contents: contents.data(using: .utf8)
        )
        let linkedDir = URL(fileURLWithPath: linked.path, isDirectory: true)
        let expected = URL(fileURLWithPath: "../main/.git/worktrees/x", relativeTo: linkedDir)
            .standardizedFileURL.path
        XCTAssertEqual(WorktreeManager.gitdir(forWorktreeAt: linked.path), expected)
    }

    // MARK: - In-Progress Op Probe

    private func makeGitdir() throws -> URL {
        let dir = try XCTUnwrap(tempDir).appendingPathComponent("gitdir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeGitdirFile(_ relativePath: String, contents: String, in gitdir: URL) throws {
        let target = gitdir.appendingPathComponent(relativePath)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: contents.data(using: .utf8))
    }

    func testInProgressOpRecognizesRebaseMerge() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("rebase-merge/head-name", contents: "refs/heads/feature-x\n", in: gitdir)
        let op = try XCTUnwrap(WorktreeManager.inProgressOp(gitdir: gitdir.path))
        XCTAssertEqual(op.branch, "feature-x")
        XCTAssertEqual(op.status, .rebasing)
    }

    func testInProgressOpRecognizesRebaseApply() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("rebase-apply/head-name", contents: "refs/heads/feature-y\n", in: gitdir)
        let op = try XCTUnwrap(WorktreeManager.inProgressOp(gitdir: gitdir.path))
        XCTAssertEqual(op.branch, "feature-y")
        XCTAssertEqual(op.status, .rebasing)
    }

    func testInProgressOpRecognizesBisect() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("BISECT_START", contents: "feature-z\n", in: gitdir)
        let op = try XCTUnwrap(WorktreeManager.inProgressOp(gitdir: gitdir.path))
        XCTAssertEqual(op.branch, "feature-z")
        XCTAssertEqual(op.status, .bisecting)
    }

    func testInProgressOpRecognizesGitAm() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("rebase-apply/applying", contents: "", in: gitdir)
        let op = try XCTUnwrap(WorktreeManager.inProgressOp(gitdir: gitdir.path))
        XCTAssertNil(op.branch)
        XCTAssertEqual(op.status, .inProgress)
    }

    func testInProgressOpRecognizesMerge() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("MERGE_HEAD", contents: "abc123\n", in: gitdir)
        let op = try XCTUnwrap(WorktreeManager.inProgressOp(gitdir: gitdir.path))
        XCTAssertNil(op.branch)
        XCTAssertEqual(op.status, .inProgress)
    }

    func testInProgressOpRecognizesCherryPick() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("CHERRY_PICK_HEAD", contents: "abc123\n", in: gitdir)
        let op = try XCTUnwrap(WorktreeManager.inProgressOp(gitdir: gitdir.path))
        XCTAssertNil(op.branch)
        XCTAssertEqual(op.status, .inProgress)
    }

    func testInProgressOpRecognizesRevert() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("REVERT_HEAD", contents: "abc123\n", in: gitdir)
        let op = try XCTUnwrap(WorktreeManager.inProgressOp(gitdir: gitdir.path))
        XCTAssertNil(op.branch)
        XCTAssertEqual(op.status, .inProgress)
    }

    func testInProgressOpReturnsNilWhenNoState() throws {
        let gitdir = try makeGitdir()
        XCTAssertNil(WorktreeManager.inProgressOp(gitdir: gitdir.path))
    }

    func testInProgressOpPrefersRebaseMergeOverRebaseApply() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("rebase-merge/head-name", contents: "refs/heads/merge-branch\n", in: gitdir)
        try writeGitdirFile("rebase-apply/head-name", contents: "refs/heads/apply-branch\n", in: gitdir)
        let op = try XCTUnwrap(WorktreeManager.inProgressOp(gitdir: gitdir.path))
        XCTAssertEqual(op.branch, "merge-branch")
        XCTAssertEqual(op.status, .rebasing)
    }

    /// An interactive rebase stopped on a conflict leaves CHERRY_PICK_HEAD next to the rebase
    /// state, and `git status` reports the rebase. The recovered branch name must survive.
    func testInProgressOpPrefersRebaseOverCherryPick() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("rebase-merge/head-name", contents: "refs/heads/feature-r\n", in: gitdir)
        try writeGitdirFile("CHERRY_PICK_HEAD", contents: "abc123\n", in: gitdir)
        let op = try XCTUnwrap(WorktreeManager.inProgressOp(gitdir: gitdir.path))
        XCTAssertEqual(op.branch, "feature-r")
        XCTAssertEqual(op.status, .rebasing)
    }

    func testInProgressOpTrimsTrailingWhitespace() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("rebase-merge/head-name", contents: "refs/heads/foo\n\n  ", in: gitdir)
        let op = try XCTUnwrap(WorktreeManager.inProgressOp(gitdir: gitdir.path))
        XCTAssertEqual(op.branch, "foo")
        XCTAssertEqual(op.status, .rebasing)
    }

    // MARK: - Resolver Pipeline

    func testParserAndResolverPipelineRecoversRebasingBranch() throws {
        let tmp = try XCTUnwrap(tempDir)

        // 1. Create <tmp>/main/ — the main worktree root
        let mainRoot = tmp.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: mainRoot, withIntermediateDirectories: true)

        // 2. Create <tmp>/main/.git/worktrees/feature/ — the linked gitdir
        let mainGitdir = mainRoot
            .appendingPathComponent(".git")
            .appendingPathComponent("worktrees")
            .appendingPathComponent("feature")
        try FileManager.default.createDirectory(at: mainGitdir, withIntermediateDirectories: true)

        // 3. Create <tmp>/main/.git/worktrees/feature/rebase-merge/ and head-name
        let rebaseMergeDir = mainGitdir.appendingPathComponent("rebase-merge")
        try FileManager.default.createDirectory(at: rebaseMergeDir, withIntermediateDirectories: true)
        let headNameFile = rebaseMergeDir.appendingPathComponent("head-name")
        let headNameContents = "refs/heads/feature\n"
        FileManager.default.createFile(
            atPath: headNameFile.path,
            contents: headNameContents.data(using: .utf8)
        )

        // 4. Create <tmp>/feature-wt/ — the linked worktree root
        let featureWt = tmp.appendingPathComponent("feature-wt")
        try FileManager.default.createDirectory(at: featureWt, withIntermediateDirectories: true)

        // 5. Write <tmp>/feature-wt/.git pointing to the linked gitdir (absolute path)
        let dotGitFile = featureWt.appendingPathComponent(".git")
        let dotGitContents = "gitdir: \(mainGitdir.path)\n"
        FileManager.default.createFile(
            atPath: dotGitFile.path,
            contents: dotGitContents.data(using: .utf8)
        )

        // 6. Build porcelain output referencing the real temp paths
        let output = """
        worktree \(mainRoot.path)
        HEAD abc123
        branch refs/heads/main

        worktree \(featureWt.path)
        HEAD def456
        detached

        """

        // 7. Run the parser + resolver pipeline
        let parsed = WorktreeManager.parseWorktreeListOutput(output)
        let resolved = WorktreeManager.applyHeadResolution(to: parsed)

        // 8. Assertions
        XCTAssertEqual(resolved.count, 2)

        XCTAssertEqual(resolved[0].branch, "main")
        XCTAssertEqual(resolved[0].headStatus, .attached)

        XCTAssertEqual(resolved[1].branch, "feature")
        XCTAssertEqual(resolved[1].headStatus, .rebasing)
        XCTAssertEqual(resolved[1].path, featureWt.path)
        XCTAssertFalse(resolved[1].isMain)
    }

    func testParserAndResolverPipelineMarksCherryPickingWorktreeInProgress() throws {
        let tmp = try XCTUnwrap(tempDir)

        let mainRoot = tmp.appendingPathComponent("main")
        let linkedGitdir = mainRoot
            .appendingPathComponent(".git")
            .appendingPathComponent("worktrees")
            .appendingPathComponent("picked")
        try FileManager.default.createDirectory(at: linkedGitdir, withIntermediateDirectories: true)
        try writeGitdirFile("CHERRY_PICK_HEAD", contents: "abc123\n", in: linkedGitdir)

        let pickedWt = tmp.appendingPathComponent("picked-wt")
        try FileManager.default.createDirectory(at: pickedWt, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: pickedWt.appendingPathComponent(".git").path,
            contents: Data("gitdir: \(linkedGitdir.path)\n".utf8)
        )

        let output = """
        worktree \(mainRoot.path)
        HEAD abc123
        branch refs/heads/main

        worktree \(pickedWt.path)
        HEAD def456
        detached

        """

        let resolved = WorktreeManager.applyHeadResolution(
            to: WorktreeManager.parseWorktreeListOutput(output)
        )

        XCTAssertEqual(resolved.count, 2)
        XCTAssertNil(resolved[1].branch)
        XCTAssertEqual(resolved[1].displayName, "(detached)")
        XCTAssertEqual(resolved[1].headStatus, .inProgress)
        XCTAssertEqual(
            Worktree.visible([resolved[1]], showingDetached: false, openIds: []).map(\.id),
            [pickedWt.path],
            "a worktree with a cherry-pick in progress is never hidden"
        )
    }
}
