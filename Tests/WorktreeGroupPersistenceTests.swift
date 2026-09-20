import XCTest
@testable import Clearway

/// What the sidebar's groups survive: a relaunch, a rename, a delete, `git worktree remove`, and a
/// project git will not let the extension be enabled in. Every assertion about stored state reads
/// git through `GitRepoFixture` rather than through the manager under test.
final class WorktreeGroupPersistenceTests: WorktreeGroupManagerGitTestCase {

    // MARK: - Relaunch

    func testTheRegistrySurvivesARelaunch() async throws {
        manager.createGroup(named: "Backlog")
        manager.createGroup(named: "Shipped")
        try await waitForRegistry(["Backlog", "Shipped"])

        await restartManager()

        XCTAssertEqual(manager.groups.map(\.name), ["Backlog", "Shipped"], "registry order is creation order")
    }

    func testMembershipAndPositionSurviveARelaunch() async throws {
        let alphaPath = try repo.addWorktree(branch: "alpha")
        let bravoPath = try repo.addWorktree(branch: "bravo")
        let alpha = makeWorktree(branch: "alpha", path: alphaPath)
        let bravo = makeWorktree(branch: "bravo", path: bravoPath)
        manager.createGroup(named: "Group")
        manager.addWorktree(alpha, toGroupNamed: "Group")
        manager.addWorktree(bravo, toGroupNamed: "Group")
        manager.setGroupOrder(named: "Group", ids: [bravo.id, alpha.id], in: [alpha, bravo], openIds: [])
        try await waitForStoredValue("0", ofKey: WorktreeConfigStore.positionKey, at: bravoPath)
        try await waitForStoredValue("1", ofKey: WorktreeConfigStore.positionKey, at: alphaPath)

        await restartManager()
        manager.reconcile([alpha, bravo], openIds: [])

        try await waitFor([bravo.id, alpha.id], describing: "rendered order after a relaunch") {
            self.renderedOrder([alpha, bravo])
        }
        XCTAssertEqual(manager.groupName(for: alpha.id), "Group")
        XCTAssertEqual(manager.groupName(for: bravo.id), "Group")
    }

    /// The seed must not run ahead of the reload. When it did, a relaunch re-numbered every
    /// worktree in `Worktree.sorted` order before the reload had published what git held, and the
    /// reload then read the clobbered values back — the custom sidebar order reset on every launch.
    func testTheStoredOrderSurvivesContentViewsReloadSequence() async throws {
        let alphaPath = try repo.addWorktree(branch: "alpha")
        let bravoPath = try repo.addWorktree(branch: "bravo")
        let alpha = makeWorktree(branch: "alpha", path: alphaPath)
        let bravo = makeWorktree(branch: "bravo", path: bravoPath)
        manager.seedPositions(for: [alpha, bravo], openIds: [])
        manager.setUngroupedOrder([bravo.id, alpha.id], in: [alpha, bravo], openIds: [])
        try await waitForStoredValue("0", ofKey: WorktreeConfigStore.positionKey, at: bravoPath)
        try await waitForStoredValue("1", ofKey: WorktreeConfigStore.positionKey, at: alphaPath)

        await restartManager()
        // The one call `ContentView` makes when the worktree list changes.
        manager.reconcile([alpha, bravo], openIds: [])

        try await waitFor([bravo.id, alpha.id], describing: "rendered order after a relaunch") {
            self.renderedOrder([alpha, bravo])
        }
        XCTAssertEqual(
            try repo.value(ofKey: WorktreeConfigStore.positionKey, atWorktree: bravoPath),
            "0",
            "the seed must not renumber a worktree git already holds a position for"
        )
    }

    func testTheGroupingModeRoundTrips() async throws {
        manager.setGrouping(.status)
        try await waitForLocalValue("status", ofKey: WorktreeConfigStore.groupingKey)

        await restartManager()
        XCTAssertEqual(manager.grouping, .status)

        manager.setGrouping(.none)
        try await waitForLocalValue("none", ofKey: WorktreeConfigStore.groupingKey)

        await restartManager()
        XCTAssertEqual(manager.grouping, .none)
    }

