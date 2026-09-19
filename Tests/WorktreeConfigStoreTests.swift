import XCTest
@testable import Clearway

/// The pure half: argument building and `--list --null` parsing, pinned without a repository.
final class WorktreeConfigArgumentTests: XCTestCase {

    func testListArgs() {
        XCTAssertEqual(
            WorktreeConfigStore.listArgs(worktreePath: "/repo/.worktrees/a"),
            ["git", "-C", "/repo/.worktrees/a", "config", "--worktree", "--list", "--null"]
        )
    }

    func testSetArgs() {
        XCTAssertEqual(
            WorktreeConfigStore.setArgs(worktreePath: "/repo/.worktrees/a", key: "clearway.name", value: "My Name"),
            ["git", "-C", "/repo/.worktrees/a", "config", "--worktree", "clearway.name", "My Name"]
        )
    }

    func testUnsetArgs() {
        XCTAssertEqual(
            WorktreeConfigStore.unsetArgs(worktreePath: "/repo/.worktrees/a", key: "clearway.status"),
            ["git", "-C", "/repo/.worktrees/a", "config", "--worktree", "--unset", "clearway.status"]
        )
    }

    func testParseListSingleRecord() {
        XCTAssertEqual(
            WorktreeConfigStore.parseList("clearway.name\nMy Name\0"),
            ["clearway.name": "My Name"]
        )
    }

    func testParseListTwoRecords() {
        XCTAssertEqual(
            WorktreeConfigStore.parseList("clearway.name\nMy Name\0clearway.status\ninProgress\0"),
            ["clearway.name": "My Name", "clearway.status": "inProgress"]
        )
    }

    /// Only the first newline separates key from value, which is the whole reason for `--null`.
    func testParseListKeepsNewlinesInsideAValue() {
        XCTAssertEqual(
            WorktreeConfigStore.parseList("clearway.name\nline1\nline2\0"),
            ["clearway.name": "line1\nline2"]
        )
    }

    /// `git worktree add` seeds this into every new worktree's `config.worktree`.
    func testParseListDropsNonClearwayKeys() {
        XCTAssertEqual(
            WorktreeConfigStore.parseList("core.bare\nfalse\0clearway.name\nMy Name\0"),
            ["clearway.name": "My Name"]
        )
    }

    func testParseListEmptyInput() {
        XCTAssertEqual(WorktreeConfigStore.parseList(""), [:])
    }

    /// No `-C`: a repo-level command reaches the shared `.git/config` from any worktree.
    func testLocalGetArgs() {
        XCTAssertEqual(
            WorktreeConfigStore.localGetArgs(key: "clearway.grouping"),
            ["git", "config", "--local", "--get", "--null", "clearway.grouping"]
        )
    }

    func testLocalGetAllArgs() {
        XCTAssertEqual(
            WorktreeConfigStore.localGetAllArgs(key: "clearway.groupOrder"),
            ["git", "config", "--local", "--get-all", "--null", "clearway.groupOrder"]
        )
    }

    func testLocalSetArgs() {
        XCTAssertEqual(
            WorktreeConfigStore.localSetArgs(key: "clearway.grouping", value: "status"),
            ["git", "config", "--local", "clearway.grouping", "status"]
        )
    }

    func testLocalAddArgs() {
        XCTAssertEqual(
            WorktreeConfigStore.localAddArgs(key: "clearway.groupOrder", value: "Backlog"),
            ["git", "config", "--local", "--add", "clearway.groupOrder", "Backlog"]
        )
    }

    func testLocalUnsetAllArgs() {
        XCTAssertEqual(
            WorktreeConfigStore.localUnsetAllArgs(key: "clearway.groupOrder"),
            ["git", "config", "--local", "--unset-all", "clearway.groupOrder"]
        )
    }

    /// The final NUL terminates the last value rather than introducing an empty one, and nothing
    /// splits on newlines — a group name is user text and may contain either.
    func testParseNullSeparatedKeepsNewlinesAndDropsTheTerminator() {
        XCTAssertEqual(WorktreeConfigStore.parseNullSeparated("a\nb\0c\0"), ["a\nb", "c"])
    }

    func testParseNullSeparatedEmptyInput() {
        XCTAssertEqual(WorktreeConfigStore.parseNullSeparated(""), [])
    }

