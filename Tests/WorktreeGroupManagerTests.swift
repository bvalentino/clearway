import XCTest
@testable import Clearway

final class WorktreeGroupManagerTests: WorktreeGroupManagerGitTestCase {

    // MARK: - createGroup / renameGroup / deleteGroup round-trip

    func testCreateGroupAppearsInGroups() async throws {
        manager.createGroup(named: "Alpha")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.groups.count, 1)
        XCTAssertEqual(manager.groups.first?.name, "Alpha")
    }

    /// A group is identified by its name, so `createGroup` refuses what would make a name-keyed
    /// lookup ambiguous rather than leaving the caller to check.
    func testCreateGroupRefusesADuplicateOrEmptyName() async throws {
        manager.createGroup(named: "Backlog")
        try await Task.sleep(nanoseconds: 100_000_000)
        manager.createGroup(named: "Backlog")
        try await Task.sleep(nanoseconds: 100_000_000)
        manager.createGroup(named: "  ")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.groups.map(\.name), ["Backlog"])
    }

    func testRenameGroupUpdatesName() async throws {
        manager.createGroup(named: "Original")
        try await Task.sleep(nanoseconds: 100_000_000)

        manager.renameGroup(named: "Original", to: "Renamed")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.groups.first?.name, "Renamed")
    }

    func testDeleteGroupRemovesIt() async throws {
        manager.createGroup(named: "ToDelete")
        try await Task.sleep(nanoseconds: 100_000_000)

        manager.deleteGroup(named: "ToDelete")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(manager.groups.isEmpty)
    }

    // MARK: - addWorktree / removeWorktreeFromGroup

    func testAddWorktreeToGroupPlacesItInGroup() async throws {
        manager.createGroup(named: "GroupA")
        try await Task.sleep(nanoseconds: 100_000_000)

        let wt = makeWorktree(branch: "feature-x", path: "/tmp/feature-x")
        manager.addWorktree(wt, toGroupNamed: "GroupA")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.groupName(for: wt.id), "GroupA")
    }

    func testAddWorktreeRemovesFromPreviousGroup() async throws {
        manager.createGroup(named: "GroupA")
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.createGroup(named: "GroupB")
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(manager.groups.map(\.name), ["GroupA", "GroupB"])

        let wt = makeWorktree(branch: "feature-y", path: "/tmp/feature-y")

        // Add to GroupA first, wait for watcher to settle.
        manager.addWorktree(wt, toGroupNamed: "GroupA")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(manager.groupName(for: wt.id), "GroupA")

        // Move to GroupB — must no longer appear in GroupA.
        // Extra sleep ensures the first save's watcher callback completes before
        // the second addWorktree mutates groups (same race as reconcile test).
        manager.addWorktree(wt, toGroupNamed: "GroupB")
        try await Task.sleep(nanoseconds: 150_000_000)

        // `groupName` answers with the first group holding the id, so GroupB is also the proof
        // that the move removed it from GroupA.
        XCTAssertEqual(manager.groupName(for: wt.id), "GroupB")
    }

    func testAddMainWorktreeIsNoOp() async throws {
        manager.createGroup(named: "SomeGroup")
        try await Task.sleep(nanoseconds: 100_000_000)

        let mainWt = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        manager.addWorktree(mainWt, toGroupNamed: "SomeGroup")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(manager.groupName(for: mainWt.id), "main worktree must never be in any group")
    }

    func testRemoveWorktreeFromGroup() async throws {
        manager.createGroup(named: "G1")
        try await Task.sleep(nanoseconds: 100_000_000)

        let wt = makeWorktree(branch: "branch-rm", path: "/tmp/branch-rm")
        manager.addWorktree(wt, toGroupNamed: "G1")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.groupName(for: wt.id), "G1")

        manager.removeWorktreeFromGroup(wt)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(manager.groupName(for: wt.id))
    }

    // MARK: - groupName(for:)

    func testGroupNameForUngroupedWorktreeIsNil() {
        let wt = makeWorktree(branch: "ungrouped", path: "/tmp/ungrouped")
        XCTAssertNil(manager.groupName(for: wt.id))
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

        let ungrouped = makeWorktree(branch: "ungrouped", path: "/tmp/ungrouped")
        let grouped = makeWorktree(branch: "grouped", path: "/tmp/grouped")
        manager.addWorktree(grouped, toGroupNamed: "MyGroup")
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

        XCTAssertEqual(manager.groups.map(\.name), ["Older", "Newer"])

        let wtOlder = makeWorktree(branch: "wt-older", path: "/tmp/wt-older")
        let wtNewer = makeWorktree(branch: "wt-newer", path: "/tmp/wt-newer")
        manager.addWorktree(wtOlder, toGroupNamed: "Older")
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.addWorktree(wtNewer, toGroupNamed: "Newer")
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

        let fooUngrouped = makeWorktree(branch: "foo-ungrouped", path: "/tmp/foo-ungrouped")
        let barUngrouped = makeWorktree(branch: "bar-ungrouped", path: "/tmp/bar-ungrouped")
        let fooGrouped = makeWorktree(branch: "foo-grouped", path: "/tmp/foo-grouped")
        let barGrouped = makeWorktree(branch: "bar-grouped", path: "/tmp/bar-grouped")

        manager.addWorktree(fooGrouped, toGroupNamed: "FilterGroup")
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.addWorktree(barGrouped, toGroupNamed: "FilterGroup")
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

        XCTAssertEqual(manager.groups.map(\.name), ["AGroup", "BGroup"])

        let nonMain = makeWorktree(branch: "non-main", path: "/tmp/non-main")
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)

        // Add non-main to AGroup; attempt to add main to BGroup (should be a no-op).
        // Sleep between the two calls so the first save's watcher callback settles
        // before the second addWorktree (see reconcile test for full explanation).
        manager.addWorktree(nonMain, toGroupNamed: "AGroup")
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.addWorktree(main, toGroupNamed: "BGroup") // silent no-op
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

    /// Seeding records non-main, ungrouped worktrees in the ungrouped section's order.
    /// Already-recorded IDs, grouped IDs, and main are untouched. `zebra` is recorded first and
    /// sorts last alphabetically, so an order that re-sorted rather than appended would put
    /// `fresh` ahead of it.
    func testSeedDefaultOrderAppendsOnlyMissingIds() async throws {
        manager.createGroup(named: "SomeGroup")
        try await Task.sleep(nanoseconds: 150_000_000)

        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let already = makeWorktree(branch: "zebra", path: "/tmp/zebra")
        let grouped = makeWorktree(branch: "grouped", path: "/tmp/grouped")
        let fresh = makeWorktree(branch: "fresh", path: "/tmp/fresh")

        manager.setUngroupedOrder([already.id])
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.addWorktree(grouped, toGroupNamed: "SomeGroup")
        try await Task.sleep(nanoseconds: 150_000_000)

        manager.seedDefaultOrder(with: [main, already, grouped, fresh], openIds: [])
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            renderedOrder([main, already, grouped, fresh]),
            [main.id, already.id, fresh.id, grouped.id],
            "main stays pinned, fresh is appended after the recorded id, and grouped keeps its section"
        )
    }

    /// seedDefaultOrder is a no-op when every candidate is already recorded: nothing is reordered
    /// and nothing is recorded twice.
    func testSeedDefaultOrderIsIdempotent() async throws {
        let zulu = makeWorktree(branch: "zulu", path: "/tmp/zulu")
        let alpha = makeWorktree(branch: "alpha", path: "/tmp/alpha")
        manager.setUngroupedOrder([zulu.id, alpha.id])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(renderedOrder([zulu, alpha]), [zulu.id, alpha.id])

        manager.seedDefaultOrder(with: [zulu, alpha], openIds: [])
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(renderedOrder([zulu, alpha]), [zulu.id, alpha.id])
    }

    /// Once every non-main worktree is recorded in the ungrouped order, mutating
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

    /// A reorder carries only the rows the sidebar rendered. The manager never sees why an id
    /// was omitted, so these pin the rule: an omitted id keeps its group and its slot.
    func testSetGroupOrderKeepsIdsAbsentFromTheNewOrder() async throws {
        manager.createGroup(named: "Group")
        try await Task.sleep(nanoseconds: 150_000_000)

        let first = makeWorktree(branch: "first", path: "/tmp/first")
        let hidden = makeWorktree(branch: nil, path: "/tmp/hidden", headStatus: .detached)
        let last = makeWorktree(branch: "last", path: "/tmp/last")
        for wt in [first, hidden, last] {
            manager.addWorktree(wt, toGroupNamed: "Group")
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        manager.setGroupOrder(named: "Group", ids: [last.id, first.id])
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            renderedOrder([first, hidden, last], showingDetached: true),
            [last.id, hidden.id, first.id],
            "the omitted id must stay in the group, in its original slot"
        )
    }

    /// Same rule for the ungrouped section's order.
    func testSetUngroupedOrderKeepsIdsAbsentFromTheNewOrder() async throws {
        let first = makeWorktree(branch: "first", path: "/tmp/first")
        let hidden = makeWorktree(branch: nil, path: "/tmp/hidden", headStatus: .detached)
        let last = makeWorktree(branch: "last", path: "/tmp/last")

        manager.setUngroupedOrder([first.id, hidden.id, last.id])
        try await Task.sleep(nanoseconds: 150_000_000)

        manager.setUngroupedOrder([last.id, first.id])
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            renderedOrder([first, hidden, last], showingDetached: true),
            [last.id, hidden.id, first.id]
        )
    }

    /// An id the manager has never seen — a worktree appended at render time and then dragged —
    /// is recorded rather than discarded.
    func testSetUngroupedOrderRecordsAnIdItHasNotStored() async throws {
        let stored = makeWorktree(branch: "stored", path: "/tmp/stored")
        let fresh = makeWorktree(branch: "fresh", path: "/tmp/fresh")

        manager.setUngroupedOrder([stored.id])
        try await Task.sleep(nanoseconds: 150_000_000)

        manager.setUngroupedOrder([fresh.id, stored.id])
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(renderedOrder([stored, fresh]), [fresh.id, stored.id])
    }

    /// A stored order can record the same id twice. A drag must collapse that, not add a third
    /// copy. The rule is pinned on `repositioned` itself because the rendered order deduplicates
    /// before the sidebar sees it, so no published value can tell the two apart.
    func testRepositionedCollapsesADuplicateStoredId() {
        XCTAssertEqual(
            WorktreeGroupManager.repositioned(
                ["/tmp/a", "/tmp/a", "/tmp/b"],
                with: ["/tmp/b", "/tmp/a"]
            ),
            ["/tmp/b", "/tmp/a"]
        )
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

        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let detached = makeWorktree(branch: nil, path: "/tmp/detached", headStatus: .detached)
        manager.addWorktree(detached, toGroupNamed: "Group")
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

    // MARK: - Helpers

    private func renderedOrder(_ worktrees: [Worktree], showingDetached: Bool = false) -> [String] {
        manager.sidebarOrderedWorktrees(
            worktrees,
            showingDetached: showingDetached,
            openIds: [],
            matches: { _ in true }
        ).map(\.id)
    }
}
