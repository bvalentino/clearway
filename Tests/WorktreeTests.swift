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

    func testIdFallsBackToPathWhenGitdirMissing() {
        // Non-main worktree at a path that has no .git file: id falls back to the path itself.
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature")
        XCTAssertEqual(wt.id, "/tmp/feature")
    }

    func testIdFallsToBranchWhenNoPath() {
        let wt = makeWorktree(branch: "orphan", path: nil)
        XCTAssertEqual(wt.id, "orphan")
    }

    func testIdForMainWorktreeIsStableSentinel() {
        // Main worktree id is a fixed sentinel, independent of its on-disk path.
        let a = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let b = makeWorktree(branch: "main", path: "/elsewhere/main", isMain: true)
        XCTAssertEqual(a.id, "<main>")
        XCTAssertEqual(a.id, b.id)
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

    func testBranchFromInProgressOpRecognizesRebaseMerge() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("rebase-merge/head-name", contents: "refs/heads/feature-x\n", in: gitdir)
        let result = WorktreeManager.branchFromInProgressOp(gitdir: gitdir.path)
        XCTAssertEqual(result?.branch, "feature-x")
        XCTAssertEqual(result?.status, .rebasing)
    }

    func testBranchFromInProgressOpRecognizesRebaseApply() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("rebase-apply/head-name", contents: "refs/heads/feature-y\n", in: gitdir)
        let result = WorktreeManager.branchFromInProgressOp(gitdir: gitdir.path)
        XCTAssertEqual(result?.branch, "feature-y")
        XCTAssertEqual(result?.status, .rebasing)
    }

    func testBranchFromInProgressOpRecognizesBisect() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("BISECT_START", contents: "feature-z\n", in: gitdir)
        let result = WorktreeManager.branchFromInProgressOp(gitdir: gitdir.path)
        XCTAssertEqual(result?.branch, "feature-z")
        XCTAssertEqual(result?.status, .bisecting)
    }

    func testBranchFromInProgressOpReturnsNilWhenNoState() throws {
        let gitdir = try makeGitdir()
        let result = WorktreeManager.branchFromInProgressOp(gitdir: gitdir.path)
        XCTAssertNil(result)
    }

    func testBranchFromInProgressOpPrefersRebaseMergeOverRebaseApply() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("rebase-merge/head-name", contents: "refs/heads/merge-branch\n", in: gitdir)
        try writeGitdirFile("rebase-apply/head-name", contents: "refs/heads/apply-branch\n", in: gitdir)
        let result = WorktreeManager.branchFromInProgressOp(gitdir: gitdir.path)
        XCTAssertEqual(result?.branch, "merge-branch")
        XCTAssertEqual(result?.status, .rebasing)
    }

    func testBranchFromInProgressOpTrimsTrailingWhitespace() throws {
        let gitdir = try makeGitdir()
        try writeGitdirFile("rebase-merge/head-name", contents: "refs/heads/foo\n\n  ", in: gitdir)
        let result = WorktreeManager.branchFromInProgressOp(gitdir: gitdir.path)
        XCTAssertEqual(result?.branch, "foo")
        XCTAssertEqual(result?.status, .rebasing)
    }

    // MARK: - Resolver Pipeline

    // MARK: - Stable Worktree Id

    /// The headline invariant: a non-main worktree's id is the last component of its
    /// resolved gitdir (the name git itself uses for the worktree under `.git/worktrees/`).
    /// This is what git keeps stable across `git branch -m`, `git worktree move`, and
    /// `git worktree repair` — so the app-side id survives all three.
    func testWorktreeIdIsLastComponentOfGitdirForNonMain() throws {
        let tmp = try XCTUnwrap(tempDir)
        let mainRoot = tmp.appendingPathComponent("main")
        let featureGitdir = mainRoot
            .appendingPathComponent(".git")
            .appendingPathComponent("worktrees")
            .appendingPathComponent("foo")
        try FileManager.default.createDirectory(at: featureGitdir, withIntermediateDirectories: true)

        let featureWt = tmp.appendingPathComponent("feature-wt")
        try FileManager.default.createDirectory(at: featureWt, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: featureWt.appendingPathComponent(".git").path,
            contents: Data("gitdir: \(featureGitdir.path)\n".utf8)
        )

        XCTAssertEqual(WorktreeManager.worktreeId(isMain: false, path: featureWt.path), "foo")
    }

    /// Renaming the worktree directory is exactly what breaks path-based ids. The stable
    /// id must survive — as long as the gitdir it points at is unchanged, the id is the
    /// gitdir's last component.
    func testWorktreeIdSurvivesDirectoryRenameWhenGitdirUnchanged() throws {
        let tmp = try XCTUnwrap(tempDir)
        let mainRoot = tmp.appendingPathComponent("main")
        let featureGitdir = mainRoot
            .appendingPathComponent(".git")
            .appendingPathComponent("worktrees")
            .appendingPathComponent("foo")
        try FileManager.default.createDirectory(at: featureGitdir, withIntermediateDirectories: true)

        let before = tmp.appendingPathComponent("before")
        let after = tmp.appendingPathComponent("after")
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: after, withIntermediateDirectories: true)
        let dotGitContents = Data("gitdir: \(featureGitdir.path)\n".utf8)
        FileManager.default.createFile(atPath: before.appendingPathComponent(".git").path, contents: dotGitContents)
        FileManager.default.createFile(atPath: after.appendingPathComponent(".git").path, contents: dotGitContents)

        let idBefore = WorktreeManager.worktreeId(isMain: false, path: before.path)
        let idAfter = WorktreeManager.worktreeId(isMain: false, path: after.path)
        XCTAssertEqual(idBefore, "foo")
        XCTAssertEqual(idAfter, idBefore)
    }

    func testWorktreeIdFallsBackToPathWhenGitdirUnresolvable() throws {
        let tmp = try XCTUnwrap(tempDir)
        let orphan = tmp.appendingPathComponent("orphan")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        // No .git file present — resolver returns nil and id falls back to the path.
        XCTAssertEqual(WorktreeManager.worktreeId(isMain: false, path: orphan.path), orphan.path)
    }

    func testWorktreeIdForMainHelperReturnsSentinel() {
        XCTAssertEqual(WorktreeManager.worktreeId(isMain: true, path: "/anywhere"), "<main>")
    }

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
}