    func testParseNullSeparatedSingleEmptyValue() {
        XCTAssertEqual(WorktreeConfigStore.parseNullSeparated("\0"), [""])
    }
}

/// The integration half: a real repository per test, under the scratch root.
@MainActor
final class WorktreeConfigStoreTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-config-tests" }

    private var repo: GitRepoFixture!
    private var store: WorktreeConfigStore!

    override func setUp() async throws {
        try await super.setUp()
        repo = try GitRepoFixture.make(at: tempRoot)
        store = WorktreeConfigStore(projectPath: repo.root)
    }

    override func tearDown() async throws {
        store = nil
        repo = nil
        try await super.tearDown()
    }

    // MARK: - Extension bootstrap

    func testFirstWriteEnablesTheExtensionAndMovesCoreBare() async throws {
        let worktree = try repo.addWorktree(branch: "feature")

        let stored = await store.set("My Name", forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)

        XCTAssertTrue(stored)
        XCTAssertEqual(try repo.value(ofLocalKey: "extensions.worktreeConfig"), "true")
        XCTAssertNil(try repo.value(ofLocalKey: "core.bare"))
        XCTAssertTrue(try repo.mainWorktreeConfigContents().contains("bare = false"))

        XCTAssertTrue(try repo.statusSucceeds(in: repo.root))
        XCTAssertTrue(try repo.statusSucceeds(in: worktree))
    }

    /// The bootstrap moves two keys, and a plain `git init` only ever has one of them. A repo
    /// created with `--separate-git-dir` carries `core.worktree`, and leaving that behind in
    /// `$GIT_DIR/config` is the state git-worktree(1) says breaks the repository.
    func testFirstWriteAlsoMovesCoreWorktree() async throws {
        try GitRepoFixture.git(["config", "--local", "core.worktree", repo.root], in: repo.root)
        let worktree = try repo.addWorktree(branch: "feature")

        await store.set("My Name", forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)

        XCTAssertNil(try repo.value(ofLocalKey: "core.worktree"))
        XCTAssertTrue(try repo.mainWorktreeConfigContents().contains("worktree = "))
        XCTAssertTrue(try repo.statusSucceeds(in: repo.root))
        XCTAssertTrue(try repo.statusSucceeds(in: worktree))
    }

    // MARK: - Round trip and isolation

    func testNameAndStatusRoundTripAndDoNotLeakToASibling() async throws {
        let feature = try repo.addWorktree(branch: "feature")
        await store.set("My Name", forKey: WorktreeConfigStore.nameKey, worktreeAt: feature)
        await store.set("inProgress", forKey: WorktreeConfigStore.statusKey, worktreeAt: feature)

        // Added after the extension is on, so git seeds core.bare into its config.worktree too.
        let sibling = try repo.addWorktree(branch: "other")

        let read = await store.values(forWorktreeAt: feature)
        let values = try XCTUnwrap(read)
        XCTAssertEqual(values[WorktreeConfigStore.nameKey], "My Name")
        XCTAssertEqual(values[WorktreeConfigStore.statusKey], "inProgress")
        XCTAssertNil(values["core.bare"])

        let readSibling = await store.values(forWorktreeAt: sibling)
        let siblingValues = try XCTUnwrap(readSibling)
        XCTAssertEqual(siblingValues, [:])
        XCTAssertNil(try repo.value(ofKey: WorktreeConfigStore.nameKey, atWorktree: sibling))
        XCTAssertEqual(try repo.value(ofKey: WorktreeConfigStore.nameKey, atWorktree: feature), "My Name")
    }

    /// A worktree Clearway has never written to has no `config.worktree` at all, and git answers
    /// `--list` with exit 128 rather than with empty output. That refusal is still an answer —
    /// "stores nothing" — and must not be reported as a read that could not be performed, which
    /// would leave the worktree showing whatever the sidebar already had.
    func testAWorktreeWithNoConfigWorktreeReadsAsEmptyRatherThanUnknown() async throws {
        let worktree = try repo.addWorktree(branch: "feature")
        try repo.enableWorktreeConfig()

        let read = await store.values(forWorktreeAt: worktree)
        let values = try XCTUnwrap(read)

        XCTAssertEqual(values, [:])
    }

    // MARK: - Clearing

    func testClearingOneKeyLeavesTheOtherIntact() async throws {
        let worktree = try repo.addWorktree(branch: "feature")
        await store.set("My Name", forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)
        await store.set("done", forKey: WorktreeConfigStore.statusKey, worktreeAt: worktree)

        let cleared = await store.set(nil, forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)

        XCTAssertTrue(cleared)
        let read = await store.values(forWorktreeAt: worktree)
        let values = try XCTUnwrap(read)
        XCTAssertNil(values[WorktreeConfigStore.nameKey])
        XCTAssertEqual(values[WorktreeConfigStore.statusKey], "done")
    }

    func testClearingAKeyThatWasNeverWrittenIsNotAnError() async throws {
        let worktree = try repo.addWorktree(branch: "feature")
        await store.set("done", forKey: WorktreeConfigStore.statusKey, worktreeAt: worktree)

        let clearedNil = await store.set(nil, forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)
        let clearedEmpty = await store.set("", forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)

        // git exits 5 on an unset with nothing to remove, which is the state asked for and so is
        // reported as stored — the distinction the migration relies on to keep `groups.json`.
        XCTAssertTrue(clearedNil)
        XCTAssertTrue(clearedEmpty)
        let read = await store.values(forWorktreeAt: worktree)
        let values = try XCTUnwrap(read)
        XCTAssertEqual(values, [WorktreeConfigStore.statusKey: "done"])
    }

    // MARK: - Removal

    func testRemovingAWorktreeTakesItsConfigWithIt() async throws {
        let worktree = try repo.addWorktree(branch: "feature")
        await store.set("My Name", forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)
        XCTAssertEqual(try repo.value(ofKey: WorktreeConfigStore.nameKey, atWorktree: worktree), "My Name")

        try repo.removeWorktree(at: worktree)

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (repo.root as NSString).appendingPathComponent(".git/worktrees/feature")
            ),
            "the worktree's config.worktree should have gone with it — nothing prunes it"
        )
        let read = await store.values(forWorktreeAt: worktree)
        let values = try XCTUnwrap(read)
        XCTAssertEqual(values, [:])
    }

    // MARK: - Extension off

    /// Nothing has ever been written here, so the extension is off and a read costs no process
    /// rather than falling back to `--local` and reporting the repository's `core.*` keys.
    func testReadingWithTheExtensionOffReturnsNothing() async throws {
        let worktree = try repo.addWorktree(branch: "feature")

        let read = await store.values(forWorktreeAt: worktree)
        let values = try XCTUnwrap(read)

        XCTAssertEqual(values, [:])
        XCTAssertNil(try repo.value(ofLocalKey: "extensions.worktreeConfig"))
    }

    /// Clearing is the other read-shaped path: with the extension off no `clearway.*` value can
    /// exist, so the unset has nothing to remove and the bootstrap would move `core.bare` into a
    /// `config.worktree` the project never asked for.
    func testClearingWithTheExtensionOffLeavesTheConfigUntouched() async throws {
        let worktree = try repo.addWorktree(branch: "feature")

        await store.set(nil, forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)

        XCTAssertNil(try repo.value(ofLocalKey: "extensions.worktreeConfig"))
        XCTAssertEqual(try repo.value(ofLocalKey: "core.bare"), "false")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (repo.root as NSString).appendingPathComponent(".git/config.worktree")
            ),
            "no config.worktree should have been created"
        )
    }

    // MARK: - Repo scope

    func testTheRegistryRoundTripsInOrder() async throws {
        let written = await store.replaceLocalValues(["one", "two"], forKey: WorktreeConfigStore.groupOrderKey)

        XCTAssertTrue(written)
        let read = await store.localValues(forKey: WorktreeConfigStore.groupOrderKey)
        XCTAssertEqual(read, ["one", "two"])
    }

    /// The whole-registry rewrite: what was there is gone, not merged with what replaces it.
    func testRewritingTheRegistryReplacesEveryValue() async throws {
        await store.replaceLocalValues(["one", "two"], forKey: WorktreeConfigStore.groupOrderKey)

        await store.replaceLocalValues(["two"], forKey: WorktreeConfigStore.groupOrderKey)

        let read = await store.localValues(forKey: WorktreeConfigStore.groupOrderKey)
        XCTAssertEqual(read, ["two"])
    }

    /// A group name is arbitrary user text. This is why the rewrite is `--unset-all` plus one
    /// `--add` per value rather than `--replace-all` with a value-regex, which would need the name
    /// escaped into a POSIX ERE.
    func testAValueCarryingRegexMetacharactersOrSpacesRoundTripsUnharmed() async throws {
        let names = ["a.*b[0]", "has space", "two\nlines"]

        await store.replaceLocalValues(names, forKey: WorktreeConfigStore.groupOrderKey)

        let read = await store.localValues(forKey: WorktreeConfigStore.groupOrderKey)
        XCTAssertEqual(read, names)
    }

    func testEmptyValuesLeaveTheRegistryUnset() async throws {
        await store.replaceLocalValues(["one"], forKey: WorktreeConfigStore.groupOrderKey)

        let written = await store.replaceLocalValues([], forKey: WorktreeConfigStore.groupOrderKey)

        XCTAssertTrue(written)
        let read = await store.localValues(forKey: WorktreeConfigStore.groupOrderKey)
        XCTAssertEqual(read, [])
    }

    func testTheGroupingModeRoundTripsAndClears() async throws {
        let written = await store.setLocal("status", forKey: WorktreeConfigStore.groupingKey)
        XCTAssertTrue(written)
        let stored = await store.localValue(forKey: WorktreeConfigStore.groupingKey)
        XCTAssertEqual(stored, "status")

        let cleared = await store.setLocal(nil, forKey: WorktreeConfigStore.groupingKey)
        let clearedAgain = await store.setLocal(nil, forKey: WorktreeConfigStore.groupingKey)

        // git exits 5 on an unset with nothing to remove, which is the state asked for.
        XCTAssertTrue(cleared)
        XCTAssertTrue(clearedAgain)
        let read = await store.localValue(forKey: WorktreeConfigStore.groupingKey)
        XCTAssertNil(read)
    }

    /// `--local` reaches the main repository's `.git/config` from a linked worktree, so one
    /// process reads the registry for the whole project wherever `projectPath` points.
    func testTheRegistryIsSharedWithEveryLinkedWorktree() async throws {
        let worktree = try repo.addWorktree(branch: "feature")
        await store.replaceLocalValues(["Backlog"], forKey: WorktreeConfigStore.groupOrderKey)

        let contents = try String(
            contentsOfFile: (repo.root as NSString).appendingPathComponent(".git/config"),
            encoding: .utf8
        )
        XCTAssertTrue(contents.contains("Backlog"))

        let fromWorktree = WorktreeConfigStore(projectPath: worktree)
        let read = await fromWorktree.localValues(forKey: WorktreeConfigStore.groupOrderKey)
        XCTAssertEqual(read, ["Backlog"])
    }

    // MARK: - Repo scope, extension off

    /// The gate is what makes "a project where the extension cannot be enabled shows no groups"
    /// one rule rather than two: the values are on disk and are still not reported.
    func testRepoScopeReadsWithTheExtensionOffReturnNothingWithoutReadingTheValues() async throws {
        try GitRepoFixture.git(
            ["config", "--local", "--add", WorktreeConfigStore.groupOrderKey, "Backlog"],
            in: repo.root
        )
        try GitRepoFixture.git(
            ["config", "--local", WorktreeConfigStore.groupingKey, "status"],
            in: repo.root
        )

        let order = await store.localValues(forKey: WorktreeConfigStore.groupOrderKey)
        let grouping = await store.localValue(forKey: WorktreeConfigStore.groupingKey)

        XCTAssertEqual(order, [])
        XCTAssertNil(grouping)
        XCTAssertNil(try repo.value(ofLocalKey: "extensions.worktreeConfig"))
    }

    func testTheFirstRegistryWriteEnablesTheExtension() async throws {
        let written = await store.replaceLocalValues(["Backlog"], forKey: WorktreeConfigStore.groupOrderKey)

        XCTAssertTrue(written)
        XCTAssertEqual(try repo.value(ofLocalKey: "extensions.worktreeConfig"), "true")
        XCTAssertNil(try repo.value(ofLocalKey: "core.bare"))
        XCTAssertTrue(try repo.mainWorktreeConfigContents().contains("bare = false"))
        let read = await store.localValues(forKey: WorktreeConfigStore.groupOrderKey)
        XCTAssertEqual(read, ["Backlog"])
    }
}