    // MARK: - Rename and delete

    /// The members are written before the registry, so a rename that stopped halfway would leave
    /// members naming a group nothing lists — which renders ungrouped rather than empty.
    func testRenameRewritesEveryMemberAndKeepsTheRegistrySlot() async throws {
        let path = try repo.addWorktree(branch: "member")
        let member = makeWorktree(branch: "member", path: path)
        manager.createGroup(named: "Old")
        manager.createGroup(named: "Later")
        manager.addWorktree(member, toGroupNamed: "Old")
        try await waitForStoredValue("Old", ofKey: WorktreeConfigStore.groupKey, at: path)

        manager.renameGroup(named: "Old", to: "New")

        try await waitForStoredValue("New", ofKey: WorktreeConfigStore.groupKey, at: path)
        try await waitForRegistry(["New", "Later"])
        XCTAssertTrue(recordedWriteAlerts.isEmpty, "a gesture that landed tells the user nothing")
    }

    /// The registry is written last and only if every member write landed, so a rename whose
    /// members all fail changes nothing on disk and the next reload restores what the sidebar
    /// showed before. Here the member's directory is gone, so `git -C <path> config --worktree`
    /// can only fail.
    func testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched() async throws {
        let path = try repo.addWorktree(branch: "member")
        let member = makeWorktree(branch: "member", path: path)
        manager.createGroup(named: "Old")
        manager.addWorktree(member, toGroupNamed: "Old")
        try await waitForStoredValue("Old", ofKey: WorktreeConfigStore.groupKey, at: path)
        try repo.removeWorktree(at: path)

        manager.renameGroup(named: "Old", to: "New")
        // Queued behind the rename on the write chain, so its arrival proves the rename is done.
        manager.setGrouping(.status)
        try await waitForLocalValue("status", ofKey: WorktreeConfigStore.groupingKey)

        XCTAssertEqual(
            try repo.localValues(ofKey: WorktreeConfigStore.groupOrderKey),
            ["Old"],
            "a rename no member accepted must not reach the registry"
        )
        XCTAssertEqual(
            recordedWriteAlerts,
            [WorktreeGroupWriteAlert(group: "New", path: path)],
            "the abandoned registry is the one failure the user is told about"
        )
        await restartManager()
        XCTAssertEqual(manager.groups.map(\.name), ["Old"], "the next launch shows the old name")
    }

    /// The same abandon as the rename above, reached by the one gesture whose member value is not
    /// the group it acts on: a delete writes `nil`, so the name the alert carries can only have
    /// come from the gesture. The failing `clearway.position` write the delete queues ahead of the
    /// registry stays log-only, which is what the single recorded alert pins.
    func testADeleteWhoseMemberWritesFailLeavesTheRegistryUntouched() async throws {
        let path = try repo.addWorktree(branch: "member")
        let member = makeWorktree(branch: "member", path: path)
        manager.createGroup(named: "Doomed")
        manager.addWorktree(member, toGroupNamed: "Doomed")
        try await waitForStoredValue("Doomed", ofKey: WorktreeConfigStore.groupKey, at: path)
        try repo.removeWorktree(at: path)

        manager.deleteGroup(named: "Doomed")
        // Queued behind the delete on the write chain, so its arrival proves the delete is done.
        manager.setGrouping(.status)
        try await waitForLocalValue("status", ofKey: WorktreeConfigStore.groupingKey)

        XCTAssertEqual(
            try repo.localValues(ofKey: WorktreeConfigStore.groupOrderKey),
            ["Doomed"],
            "a delete no member accepted must not reach the registry"
        )
        XCTAssertEqual(
            recordedWriteAlerts,
            [WorktreeGroupWriteAlert(group: "Doomed", path: path)],
            "the alert names the deleted group, never the nil written to its members"
        )
    }

