import XCTest
@testable import Clearway

/// Statuses are backed by each worktree's own git config, so every case that asserts on stored
/// state runs against a real repository and reads the value back with `git config --worktree`.
/// The ordering cases below set a status only to partition a list, so they keep synthetic paths.
final class WorktreeGroupManagerStatusTests: WorktreeGroupManagerGitTestCase {

    // MARK: - setStatus / status(for:)

    func testSetStatusPublishesAndPersistsToWorktreeConfig() async throws {
        let path = try repo.addWorktree(branch: "feature")
        let wt = makeWorktree(branch: "feature", path: path)

        manager.setStatus(.inReview, for: wt)

        XCTAssertEqual(manager.statuses, [wt.id: .inReview], "the sidebar must not wait on git")
        XCTAssertEqual(manager.status(for: wt), .inReview)
        try await waitForStoredStatus(.inReview, at: path)
    }

    func testSetStatusNilClearsThePublishedEntryAndTheStoredKey() async throws {
        let path = try repo.addWorktree(branch: "feature")
        let wt = makeWorktree(branch: "feature", path: path)
        manager.setStatus(.done, for: wt)
        try await waitForStoredStatus(.done, at: path)

        manager.setStatus(nil, for: wt)

        XCTAssertNil(manager.status(for: wt))
        try await waitForStoredStatus(nil, at: path)
    }

    func testSetStatusIgnoresTheMainWorktree() async throws {
        let main = makeWorktree(branch: "main", path: repo.root, isMain: true)

        manager.setStatus(.todo, for: main)
        await settle()

        XCTAssertTrue(manager.statuses.isEmpty)
        XCTAssertNil(
            try repo.value(ofLocalKey: "extensions.worktreeConfig"),
            "a main-worktree status must not even bootstrap the extension"
        )
    }

    /// `setStatus` refuses main, but `config.worktree` is hand-editable, so a status can still
    /// reach `statuses` under main's id. The read path has to refuse it too, or main drops out of
    /// the top of the by-status order and `⌘1` moves with it. Driven through two `Worktree` values
    /// over one path, since `Worktree.id` is the path and nothing else can seed that entry.
    func testAStatusStoredAgainstMainsIdIsIgnoredOnTheReadPath() {
        let mainPath = "/tmp/main"
        manager.setStatus(.done, for: makeWorktree(branch: "main", path: mainPath))

        let main = makeWorktree(branch: "main", path: mainPath, isMain: true)
        let alpha = makeWorktree(branch: "alpha", path: "/tmp/alpha")
        manager.setStatus(.todo, for: alpha)
        manager.setGrouping(.status)

        XCTAssertEqual(manager.statuses[main.id], .done, "the seed landed under main's id")
        XCTAssertNil(manager.status(for: main))
        XCTAssertEqual(
            manager.sidebarOrderedWorktrees(
                [main, alpha],
                showingDetached: false,
                openIds: [],
                matches: { _ in true }
            ).map(\.id),
            [main.id, alpha.id],
            "main stays first; honouring its stored `.done` would sort it behind alpha's `.todo`"
        )
    }

    // MARK: - reconcile reads statuses instead of pruning them

    func testReconcilePopulatesStatusesFromWorktreeConfig() async throws {
        let path = try repo.addWorktree(branch: "alive")
        try repo.enableWorktreeConfig()
        try repo.setValue(
            WorktreeStatus.inReview.rawValue,
            ofKey: WorktreeConfigStore.statusKey,
            atWorktree: path
        )
        let alive = makeWorktree(branch: "alive", path: path)
        await restartManager()

        manager.reconcile([alive], openIds: [])

        try await waitForPublishedStatuses([alive.id: .inReview])
    }

