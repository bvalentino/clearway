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

        await store.set("My Name", forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)

        let localConfig = try repo.localConfigContents()
        XCTAssertTrue(localConfig.contains("worktreeConfig = true"), localConfig)
        XCTAssertFalse(localConfig.contains("bare ="), localConfig)
        XCTAssertTrue(try repo.mainWorktreeConfigContents().contains("bare = false"))

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

        let values = await store.values(forWorktreeAt: feature)
        XCTAssertEqual(values[WorktreeConfigStore.nameKey], "My Name")
        XCTAssertEqual(values[WorktreeConfigStore.statusKey], "inProgress")
        XCTAssertNil(values["core.bare"])

        let siblingValues = await store.values(forWorktreeAt: sibling)
        XCTAssertEqual(siblingValues, [:])
        XCTAssertNil(try repo.value(ofKey: WorktreeConfigStore.nameKey, atWorktree: sibling))
        XCTAssertEqual(try repo.value(ofKey: WorktreeConfigStore.nameKey, atWorktree: feature), "My Name")
    }

    // MARK: - Clearing

    func testClearingOneKeyLeavesTheOtherIntact() async throws {
        let worktree = try repo.addWorktree(branch: "feature")
        await store.set("My Name", forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)
        await store.set("done", forKey: WorktreeConfigStore.statusKey, worktreeAt: worktree)

        await store.set(nil, forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)

        let values = await store.values(forWorktreeAt: worktree)
        XCTAssertNil(values[WorktreeConfigStore.nameKey])
        XCTAssertEqual(values[WorktreeConfigStore.statusKey], "done")
    }

    func testClearingAKeyThatWasNeverWrittenIsNotAnError() async throws {
        let worktree = try repo.addWorktree(branch: "feature")
        await store.set("done", forKey: WorktreeConfigStore.statusKey, worktreeAt: worktree)

        await store.set(nil, forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)
        await store.set("", forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)

        let values = await store.values(forWorktreeAt: worktree)
        XCTAssertEqual(values, [WorktreeConfigStore.statusKey: "done"])
    }

    // MARK: - Removal

    func testRemovingAWorktreeTakesItsConfigWithIt() async throws {
        let worktree = try repo.addWorktree(branch: "feature")
        await store.set("My Name", forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)
        XCTAssertEqual(try repo.value(ofKey: WorktreeConfigStore.nameKey, atWorktree: worktree), "My Name")

        try repo.removeWorktree(at: worktree)

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        let values = await store.values(forWorktreeAt: worktree)
        XCTAssertEqual(values, [:])
    }

    // MARK: - Extension off

    /// Nothing has ever been written here, so the extension is off and a read costs no process
    /// rather than falling back to `--local` and reporting the repository's `core.*` keys.
    func testReadingWithTheExtensionOffReturnsNothing() async throws {
        let worktree = try repo.addWorktree(branch: "feature")

        let values = await store.values(forWorktreeAt: worktree)

        XCTAssertEqual(values, [:])
        XCTAssertFalse(try repo.localConfigContents().contains("worktreeConfig"))
    }

    /// Clearing is the other read-shaped path: with the extension off no `clearway.*` value can
    /// exist, so the unset has nothing to remove and the bootstrap would move `core.bare` into a
    /// `config.worktree` the project never asked for.
    func testClearingWithTheExtensionOffLeavesTheConfigUntouched() async throws {
        let worktree = try repo.addWorktree(branch: "feature")

        await store.set(nil, forKey: WorktreeConfigStore.nameKey, worktreeAt: worktree)

        let localConfig = try repo.localConfigContents()
        XCTAssertFalse(localConfig.contains("worktreeConfig"), localConfig)
        XCTAssertTrue(localConfig.contains("bare = false"), localConfig)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (repo.root as NSString).appendingPathComponent(".git/config.worktree")
            ),
            "no config.worktree should have been created"
        )
    }
}