    /// The registry rewrite is half-applied on its own terms: `replaceLocalValues` unsets every
    /// value before adding each one back, so a refusal partway leaves `clearway.groupOrder`
    /// truncated or empty and every group is gone on the next launch. Here the repository's git
    /// directory is removed once the first group has landed, so a repo-level write can only fail.
    func testAFailedRegistryRewriteTellsTheUser() async throws {
        manager.createGroup(named: "Keep")
        try await waitForRegistry(["Keep"])
        try FileManager.default.removeItem(
            atPath: (tempRoot as NSString).appendingPathComponent(".git")
        )

        manager.createGroup(named: "Doomed")

        try await waitFor(
            [WorktreeGroupWriteAlert(group: "Doomed", path: nil)],
            describing: "the alert a lost registry rewrite raises"
        ) {
            self.recordedWriteAlerts
        }
    }

    /// A name or status git refused is log-only: `WorktreeGroupManager` names the lost gesture in
    /// the log and tells the user nothing, because the value is one the next gesture overwrites and
    /// the next reload corrects — unlike the half-applied registry rewrite that owns the alert.
    /// Here the worktree's directory is gone, so its `git config --worktree` writes can only fail.
    func testAFailedNameOrStatusWriteStaysPublishedAndRaisesNoAlert() async throws {
        let path = try repo.addWorktree(branch: "member")
        let member = makeWorktree(branch: "member", path: path)
        manager.setName("Named", for: member)
        try await waitForStoredValue("Named", ofKey: WorktreeConfigStore.nameKey, at: path)
        try repo.removeWorktree(at: path)

        manager.setName("Renamed", for: member)
        manager.setStatus(.inReview, for: member)
        await settle()

        XCTAssertEqual(manager.name(for: member), "Renamed", "the publish stands when the write fails")
        XCTAssertEqual(manager.status(for: member), .inReview, "the publish stands when the write fails")
        XCTAssertTrue(recordedWriteAlerts.isEmpty, "a lost name or status is log-only")
    }

    func testDeleteUnsetsEveryMemberAndDropsTheRegistryEntry() async throws {
        let path = try repo.addWorktree(branch: "member")
        let member = makeWorktree(branch: "member", path: path)
        manager.createGroup(named: "Doomed")
        manager.addWorktree(member, toGroupNamed: "Doomed")
        try await waitForStoredValue("Doomed", ofKey: WorktreeConfigStore.groupKey, at: path)

        manager.deleteGroup(named: "Doomed")

        try await waitForStoredValue(nil, ofKey: WorktreeConfigStore.groupKey, at: path)
        try await waitForRegistry([])
    }

    // MARK: - Config the app did not write

    /// Every other case that observes a repo-level key does it through a relaunch. `reconcile` is
    /// the call `ContentView` makes when the worktree list changes, and it re-reads the grouping
    /// mode and the registry alongside each worktree's own config — so a group or a grouping mode
    /// another checkout of the repo wrote reaches the sidebar without one.
    func testReconcileRereadsBothRepoLevelKeys() async throws {
        try repo.enableWorktreeConfig()
        await restartManager()
        try repo.setLocalValue("status", ofKey: WorktreeConfigStore.groupingKey)
        try repo.addLocalValue("Seeded", ofKey: WorktreeConfigStore.groupOrderKey)

        // Both reads are repo-level and independent of the worktree list, so the list is empty.
        await manager.reconcile([], openIds: []).value

        XCTAssertEqual(manager.grouping, .status, "the grouping mode, with no relaunch")
        XCTAssertEqual(manager.groups.map(\.name), ["Seeded"], "the registry, with no relaunch")
    }

