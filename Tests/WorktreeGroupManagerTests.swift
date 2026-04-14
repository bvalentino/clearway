import XCTest
@testable import Clearway

@MainActor
final class WorktreeGroupManagerTests: XCTestCase {

    private var tempRoot: String!
    private var manager: WorktreeGroupManager!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-manager-tests-\(UUID().uuidString)")
        manager = WorktreeGroupManager(projectPath: tempRoot)
        // Allow the manager's init Task (store.load + startWatching) to complete before
        // each test body runs. Without this, the background load() can race with early
        // createGroup() calls and overwrite the in-memory groups with [].
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    override func tearDown() async throws {
        manager = nil
        if let root = tempRoot {
            try? FileManager.default.removeItem(atPath: root)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - createGroup / renameGroup / deleteGroup round-trip

    func testCreateGroupAppearsInGroups() async throws {
        manager.createGroup(named: "Alpha")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.groups.count, 1)
        XCTAssertEqual(manager.groups.first?.name, "Alpha")
    }

    func testRenameGroupUpdatesName() async throws {
        manager.createGroup(named: "Original")
        try await Task.sleep(nanoseconds: 100_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group after createGroup")
            return
        }

        manager.renameGroup(id: group.id, to: "Renamed")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.groups.first?.name, "Renamed")
    }

    func testDeleteGroupRemovesIt() async throws {
        manager.createGroup(named: "ToDelete")
        try await Task.sleep(nanoseconds: 100_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group after createGroup")
            return
        }

        manager.deleteGroup(id: group.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(manager.groups.isEmpty)
    }

    func testRoundTripPersistsToDisk() async throws {
        manager.createGroup(named: "Persisted")
        try await Task.sleep(nanoseconds: 150_000_000)

        // Re-load a fresh manager from the same path.
        let manager2 = WorktreeGroupManager(projectPath: tempRoot)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager2.groups.map(\.name), ["Persisted"])
    }

    // MARK: - addWorktree / removeWorktreeFromAllGroups