    /// `config.worktree` is hand-editable and a slug rename is a format change, so an
    /// unrecognised status is dropped — and must not take the name stored beside it with it.
    func testReconcileDropsAnUnrecognisedStatusSlugAndKeepsTheName() async throws {
        let path = try repo.addWorktree(branch: "alive")
        try repo.enableWorktreeConfig()
        try repo.setValue("bogus", ofKey: WorktreeConfigStore.statusKey, atWorktree: path)
        try repo.setValue("Stored name", ofKey: WorktreeConfigStore.nameKey, atWorktree: path)
        let alive = makeWorktree(branch: "alive", path: path)
        await restartManager()

        manager.reconcile([alive], openIds: [])

        try await waitFor("Stored name" as String?, describing: "published name for \(alive.id)") {
            self.manager.name(for: alive)
        }
        XCTAssertTrue(manager.statuses.isEmpty)
    }

    /// A status whose worktree has gone leaves the published map because the reload rebuilds it
    /// from the live list, not because `reconcile` prunes it.
    func testReconcileDropsAnAbsentWorktree() async throws {
        let alivePath = try repo.addWorktree(branch: "alive")
        let deadPath = try repo.addWorktree(branch: "dead")
        let alive = makeWorktree(branch: "alive", path: alivePath)
        let dead = makeWorktree(branch: "dead", path: deadPath)

        manager.setStatus(.todo, for: alive)
        manager.setStatus(.onHold, for: dead)
        try await waitForStoredStatus(.onHold, at: deadPath)

        manager.reconcile([alive], openIds: [])

        try await waitForPublishedStatuses([alive.id: .todo])
    }

    // MARK: - sidebarOrderedWorktrees per grouping

    /// `.none` renders the base order under one header, so it must return exactly what
    /// `.group` returns — the view mode changes the sections, never the list.
    func testNoneGroupingReturnsTheSameOrderAsGroup() {
        manager.createGroup(named: "G")

        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let alpha = makeWorktree(branch: "alpha", path: "/tmp/alpha")
        let bravo = makeWorktree(branch: "bravo", path: "/tmp/bravo")
        let charlie = makeWorktree(branch: "charlie", path: "/tmp/charlie")
        manager.addWorktree(charlie, toGroupNamed: "G")
        manager.setStatus(.done, for: alpha)

        let all = [main, alpha, bravo, charlie]
        let grouped = manager.sidebarOrderedWorktrees(
            all,
            showingDetached: false,
            openIds: [],
            matches: { _ in true }
        )
        manager.setGrouping(.none)
        let none = manager.sidebarOrderedWorktrees(
            all,
            showingDetached: false,
            openIds: [],
            matches: { _ in true }
        )

        XCTAssertEqual(grouped.map(\.id), [main.id, alpha.id, bravo.id, charlie.id])
        XCTAssertEqual(none, grouped, "`.none` must not reorder the base list")
    }

    /// `.status` is a stable partition of the base order: no status first, then the five
    /// statuses in `allCases` order, each bucket keeping its members' `.group` relative order.
    func testStatusGroupingStablyPartitionsTheBaseOrder() {
        manager.createGroup(named: "G")

        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let alpha = makeWorktree(branch: "alpha", path: "/tmp/alpha")
        let bravo = makeWorktree(branch: "bravo", path: "/tmp/bravo")
        let charlie = makeWorktree(branch: "charlie", path: "/tmp/charlie")
        let delta = makeWorktree(branch: "delta", path: "/tmp/delta")
        manager.addWorktree(charlie, toGroupNamed: "G")
        manager.addWorktree(delta, toGroupNamed: "G")
        manager.setStatus(.done, for: alpha)
        manager.setStatus(.todo, for: bravo)
        manager.setStatus(.done, for: charlie)

        let all = [main, alpha, bravo, charlie, delta]
        let base = manager.sidebarOrderedWorktrees(
            all,
            showingDetached: false,
            openIds: [],
            matches: { _ in true }
        )
        manager.setGrouping(.status)
        let byStatus = manager.sidebarOrderedWorktrees(
            all,
            showingDetached: false,
            openIds: [],
            matches: { _ in true }
        )

        XCTAssertEqual(base.map(\.id), [main.id, alpha.id, bravo.id, charlie.id, delta.id])
        XCTAssertEqual(
            byStatus.map(\.id),
            [main.id, delta.id, bravo.id, alpha.id, charlie.id],
            "no status first, then todo, then done; alpha keeps its place ahead of charlie"
        )
        XCTAssertEqual(Set(byStatus.map(\.id)), Set(base.map(\.id)), "no worktree lost")
        XCTAssertEqual(byStatus.count, base.count, "no worktree duplicated")
    }