    /// `config.worktree` is hand-editable, so `clearway.position` can come back as anything. Only
    /// the unparseable value is dropped: the worktree keeps the rest of its config, and the seed
    /// then gives it a slot above the section's maximum rather than ahead of it.
    func testANonIntegerPositionIsDroppedAndTheWorktreeKeepsTheRest() async throws {
        let alphaPath = try repo.addWorktree(branch: "alpha")
        let bravoPath = try repo.addWorktree(branch: "bravo")
        let alpha = makeWorktree(branch: "alpha", path: alphaPath)
        let bravo = makeWorktree(branch: "bravo", path: bravoPath)
        try repo.enableWorktreeConfig()
        await restartManager()
        try repo.setValue("Alpha", ofKey: WorktreeConfigStore.nameKey, atWorktree: alphaPath)
        try repo.setValue("seven", ofKey: WorktreeConfigStore.positionKey, atWorktree: alphaPath)
        try repo.setValue("7", ofKey: WorktreeConfigStore.positionKey, atWorktree: bravoPath)

        await manager.reconcile([alpha, bravo], openIds: []).value

        XCTAssertEqual(manager.name(for: alpha), "Alpha", "only the position is dropped")
        XCTAssertEqual(manager.positions[bravo.id], 7)
        XCTAssertEqual(manager.positions[alpha.id], 8, "seeded above the section's maximum")
        XCTAssertEqual(renderedOrder([alpha, bravo]), [bravo.id, alpha.id])
    }

    /// The registry is the only source of which groups exist, so a hand-written membership naming
    /// one it does not list renders ungrouped instead of growing a section.
    func testAMembershipNamingAnUnlistedGroupRendersUngrouped() async throws {
        let path = try repo.addWorktree(branch: "ghosted")
        let ghosted = makeWorktree(branch: "ghosted", path: path)
        manager.createGroup(named: "Real")
        try await waitForRegistry(["Real"])
        try repo.setValue("Ghost", ofKey: WorktreeConfigStore.groupKey, atWorktree: path)
        try repo.setValue("Ghosted", ofKey: WorktreeConfigStore.nameKey, atWorktree: path)

        manager.reconcile([ghosted], openIds: [])

        try await waitFor("Ghosted" as String?, describing: "published name for \(ghosted.id)") {
            self.manager.name(for: ghosted)
        }
        XCTAssertNil(manager.groupName(for: ghosted.id), "the membership names no listed group")
        XCTAssertEqual(manager.groups.map(\.name), ["Real"], "no phantom section")
        XCTAssertEqual(renderedOrder([ghosted]), [ghosted.id])
    }

    /// `.git/config` is hand-editable and shared with every other git tool, so the registry can
    /// come back holding a name twice or a blank one. Two groups with the same name share an `id`
    /// and trap the sidebar's `ForEach`; a blank one renders a nameless section whose drops
    /// `WorktreeConfigStore.set` discards as a clear.
    func testAHandEditedRegistryDropsBlanksAndRepeats() async throws {
        try repo.enableWorktreeConfig()
        for value in ["Dup", "", "Dup", "Other"] {
            try repo.addLocalValue(value, ofKey: WorktreeConfigStore.groupOrderKey)
        }

        await restartManager()

        XCTAssertEqual(manager.groups.map(\.name), ["Dup", "Other"])
    }

    /// `git worktree remove` deletes the worktree's `config.worktree` with it, so nothing prunes
    /// and nothing is left behind on the worktrees that remain.
    func testRemovingAWorktreeLeavesNothingBehind() async throws {
        let goingPath = try repo.addWorktree(branch: "going")
        let stayingPath = try repo.addWorktree(branch: "staying")
        let main = makeWorktree(branch: "main", path: repo.root, isMain: true)
        let going = makeWorktree(branch: "going", path: goingPath)
        let staying = makeWorktree(branch: "staying", path: stayingPath)
        manager.createGroup(named: "Group")
        manager.addWorktree(going, toGroupNamed: "Group")
        manager.addWorktree(staying, toGroupNamed: "Group")
        try await waitForStoredValue("0", ofKey: WorktreeConfigStore.positionKey, at: goingPath)
        try await waitForStoredValue("1", ofKey: WorktreeConfigStore.positionKey, at: stayingPath)

        try repo.removeWorktree(at: goingPath)
        manager.reconcile([main, staying], openIds: [])

        try await waitFor([staying.id: "Group"], describing: "published memberships") {
            self.manager.groupNames
        }
        XCTAssertEqual(manager.positions, [staying.id: 1])
        XCTAssertEqual(renderedOrder([main, staying]), [main.id, staying.id])
        XCTAssertNil(try repo.value(ofKey: WorktreeConfigStore.groupKey, atWorktree: repo.root))
        XCTAssertNil(try repo.value(ofKey: WorktreeConfigStore.positionKey, atWorktree: repo.root))
        XCTAssertEqual(try repo.value(ofKey: WorktreeConfigStore.positionKey, atWorktree: stayingPath), "1")
    }

