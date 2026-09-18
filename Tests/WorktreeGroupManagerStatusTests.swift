import XCTest
@testable import Clearway

final class WorktreeGroupManagerStatusTests: WorktreeGroupManagerTestCase {

    // MARK: - setStatus / status(for:)

    func testSetStatusPublishesAndPersists() async throws {
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature")

        manager.setStatus(.inReview, for: wt)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager.statuses, [wt.id: .inReview])
        XCTAssertEqual(manager.status(for: wt), .inReview)

        let reloaded = await WorktreeGroupStore(projectPath: tempRoot).load()
        XCTAssertEqual(reloaded.statuses, [wt.id: .inReview])
    }

    func testSetStatusNilRemovesTheEntryAndPersistsTheRemoval() async throws {
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature")

        manager.setStatus(.done, for: wt)
        try await Task.sleep(nanoseconds: 150_000_000)

        manager.setStatus(nil, for: wt)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNil(manager.status(for: wt))
        let reloaded = await WorktreeGroupStore(projectPath: tempRoot).load()
        XCTAssertEqual(reloaded.statuses, [:])
    }

    func testSetStatusIgnoresTheMainWorktree() async throws {
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)

        manager.setStatus(.todo, for: main)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(manager.statuses.isEmpty)
        XCTAssertFalse(groupsFileExists, "a main-worktree status must write nothing")
    }

    /// `setStatus` is not the only way an entry lands in `statuses`: `groups.json` is a plain
    /// file the app reloads live, and nothing prunes main's id from it. Honouring one would
    /// drop main out of the top of the by-status order with no badge or menu to explain it.
    func testStatusStoredAgainstMainIsIgnoredOnTheReadPath() async throws {
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let alpha = makeWorktree(branch: "alpha", path: "/tmp/alpha")
        try await writeGroupsFile(statuses: [main.id: .done], grouping: .status)

        let reopened = try await reopenedManager()

        XCTAssertNil(reopened.status(for: main))
        XCTAssertFalse(reopened.matches(main, query: "done", taskTitle: nil))
        let ordered = reopened.sidebarOrderedWorktrees(
            [main, alpha],
            showingDetached: false,
            openIds: [],
            matches: { _ in true }
        )
        XCTAssertEqual(
            ordered.map(\.id),
            [main.id, alpha.id],
            "main stays ahead of the no-status bucket instead of sinking into Done"
        )
    }

    // MARK: - Loading what was persisted

    /// The one thing `setStatus`/`setGrouping`'s own round-trip tests cannot see: without the
    /// two assignments in `init`, a relaunch opens with no statuses and `.group`, and the next
    /// save — `seedDefaultOrder` on the first worktree refresh — writes that over the file.
    func testInitLoadsStatusesAndGrouping() async throws {
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature")
        try await writeGroupsFile(statuses: [wt.id: .onHold], grouping: .status)

        let reopened = try await reopenedManager()

        XCTAssertEqual(reopened.statuses, [wt.id: .onHold])
        XCTAssertEqual(reopened.grouping, .status)
    }

    /// Criterion 7's external-edit half, at the manager rather than the store: the watcher
    /// fires and the reloaded statuses and grouping are republished.
    func testExternalWriteRepublishesStatusesAndGrouping() async throws {
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature")

        try await writeGroupsFile(statuses: [wt.id: .inProgress], grouping: .none)

        let deadline = Date().addingTimeInterval(5)
        while manager.statuses.isEmpty || manager.grouping == .group, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(manager.statuses, [wt.id: .inProgress])
        XCTAssertEqual(manager.grouping, .none)
    }

    private func writeGroupsFile(
        statuses: [String: WorktreeStatus],
        grouping: WorktreeGrouping
    ) async throws {
        try await WorktreeGroupStore(projectPath: tempRoot).save(
            WorktreeGroupsPayload(groups: [], defaultOrder: [], statuses: statuses, grouping: grouping)
        )
    }

    /// A second manager over the same root, standing in for a relaunch.
    private func reopenedManager() async throws -> WorktreeGroupManager {
        let reopened = WorktreeGroupManager(projectPath: tempRoot)
        try await Task.sleep(nanoseconds: 150_000_000)
        return reopened
    }

    // MARK: - setGrouping

    func testSetGroupingPublishesAndPersists() async throws {
        manager.setGrouping(.status)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager.grouping, .status)
        let reloaded = await WorktreeGroupStore(projectPath: tempRoot).load()
        XCTAssertEqual(reloaded.grouping, .status)
    }

    func testSetGroupingToTheCurrentValueWritesNothing() async throws {
        manager.setGrouping(.group)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(groupsFileExists, "an unchanged grouping must not save")
    }

    // MARK: - reconcile prunes statuses

    func testReconcileDropsStatusesOfAbsentWorktrees() async throws {
        let alive = makeWorktree(branch: "alive", path: "/tmp/alive")
        let dead = makeWorktree(branch: "dead", path: "/tmp/dead")

        manager.setStatus(.todo, for: alive)
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.setStatus(.onHold, for: dead)
        try await Task.sleep(nanoseconds: 150_000_000)

        manager.reconcile([alive])
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager.statuses, [alive.id: .todo])
        let reloaded = await WorktreeGroupStore(projectPath: tempRoot).load()
        XCTAssertEqual(
            reloaded.statuses,
            [alive.id: .todo],
            "a reconcile whose only change is a status prune must still persist"
        )
    }

    // MARK: - sidebarOrderedWorktrees per grouping

    /// `.none` renders the base order under one header, so it must return exactly what
    /// `.group` returns — the view mode changes the sections, never the list.
    func testNoneGroupingReturnsTheSameOrderAsGroup() async throws {
        manager.createGroup(named: "G")
        try await Task.sleep(nanoseconds: 150_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let alpha = makeWorktree(branch: "alpha", path: "/tmp/alpha")
        let bravo = makeWorktree(branch: "bravo", path: "/tmp/bravo")
        let charlie = makeWorktree(branch: "charlie", path: "/tmp/charlie")
        manager.addWorktree(charlie, toGroup: group.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.setStatus(.done, for: alpha)
        try await Task.sleep(nanoseconds: 150_000_000)

        let all = [main, alpha, bravo, charlie]
        let grouped = manager.sidebarOrderedWorktrees(
            all,
            showingDetached: false,
            openIds: [],
            matches: { _ in true }
        )
        manager.setGrouping(.none)
        try await Task.sleep(nanoseconds: 150_000_000)
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
    func testStatusGroupingStablyPartitionsTheBaseOrder() async throws {
        manager.createGroup(named: "G")
        try await Task.sleep(nanoseconds: 150_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let alpha = makeWorktree(branch: "alpha", path: "/tmp/alpha")
        let bravo = makeWorktree(branch: "bravo", path: "/tmp/bravo")
        let charlie = makeWorktree(branch: "charlie", path: "/tmp/charlie")
        let delta = makeWorktree(branch: "delta", path: "/tmp/delta")
        manager.addWorktree(charlie, toGroup: group.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.addWorktree(delta, toGroup: group.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.setStatus(.done, for: alpha)
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.setStatus(.todo, for: bravo)
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.setStatus(.done, for: charlie)
        try await Task.sleep(nanoseconds: 150_000_000)

        let all = [main, alpha, bravo, charlie, delta]
        let base = manager.sidebarOrderedWorktrees(
            all,
            showingDetached: false,
            openIds: [],
            matches: { _ in true }
        )
        manager.setGrouping(.status)
        try await Task.sleep(nanoseconds: 150_000_000)
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
    func testStatusGroupingAppliesVisibilityFirst() async throws {
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let closed = makeWorktree(branch: "closed", path: "/tmp/closed")
        let detached = makeWorktree(branch: nil, path: "/tmp/detached", headStatus: .detached)
        manager.setDefaultOrder([detached.id, closed.id])
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.setStatus(.todo, for: closed)
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.setGrouping(.status)
        try await Task.sleep(nanoseconds: 150_000_000)

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

    func testMatchesContainingGroupName() async throws {
        manager.createGroup(named: "Backend")
        try await Task.sleep(nanoseconds: 150_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let wt = makeWorktree(branch: "feature-x", path: "/tmp/feature-x")
        manager.addWorktree(wt, toGroup: group.id)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(manager.matches(wt, query: "backend", taskTitle: nil))
    }

    func testMatchesStatusDisplayName() async throws {
        let wt = makeWorktree(branch: "feature-x", path: "/tmp/feature-x")
        manager.setStatus(.inReview, for: wt)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(manager.matches(wt, query: "review", taskTitle: nil))
        XCTAssertFalse(manager.matches(wt, query: "hold", taskTitle: nil))
    }
}