    /// The partition runs after `Worktree.visible`, so the detached rule is inherited by
    /// `.status` without restating it.
    func testStatusGroupingAppliesVisibilityFirst() {
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let closed = makeWorktree(branch: "closed", path: "/tmp/closed")
        let detached = makeWorktree(branch: nil, path: "/tmp/detached", headStatus: .detached)
        manager.setUngroupedOrder([detached.id, closed.id], in: [detached, closed], openIds: [])
        manager.setStatus(.todo, for: closed)
        manager.setGrouping(.status)

        let all = [main, closed, detached]
        let hiding = manager.sidebarOrderedWorktrees(
            all,
            showingDetached: false,
            openIds: [],
            matches: { _ in true }
        )
        let showing = manager.sidebarOrderedWorktrees(
            all,
            showingDetached: true,
            openIds: [],
            matches: { _ in true }
        )

        XCTAssertEqual(hiding.map(\.id), [main.id, closed.id],
                       "the bare-detached worktree is hidden; a closed one still appears")
        XCTAssertEqual(showing.map(\.id), [main.id, detached.id, closed.id],
                       "showingDetached keeps it, in the no-status bucket")
    }

    // MARK: - matches(_:query:taskTitle:)

    func testMatchesEmptyQueryMatchesEverything() {
        let wt = makeWorktree(branch: "feature-x", path: "/tmp/feature-x")

        XCTAssertTrue(manager.matches(wt, query: "", taskTitle: nil))
        XCTAssertTrue(manager.matches(wt, query: "   ", taskTitle: nil))
    }

    func testMatchesBranchNameAndTaskTitle() {
        let wt = makeWorktree(branch: "feature-x", path: "/tmp/feature-x")

        XCTAssertTrue(manager.matches(wt, query: "EATURE", taskTitle: nil))
        XCTAssertTrue(manager.matches(wt, query: "rewrite", taskTitle: "Rewrite the parser"))
        XCTAssertFalse(manager.matches(wt, query: "nothing", taskTitle: "Rewrite the parser"))
    }

    func testMatchesContainingGroupName() {
        manager.createGroup(named: "Backend")

        let wt = makeWorktree(branch: "feature-x", path: "/tmp/feature-x")
        manager.addWorktree(wt, toGroupNamed: "Backend")

        XCTAssertTrue(manager.matches(wt, query: "backend", taskTitle: nil))
    }

    func testMatchesStatusDisplayName() {
        let wt = makeWorktree(branch: "feature-x", path: "/tmp/feature-x")
        manager.setStatus(.inReview, for: wt)

        XCTAssertTrue(manager.matches(wt, query: "review", taskTitle: nil))
        XCTAssertFalse(manager.matches(wt, query: "hold", taskTitle: nil))
    }

    // MARK: - Helpers

    private func waitForStoredStatus(
        _ expected: WorktreeStatus?,
        at path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitForStoredValue(
            expected?.rawValue,
            ofKey: WorktreeConfigStore.statusKey,
            at: path,
            file: file,
            line: line
        )
    }

    private func waitForPublishedStatuses(
        _ expected: [String: WorktreeStatus],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitFor(expected, describing: "published statuses", file: file, line: line) {
            self.manager.statuses
        }
    }
}