    // MARK: - Config the app must not write

    /// `.group` is the manager's default, so choosing it again is a no-op gesture. It must not
    /// reach git: the write would bootstrap the extension and relocate `core.bare` for nothing.
    func testANoOpSetGroupingWritesNothing() async throws {
        manager.setGrouping(.group)
        await settle()

        XCTAssertEqual(manager.grouping, .group)
        XCTAssertNil(try repo.value(ofLocalKey: WorktreeConfigStore.groupingKey))
        XCTAssertNil(
            try repo.value(ofLocalKey: "extensions.worktreeConfig"),
            "a no-op grouping must not even bootstrap the extension"
        )
    }

    // MARK: - Nothing on the filesystem

    func testNoClearwayDirectoryIsCreated() async throws {
        let path = try repo.addWorktree(branch: "member")
        let member = makeWorktree(branch: "member", path: path)
        manager.createGroup(named: "Group")
        manager.addWorktree(member, toGroupNamed: "Group")
        manager.setGroupOrder(named: "Group", ids: [member.id], in: [member], openIds: [])
        manager.setStatus(.inReview, for: member)
        manager.setGrouping(.status)
        try await waitForStoredValue("Group", ofKey: WorktreeConfigStore.groupKey, at: path)
        try await waitForLocalValue("status", ofKey: WorktreeConfigStore.groupingKey)

        manager.renameGroup(named: "Group", to: "Renamed")
        manager.removeWorktreeFromGroup(member)
        manager.deleteGroup(named: "Renamed")
        try await waitForStoredValue(nil, ofKey: WorktreeConfigStore.groupKey, at: path)
        try await waitForRegistry([])

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (tempRoot as NSString).appendingPathComponent(".clearway")
            ),
            "every group gesture goes to git config"
        )
    }

    /// The one case the deleted non-git test base used to cover: a project git will not let the
    /// extension be enabled in publishes the gesture and stores nothing, on the same terms as
    /// names and statuses.
    func testAProjectWhereTheExtensionCannotBeEnabledShowsNoGroups() async throws {
        let plainRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: plainRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plainRoot) }

        // Built outside the base's recording seam, in a project where every write fails, so the
        // presenters are what keep the run off a modal nothing can dismiss. `createGroup` passes no
        // members, so the only failure it can reach is the registry rewrite.
        let first = WorktreeGroupManager(projectPath: plainRoot)
        first.presentWriteAlert = {
            XCTAssertEqual($0, WorktreeGroupWriteAlert(group: "Doomed", path: nil))
        }
        await first.loadTask?.value
        first.createGroup(named: "Doomed")
        XCTAssertEqual(first.groups.map(\.name), ["Doomed"], "the gesture is still published")
        await first.writeChain?.value

        let second = WorktreeGroupManager(projectPath: plainRoot)
        second.presentWriteAlert = { XCTFail("a manager that only reads must not alert: \($0)") }
        await second.loadTask?.value

        XCTAssertTrue(second.groups.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (plainRoot as NSString).appendingPathComponent(".git")
            ),
            "a failed write must not make the directory a repository"
        )
    }

    // MARK: - Helpers

    private func waitForRegistry(
        _ expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitFor(
            expected,
            describing: WorktreeConfigStore.groupOrderKey,
            file: file,
            line: line
        ) {
            try self.repo.localValues(ofKey: WorktreeConfigStore.groupOrderKey)
        }
    }

    private func waitForLocalValue(
        _ expected: String?,
        ofKey key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitFor(expected, describing: key, file: file, line: line) {
            try self.repo.value(ofLocalKey: key)
        }
    }
}
