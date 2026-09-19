import XCTest
@testable import Clearway

/// Names are backed by each worktree's own git config, so every case here runs against a real
/// repository and reads the stored value back with `git config --worktree --get`.
final class WorktreeGroupManagerNameTests: WorktreeGroupManagerGitTestCase {

    // MARK: - setName

    func testSetNamePublishesImmediatelyAndWritesTheConfig() async throws {
        let path = try repo.addWorktree(branch: "feature")
        let wt = makeWorktree(branch: "feature", path: path)

        manager.setName("Login rewrite", for: wt)

        XCTAssertEqual(manager.name(for: wt), "Login rewrite", "the sidebar must not wait on git")
        try await waitForStoredName("Login rewrite", at: path)
    }

    func testSetNameNilClearsThePublishedEntryAndTheStoredKey() async throws {
        let path = try repo.addWorktree(branch: "feature")
        let wt = makeWorktree(branch: "feature", path: path)
        manager.setName("Login rewrite", for: wt)
        try await waitForStoredName("Login rewrite", at: path)

        manager.setName(nil, for: wt)

        XCTAssertNil(manager.name(for: wt))
        try await waitForStoredName(nil, at: path)
    }

    func testSetNameWhitespaceOnlyClearsThePublishedEntryAndTheStoredKey() async throws {
        let path = try repo.addWorktree(branch: "feature")
        let wt = makeWorktree(branch: "feature", path: path)
        manager.setName("Login rewrite", for: wt)
        try await waitForStoredName("Login rewrite", at: path)

        manager.setName("   ", for: wt)

        XCTAssertNil(manager.name(for: wt))
        try await waitForStoredName(nil, at: path)
    }

    func testSetNameIgnoresTheMainWorktree() async throws {
        let main = makeWorktree(branch: "main", path: repo.root, isMain: true)

        manager.setName("Main", for: main)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(manager.names.isEmpty)
        XCTAssertNil(manager.name(for: main))
        XCTAssertFalse(
            try repo.localConfigContents().contains("worktreeConfig"),
            "a main-worktree name must not even bootstrap the extension"
        )
    }

    // MARK: - reconcile

    func testReconcilePopulatesNamesFromConfigAndDropsAClearedOne() async throws {
        let path = try repo.addWorktree(branch: "feature")
        try repo.enableWorktreeConfig()
        try repo.setValue("Stored name", ofKey: WorktreeConfigStore.nameKey, atWorktree: path)
        let wt = makeWorktree(branch: "feature", path: path)

        manager.reconcile([wt])
        try await waitForPublishedName("Stored name", for: wt)

        try repo.unsetValue(ofKey: WorktreeConfigStore.nameKey, atWorktree: path)
        manager.reconcile([wt])
        try await waitForPublishedName(nil, for: wt)
    }

    /// The one place a name is normalised: a hand-written config value that is whitespace only
    /// never reaches `names`, which is what lets `name(for:)` and the sidebar row trust the map.
    func testReconcileDropsAWhitespaceOnlyStoredName() async throws {
        let path = try repo.addWorktree(branch: "feature")
        try repo.enableWorktreeConfig()
        try repo.setValue("   ", ofKey: WorktreeConfigStore.nameKey, atWorktree: path)
        let wt = makeWorktree(branch: "feature", path: path)

        manager.reconcile([wt])

        try await waitForPublishedName(nil, for: wt)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(manager.names.isEmpty)
    }

    /// Creating a worktree writes a name *and* changes the live worktree list, which fires the
    /// reload in the same turn. Without the manager's write chain the reload reads the config
    /// before the write lands and publishes an empty name over the one just typed.
    func testReconcileRightAfterSetNameDoesNotRaceTheWrite() async throws {
        let path = try repo.addWorktree(branch: "feature")
        let wt = makeWorktree(branch: "feature", path: path)

        manager.setName("Fresh name", for: wt)
        manager.reconcile([wt])

        try await waitForStoredName("Fresh name", at: path)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(manager.name(for: wt), "Fresh name")
    }

    // MARK: - matches

    func testMatchesStoredName() async throws {
        let path = try repo.addWorktree(branch: "feature-x")
        let wt = makeWorktree(branch: "feature-x", path: path)

        manager.setName("Login rewrite", for: wt)

        XCTAssertTrue(manager.matches(wt, query: "rewrite", taskTitle: nil))
        XCTAssertTrue(manager.matches(wt, query: "LOGIN", taskTitle: nil))
        XCTAssertFalse(manager.matches(wt, query: "logout", taskTitle: nil))
    }

    // MARK: - Helpers

    private func waitForStoredName(
        _ expected: String?,
        at path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitForStoredValue(
            expected,
            ofKey: WorktreeConfigStore.nameKey,
            at: path,
            file: file,
            line: line
        )
    }

    private func waitForPublishedName(
        _ expected: String?,
        for wt: Worktree,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitFor(
            expected,
            describing: "published name for \(wt.id)",
            file: file,
            line: line
        ) {
            self.manager.name(for: wt)
        }
    }
}