    func testAddWorktreeToGroupPlacesItInGroup() async throws {
        manager.createGroup(named: "GroupA")
        try await Task.sleep(nanoseconds: 100_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let wt = makeWorktree(branch: "feature-x", path: "/tmp/feature-x")
        manager.addWorktree(wt, toGroup: group.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.groupId(for: wt.id), group.id)
    }

    func testAddWorktreeRemovesFromPreviousGroup() async throws {
        manager.createGroup(named: "GroupA")
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.createGroup(named: "GroupB")
        try await Task.sleep(nanoseconds: 150_000_000)

        let sortedGroups = manager.groups
        XCTAssertEqual(sortedGroups.count, 2)
        let groupA = sortedGroups[0]
        let groupB = sortedGroups[1]

        let wt = makeWorktree(branch: "feature-y", path: "/tmp/feature-y")

        // Add to GroupA first, wait for watcher to settle.
        manager.addWorktree(wt, toGroup: groupA.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(manager.groupId(for: wt.id), groupA.id)

        // Move to GroupB — must no longer appear in GroupA.
        // Extra sleep ensures the first save's watcher callback completes before
        // the second addWorktree mutates groups (same race as reconcile test).
        manager.addWorktree(wt, toGroup: groupB.id)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager.groupId(for: wt.id), groupB.id, "worktree should be in GroupB")
        XCTAssertFalse(
            manager.groups.first(where: { $0.id == groupA.id })?.worktreeIds.contains(wt.id) ?? false,
            "worktree must be removed from GroupA"
        )
    }

    func testAddMainWorktreeIsNoOp() async throws {
        manager.createGroup(named: "SomeGroup")
        try await Task.sleep(nanoseconds: 100_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let mainWt = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        manager.addWorktree(mainWt, toGroup: group.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Post-condition: main is not in any group.
        XCTAssertNil(manager.groupId(for: mainWt.id), "main worktree must never be in any group")
        XCTAssertTrue(
            manager.groups.first?.worktreeIds.isEmpty ?? true,
            "group must remain empty after no-op add of main"
        )
    }

    func testRemoveWorktreeFromAllGroups() async throws {
        manager.createGroup(named: "G1")
        try await Task.sleep(nanoseconds: 100_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let wt = makeWorktree(branch: "branch-rm", path: "/tmp/branch-rm")
        manager.addWorktree(wt, toGroup: group.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.groupId(for: wt.id), group.id)

        manager.removeWorktreeFromAllGroups(wt.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(manager.groupId(for: wt.id))
    }

    // MARK: - groupId(for:)

    func testGroupIdForUngroupedWorktreeIsNil() {
        let wt = makeWorktree(branch: "ungrouped", path: "/tmp/ungrouped")
        XCTAssertNil(manager.groupId(for: wt.id))
    }

    // MARK: - reconcile(knownWorktreeIds:)

    func testReconcileDropsPhantomIds() async throws {
        manager.createGroup(named: "RecGroup")
        try await Task.sleep(nanoseconds: 100_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let alive = makeWorktree(branch: "alive", path: "/tmp/alive")
        let dead = makeWorktree(branch: "dead", path: "/tmp/dead")
        manager.addWorktree(alive, toGroup: group.id)
        // Sleep between adds so the first save's watcher callback settles before
        // the second addWorktree mutates state. Without the sleep the watcher can
        // reload the just-written ["alive"] file and overwrite the in-memory
        // ["alive", "dead"] state (the equality guard doesn't protect against this
        // because the callback sees ["alive"] != ["alive", "dead"]).
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.addWorktree(dead, toGroup: group.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(manager.groups.first?.worktreeIds.count, 2)

        // Reconcile with only the alive worktree known.
        manager.reconcile(knownWorktreeIds: [alive.id])
        try await Task.sleep(nanoseconds: 100_000_000)

        let ids = manager.groups.first?.worktreeIds ?? []
        XCTAssertEqual(ids, [alive.id], "phantom id should be pruned")
    }

    func testReconcileNoOpWhenNoPruningNeeded() async throws {
        manager.createGroup(named: "StableGroup")
        try await Task.sleep(nanoseconds: 100_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let wt = makeWorktree(branch: "stable", path: "/tmp/stable")
        manager.addWorktree(wt, toGroup: group.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        let snapshotGroups = manager.groups

        // Reconcile with the worktree still present — nothing should change.
        manager.reconcile(knownWorktreeIds: [wt.id])

        XCTAssertEqual(manager.groups, snapshotGroups, "groups must be unchanged when no pruning occurs")
    }

    // MARK: - sidebarOrderedWorktrees

    /// No groups → same ordering as Worktree.sorted(_:openIds:) (regression guard).
    func testSidebarOrderedNoGroupsMatchesSortedWorktrees() {
        let wt1 = makeWorktree(branch: "alpha", path: "/tmp/alpha")
        let wt2 = makeWorktree(branch: "beta", path: "/tmp/beta")
        let wt3 = makeWorktree(branch: "gamma", path: "/tmp/gamma")
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let worktrees = [wt1, wt2, main, wt3]
        let openIds: [String] = []

        let direct = Worktree.sorted(worktrees, openIds: openIds)
        let viaManager = manager.sidebarOrderedWorktrees(worktrees, openIds: openIds, matches: { _ in true })

        XCTAssertEqual(viaManager, direct, "with no groups the two orderings must be identical")
    }

    /// Default-section worktrees appear before grouped worktrees.
    func testDefaultSectionAppearsBeforeGroupedWorktrees() async throws {
        manager.createGroup(named: "MyGroup")
        try await Task.sleep(nanoseconds: 100_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let ungrouped = makeWorktree(branch: "ungrouped", path: "/tmp/ungrouped")
        let grouped = makeWorktree(branch: "grouped", path: "/tmp/grouped")
        manager.addWorktree(grouped, toGroup: group.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        let result = manager.sidebarOrderedWorktrees(
            [ungrouped, grouped],
            openIds: [],
            matches: { _ in true }
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, ungrouped.id, "ungrouped worktree must come first")
        XCTAssertEqual(result[1].id, grouped.id, "grouped worktree must come after default section")
    }

    /// Groups appear in createdAt ascending order.
    func testGroupsAppearInCreatedAtAscendingOrder() async throws {
        // Create two groups in order; createdAt is set to Date() inside createGroup.
        // 150ms gap ensures distinct createdAt AND lets the first save's watcher
        // callback settle before the second createGroup fires (same race as elsewhere).
        manager.createGroup(named: "Older")
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.createGroup(named: "Newer")
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager.groups.count, 2)
        let olderGroup = manager.groups[0]
        let newerGroup = manager.groups[1]
        XCTAssertEqual(olderGroup.name, "Older")
        XCTAssertEqual(newerGroup.name, "Newer")

        let wtOlder = makeWorktree(branch: "wt-older", path: "/tmp/wt-older")
        let wtNewer = makeWorktree(branch: "wt-newer", path: "/tmp/wt-newer")
        manager.addWorktree(wtOlder, toGroup: olderGroup.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.addWorktree(wtNewer, toGroup: newerGroup.id)
        try await Task.sleep(nanoseconds: 150_000_000)

        let result = manager.sidebarOrderedWorktrees(
            [wtNewer, wtOlder],
            openIds: [],
            matches: { _ in true }
        )

        // First comes the default section (empty here), then older group, then newer group.
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, wtOlder.id, "older group's worktree must appear first")
        XCTAssertEqual(result[1].id, wtNewer.id, "newer group's worktree must appear second")
    }

    /// Search term filters within each section; empty sections contribute nothing.
    func testSearchFilterAppliesWithinSectionsAndDropsEmptySections() async throws {
        manager.createGroup(named: "FilterGroup")
        try await Task.sleep(nanoseconds: 100_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let fooUngrouped = makeWorktree(branch: "foo-ungrouped", path: "/tmp/foo-ungrouped")
        let barUngrouped = makeWorktree(branch: "bar-ungrouped", path: "/tmp/bar-ungrouped")
        let fooGrouped = makeWorktree(branch: "foo-grouped", path: "/tmp/foo-grouped")
        let barGrouped = makeWorktree(branch: "bar-grouped", path: "/tmp/bar-grouped")

        manager.addWorktree(fooGrouped, toGroup: group.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.addWorktree(barGrouped, toGroup: group.id)
        try await Task.sleep(nanoseconds: 150_000_000)

        let all = [fooUngrouped, barUngrouped, fooGrouped, barGrouped]

        // Filter to only "foo" matches.
        let result = manager.sidebarOrderedWorktrees(
            all,
            openIds: [],
            matches: { $0.displayName.contains("foo") }
        )

        XCTAssertEqual(result.count, 2, "only foo-* worktrees should survive the filter")
        let ids = result.map(\.id)
        XCTAssertTrue(ids.contains(fooUngrouped.id))
        XCTAssertTrue(ids.contains(fooGrouped.id))
        XCTAssertFalse(ids.contains(barUngrouped.id), "bar-ungrouped must be filtered out")
        XCTAssertFalse(ids.contains(barGrouped.id), "bar-grouped must be filtered out")
    }

    /// main always lands in the default section regardless of addWorktree attempts.
    func testMainAlwaysInDefaultSection() async throws {
        manager.createGroup(named: "AGroup")
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.createGroup(named: "BGroup")
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager.groups.count, 2)
        let groupA = manager.groups[0]
        let groupB = manager.groups[1]

        let nonMain = makeWorktree(branch: "non-main", path: "/tmp/non-main")
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)

        // Add non-main to groupA; attempt to add main to groupB (should be a no-op).
        // Sleep between the two calls so the first save's watcher callback settles
        // before the second addWorktree (see reconcile test for full explanation).
        manager.addWorktree(nonMain, toGroup: groupA.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.addWorktree(main, toGroup: groupB.id) // silent no-op
        try await Task.sleep(nanoseconds: 150_000_000)

        let result = manager.sidebarOrderedWorktrees(
            [nonMain, main],
            openIds: [],
            matches: { _ in true }
        )

        // main comes first (Worktree.sorted places main first),
        // then the grouped nonMain worktree.
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, main.id, "main must appear in the default section (first)")
        XCTAssertEqual(result[1].id, nonMain.id, "non-main grouped worktree follows the default section")
    }
}
