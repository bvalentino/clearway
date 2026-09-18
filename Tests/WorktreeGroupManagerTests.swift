import XCTest
@testable import Clearway

@MainActor
final class WorktreeGroupManagerTests: XCTestCase {

    private var tempRoot: String!
    private var manager: WorktreeGroupManager!

    private var groupsFileExists: Bool {
        FileManager.default.fileExists(
            atPath: (tempRoot as NSString).appendingPathComponent(".clearway/groups.json")
        )
    }

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
        let viaManager = manager.sidebarOrderedWorktrees(worktrees, showingDetached: false, openIds: openIds, matches: { _ in true })

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
            showingDetached: false,
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
            showingDetached: false,
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
            showingDetached: false,
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
            showingDetached: false,
            openIds: [],
            matches: { _ in true }
        )

        // main comes first (Worktree.sorted places main first),
        // then the grouped nonMain worktree.
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, main.id, "main must appear in the default section (first)")
        XCTAssertEqual(result[1].id, nonMain.id, "non-main grouped worktree follows the default section")
    }

    // MARK: - seedDefaultOrder

    /// Seeding records non-main, non-grouped worktrees into `defaultOrder`.
    /// Already-recorded IDs, grouped IDs, and main are untouched.
    func testSeedDefaultOrderAppendsOnlyMissingIds() async throws {
        manager.createGroup(named: "SomeGroup")
        try await Task.sleep(nanoseconds: 150_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let already = makeWorktree(branch: "already", path: "/tmp/already")
        let grouped = makeWorktree(branch: "grouped", path: "/tmp/grouped")
        let fresh = makeWorktree(branch: "fresh", path: "/tmp/fresh")

        // Pre-populate defaultOrder with `already` and move `grouped` into a group.
        manager.setDefaultOrder([already.id])
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.addWorktree(grouped, toGroup: group.id)
        try await Task.sleep(nanoseconds: 150_000_000)

        manager.seedDefaultOrder(with: [main, already, grouped, fresh], openIds: [])
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            manager.defaultOrder,
            [already.id, fresh.id],
            "main and grouped IDs must be skipped; fresh is appended after existing entries"
        )
    }

    /// seedDefaultOrder is a no-op when every candidate is already recorded.
    /// No disk write, no defaultOrder reassignment.
    func testSeedDefaultOrderIsIdempotent() async throws {
        let wt = makeWorktree(branch: "only", path: "/tmp/only")
        manager.setDefaultOrder([wt.id])
        try await Task.sleep(nanoseconds: 150_000_000)

        let before = manager.defaultOrder
        manager.seedDefaultOrder(with: [wt], openIds: [])
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.defaultOrder, before, "defaultOrder must not change when nothing is missing")
    }

    /// Once every non-main worktree is recorded in `defaultOrder`, mutating
    /// `openIds` (click-to-open simulation) must not change the rendered order.
    func testSidebarOrderStableAcrossOpenStateChanges() async throws {
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let wt1 = makeWorktree(branch: "one", path: "/tmp/one")
        let wt2 = makeWorktree(branch: "two", path: "/tmp/two")
        let wt3 = makeWorktree(branch: "three", path: "/tmp/three")
        let worktrees = [main, wt1, wt2, wt3]

        manager.seedDefaultOrder(with: worktrees, openIds: [])
        try await Task.sleep(nanoseconds: 150_000_000)

        let closedOrder = manager.sidebarOrderedWorktrees(worktrees, showingDetached: false, openIds: [], matches: { _ in true })
        let afterOpenLast = manager.sidebarOrderedWorktrees(worktrees, showingDetached: false, openIds: [wt3.id], matches: { _ in true })
        let afterOpenFirst = manager.sidebarOrderedWorktrees(worktrees, showingDetached: false, openIds: [wt1.id], matches: { _ in true })

        XCTAssertEqual(closedOrder.map(\.id), afterOpenLast.map(\.id),
                       "opening the last worktree must not reorder the sidebar")
        XCTAssertEqual(closedOrder.map(\.id), afterOpenFirst.map(\.id),
                       "opening the first worktree must not reorder the sidebar")
    }

    // MARK: - Reordering a filtered subset

    /// A reorder carries only the rows the sidebar rendered. The store never sees why an id was
    /// omitted, so these pin the rule at the store: an omitted id keeps its group and its slot.
    func testSetGroupOrderKeepsIdsAbsentFromTheNewOrder() async throws {
        manager.createGroup(named: "Group")
        try await Task.sleep(nanoseconds: 150_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let first = makeWorktree(branch: "first", path: "/tmp/first")
        let hidden = makeWorktree(branch: nil, path: "/tmp/hidden", headStatus: .detached)
        let last = makeWorktree(branch: "last", path: "/tmp/last")
        for wt in [first, hidden, last] {
            manager.addWorktree(wt, toGroup: group.id)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        manager.setGroupOrder(id: group.id, ids: [last.id, first.id])
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            manager.groups.first?.worktreeIds,
            [last.id, hidden.id, first.id],
            "the omitted id must stay in the group, in its original slot"
        )
    }

    /// Same rule for the ungrouped section's order.
    func testSetDefaultOrderKeepsIdsAbsentFromTheNewOrder() async throws {
        let first = makeWorktree(branch: "first", path: "/tmp/first")
        let hidden = makeWorktree(branch: nil, path: "/tmp/hidden", headStatus: .detached)
        let last = makeWorktree(branch: "last", path: "/tmp/last")

        manager.setDefaultOrder([first.id, hidden.id, last.id])
        try await Task.sleep(nanoseconds: 150_000_000)

        manager.setDefaultOrder([last.id, first.id])
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager.defaultOrder, [last.id, hidden.id, first.id])
    }

    /// An id the store has never seen — a worktree appended at render time and then dragged —
    /// is recorded rather than discarded.
    func testSetDefaultOrderRecordsAnIdItHasNotStored() async throws {
        let stored = makeWorktree(branch: "stored", path: "/tmp/stored")
        let fresh = makeWorktree(branch: "fresh", path: "/tmp/fresh")

        manager.setDefaultOrder([stored.id])
        try await Task.sleep(nanoseconds: 150_000_000)

        manager.setDefaultOrder([fresh.id, stored.id])
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager.defaultOrder, [fresh.id, stored.id])
    }

    /// An externally edited `groups.json` can record the same id twice, which renders the row
    /// twice. A drag must collapse that, not add a third copy.
    func testSetDefaultOrderCollapsesADuplicateStoredId() async throws {
        manager.setDefaultOrder(["/tmp/a", "/tmp/a", "/tmp/b"])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(manager.defaultOrder, ["/tmp/a", "/tmp/a", "/tmp/b"])

        manager.setDefaultOrder(["/tmp/b", "/tmp/a"])
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager.defaultOrder, ["/tmp/b", "/tmp/a"])
    }

    // MARK: - Visibility

    /// `sidebarOrderedWorktrees` applies `Worktree.visible` before ordering, so every
    /// sidebar-ordered list hides the same rows.
    func testSidebarOrderedHidesClosedDetachedWorktreeUnlessShowing() {
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let detached = makeWorktree(branch: nil, path: "/tmp/detached", headStatus: .detached)

        let hiding = manager.sidebarOrderedWorktrees(
            [main, detached],
            showingDetached: false,
            openIds: [],
            matches: { _ in true }
        )
        let showing = manager.sidebarOrderedWorktrees(
            [main, detached],
            showingDetached: true,
            openIds: [],
            matches: { _ in true }
        )

        XCTAssertEqual(hiding.map(\.id), [main.id], "a closed bare-detached worktree must be dropped")
        XCTAssertEqual(showing.map(\.id), [main.id, detached.id], "showingDetached must keep it")
    }

    /// The manager must hand `openIds` to the filter: a detached worktree the user has terminals
    /// open in stays in the rows and in the ⌘1…9 targets even with the toggle off.
    func testSidebarOrderedKeepsOpenDetachedWorktreeWhileHiding() {
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let detached = makeWorktree(branch: nil, path: "/tmp/detached", headStatus: .detached)

        let result = manager.sidebarOrderedWorktrees(
            [main, detached],
            showingDetached: false,
            openIds: [detached.id],
            matches: { _ in true }
        )

        XCTAssertEqual(result.map(\.id), [main.id, detached.id])
    }

    /// The filter runs before the group slices as well as the default one, so a bare-detached
    /// worktree inside a group is hidden on the same terms as an ungrouped one.
    func testSidebarOrderedHidesDetachedWorktreeInsideAGroup() async throws {
        manager.createGroup(named: "Group")
        try await Task.sleep(nanoseconds: 150_000_000)

        guard let group = manager.groups.first else {
            XCTFail("Expected one group")
            return
        }

        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let detached = makeWorktree(branch: nil, path: "/tmp/detached", headStatus: .detached)
        manager.addWorktree(detached, toGroup: group.id)
        try await Task.sleep(nanoseconds: 150_000_000)

        let hiding = manager.sidebarOrderedWorktrees(
            [main, detached],
            showingDetached: false,
            openIds: [],
            matches: { _ in true }
        )
        let showing = manager.sidebarOrderedWorktrees(
            [main, detached],
            showingDetached: true,
            openIds: [],
            matches: { _ in true }
        )

        XCTAssertEqual(hiding.map(\.id), [main.id], "a grouped bare-detached worktree must be dropped too")
        XCTAssertEqual(showing.map(\.id), [main.id, detached.id], "showingDetached must keep it in its group")
    }

    // MARK: - setStatus / status(for:)

    func testSetStatusPublishesAndPersists() async throws {
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature")

        manager.setStatus(.inReview, for: wt)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager.statuses, [wt.id: .inReview])
        XCTAssertEqual(manager.status(for: wt.id), .inReview)

        let reloaded = await WorktreeGroupStore(projectPath: tempRoot).load()
        XCTAssertEqual(reloaded.statuses, [wt.id: .inReview])
    }

    func testSetStatusNilRemovesTheEntryAndPersistsTheRemoval() async throws {
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature")

        manager.setStatus(.done, for: wt)
        try await Task.sleep(nanoseconds: 150_000_000)

        manager.setStatus(nil, for: wt)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNil(manager.status(for: wt.id))
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

        manager.reconcile(knownWorktreeIds: [alive.id])
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
