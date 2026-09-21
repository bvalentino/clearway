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
        await manager.reconcile([alpha, bravo], openIds: []).value

        XCTAssertEqual(
            renderedOrder([alpha, bravo]),
            [bravo.id, alpha.id],
            "rendered order after a relaunch"
        )
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
        await manager.reconcile([alpha, bravo], openIds: []).value
        await settle()

        XCTAssertEqual(
            renderedOrder([alpha, bravo]),
            [bravo.id, alpha.id],
            "rendered order after a relaunch"
        )
        XCTAssertEqual(
            try repo.value(ofKey: WorktreeConfigStore.positionKey, atWorktree: bravoPath),
            "0",
            "the seed must not renumber a worktree git already holds a position for"
        )
    }

    /// `tearDown` settles a manager whose last `reconcile` no body kept, and the seed write is
    /// enqueued inside that `Task`. A `settle()` blind to it returns before the first `git config`
    /// has run, so the read below is the whole case — a poll would wait the write out and hide it.
    func testSettleCoversAReconcileNoBodyAwaited() async throws {
        let path = try repo.addWorktree(branch: "alpha")
        let alpha = makeWorktree(branch: "alpha", path: path)

        manager.reconcile([alpha], openIds: [])
        await settle()

        XCTAssertEqual(
            try repo.value(ofKey: WorktreeConfigStore.positionKey, atWorktree: path),
            "0",
            "the reconcile's seed write must have landed by the time settle() returns"
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
        await settle()
        XCTAssertEqual(
            manager.groups.map(\.name),
            ["Old"],
            "the refusal reconciles against git at once, so the old name is back with no relaunch"
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
        await settle()
        XCTAssertEqual(
            manager.groups.map(\.name),
            ["Doomed"],
            "the refusal reconciles against git at once, so the group is back with no relaunch"
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

    /// A name or status git refused is log-only, unlike the half-applied registry rewrite that owns
    /// the alert. The log line has no test seam, so what is pinned here is what surrounds it: the
    /// gesture publishes at once, nothing in the write path reverts it, and no alert fires.
    /// Removing the worktree is what makes its `git config --worktree` writes fail.
    ///
    /// The refusal then starts the reconcile, on the same terms as every other write, and it
    /// publishes what git holds — which for a removed worktree is nothing, because `--worktree
    /// --list` against a gone directory is a refusal and a refusal reads as "stores nothing". So
    /// the name and status the write lost are gone from memory too, with no relaunch, rather than
    /// left standing until the worktree list next changes.
    func testAFailedNameOrStatusWriteIsReconciledAgainstGitAndRaisesNoAlert() async throws {
        let path = try repo.addWorktree(branch: "member")
        let member = makeWorktree(branch: "member", path: path)
        manager.setName("Named", for: member)
        try await waitForStoredValue("Named", ofKey: WorktreeConfigStore.nameKey, at: path)
        try repo.removeWorktree(at: path)
        XCTAssertFalse(try repo.statusSucceeds(in: path), "git can no longer run in the worktree")

        manager.setName("Renamed", for: member)
        manager.setStatus(.inReview, for: member)
        XCTAssertEqual(manager.name(for: member), "Renamed", "the gesture publishes before its write runs")
        XCTAssertEqual(manager.status(for: member), .inReview, "the gesture publishes before its write runs")

        await settle()

        XCTAssertNil(manager.name(for: member), "the reconcile publishes what git holds")
        XCTAssertNil(manager.status(for: member), "the reconcile publishes what git holds")
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

    // MARK: - Reconciling a refused write

    /// The rename git accepts on one member and refuses on the next. The registry is abandoned, so
    /// git ends up holding `New` for the member that took it and listing only `Old` — a state
    /// neither the sidebar nor the user asked for, and the one the reconcile has to describe.
    func testAHalfAppliedRenameRepublishesWhatGitHolds() async throws {
        let alphaPath = try repo.addWorktree(branch: "alpha")
        let betaPath = try repo.addWorktree(branch: "beta")
        let alpha = makeWorktree(branch: "alpha", path: alphaPath)
        let beta = makeWorktree(branch: "beta", path: betaPath)
        manager.createGroup(named: "Old")
        manager.addWorktree(alpha, toGroupNamed: "Old")
        manager.addWorktree(beta, toGroupNamed: "Old")
        try await waitForStoredValue("0", ofKey: WorktreeConfigStore.positionKey, at: alphaPath)
        try await waitForStoredValue("1", ofKey: WorktreeConfigStore.positionKey, at: betaPath)
        // The rename writes its members in position order, so alpha's write is attempted first and
        // lands; beta's directory is gone by then, so the one after it can only fail.
        try repo.removeWorktree(at: betaPath)

        manager.renameGroup(named: "Old", to: "New")
        await settle()

        XCTAssertEqual(
            try repo.value(ofKey: WorktreeConfigStore.groupKey, atWorktree: alphaPath),
            "New",
            "the first member's write landed"
        )
        XCTAssertEqual(
            try repo.localValues(ofKey: WorktreeConfigStore.groupOrderKey),
            ["Old"],
            "the member that failed abandoned the registry"
        )
        XCTAssertEqual(
            recordedWriteAlerts,
            [WorktreeGroupWriteAlert(group: "New", path: betaPath)],
            "the abandon is what the user was told about"
        )
        XCTAssertEqual(manager.groups.map(\.name), ["Old"], "the registry git holds, with no relaunch")
        XCTAssertNil(
            manager.groupName(for: alpha.id),
            "git holds New for alpha and the reloaded registry does not list it, so it renders "
                + "ungrouped rather than as a phantom section"
        )
    }

    /// A delete enqueues its positions and its registry as two chain entries, so the two halves can
    /// land separately — the third defect the change closes. Beta's git directory is the lever: the
    /// registry rewrite writes its members in position order, so alpha's `clearway.group` is cleared
    /// and beta's refusal abandons the registry, leaving one member in a group git still lists.
    func testAHalfAppliedDeleteRepublishesWhatGitHolds() async throws {
        let alphaPath = try repo.addWorktree(branch: "alpha")
        let betaPath = try repo.addWorktree(branch: "beta")
        let alpha = makeWorktree(branch: "alpha", path: alphaPath)
        let beta = makeWorktree(branch: "beta", path: betaPath)
        manager.createGroup(named: "Doomed")
        manager.addWorktree(alpha, toGroupNamed: "Doomed")
        manager.addWorktree(beta, toGroupNamed: "Doomed")
        try await waitForStoredValue("0", ofKey: WorktreeConfigStore.positionKey, at: alphaPath)
        try await waitForStoredValue("1", ofKey: WorktreeConfigStore.positionKey, at: betaPath)
        let betaGitDir = try repo.gitDir(ofWorktreeAt: betaPath)
        let previousMode = try GitRepoFixture.setPermissions(0o555, of: betaGitDir)
        defer { _ = try? GitRepoFixture.setPermissions(previousMode, of: betaGitDir) }

        manager.deleteGroup(named: "Doomed")
        await settle()

        XCTAssertNil(
            try repo.value(ofKey: WorktreeConfigStore.groupKey, atWorktree: alphaPath),
            "the first member's clear landed"
        )
        XCTAssertEqual(
            try repo.value(ofKey: WorktreeConfigStore.groupKey, atWorktree: betaPath),
            "Doomed",
            "the second member's was refused"
        )
        XCTAssertEqual(
            try repo.localValues(ofKey: WorktreeConfigStore.groupOrderKey),
            ["Doomed"],
            "the member that failed abandoned the registry"
        )
        XCTAssertEqual(
            recordedWriteAlerts,
            [WorktreeGroupWriteAlert(group: "Doomed", path: betaPath)],
            "the abandon is what the user was told about"
        )
        XCTAssertEqual(manager.groups.map(\.name), ["Doomed"], "the registry git holds")
        XCTAssertNil(manager.groupName(for: alpha.id), "the half of the delete that landed")
        XCTAssertEqual(manager.groupName(for: beta.id), "Doomed", "and the half that did not")
    }

    /// A drag whose write git refuses must not leave `positions` holding the value it published:
    /// `reassignedPositions` diffs against memory, so the next drag assigning that same value would
    /// read as no change at all and never be re-sent. Alpha's git directory is the lever.
    func testARefusedPositionWriteRepublishesTheStoredPosition() async throws {
        let alphaPath = try repo.addWorktree(branch: "alpha")
        let betaPath = try repo.addWorktree(branch: "beta")
        let alpha = makeWorktree(branch: "alpha", path: alphaPath)
        let beta = makeWorktree(branch: "beta", path: betaPath)
        manager.setUngroupedOrder([alpha.id, beta.id], in: [alpha, beta], openIds: [])
        try await waitForStoredValue("0", ofKey: WorktreeConfigStore.positionKey, at: alphaPath)
        try await waitForStoredValue("1", ofKey: WorktreeConfigStore.positionKey, at: betaPath)
        let alphaGitDir = try repo.gitDir(ofWorktreeAt: alphaPath)
        let previousMode = try GitRepoFixture.setPermissions(0o555, of: alphaGitDir)
        defer { _ = try? GitRepoFixture.setPermissions(previousMode, of: alphaGitDir) }

        manager.setUngroupedOrder([beta.id, alpha.id], in: [alpha, beta], openIds: [])
        await settle()

        XCTAssertEqual(
            try repo.value(ofKey: WorktreeConfigStore.positionKey, atWorktree: alphaPath),
            "0",
            "git refused the write, so the stored slot is the one the drag tried to replace"
        )
        XCTAssertEqual(manager.positions[alpha.id], 0, "memory holds git's value, not the drag's")
        XCTAssertEqual(manager.positions[beta.id], 0, "beta's half of the same drag landed")
    }

    /// The grouping mode is repo-level, so a refusal names no worktree at all: the reconcile it
    /// starts touches nothing, and `reloadConfig` re-reads both repo-level keys regardless. The
    /// project's own `.git` is the lever.
    func testARefusedGroupingWriteRepublishesTheStoredMode() async throws {
        try repo.enableWorktreeConfig()
        try repo.setLocalValue("status", ofKey: WorktreeConfigStore.groupingKey)
        await restartManager()
        XCTAssertEqual(manager.grouping, .status, "memory and git agree before the refusal")
        let gitDir = try repo.gitDir(ofWorktreeAt: repo.root)
        let previousMode = try GitRepoFixture.setPermissions(0o555, of: gitDir)
        defer { _ = try? GitRepoFixture.setPermissions(previousMode, of: gitDir) }

        manager.setGrouping(.none)
        await settle()

        XCTAssertEqual(
            try repo.value(ofLocalKey: WorktreeConfigStore.groupingKey),
            "status",
            "git refused the write"
        )
        XCTAssertEqual(manager.grouping, .status, "memory holds git's value, with no relaunch")
    }

    /// The registry rewrite's own refusal, as distinct from the abandoned member write above: no
    /// member is involved at all, so `writeRegistry`'s `replaceLocalValues` result is the only
    /// thing that can report it. The project's git directory is read-only once the first group has
    /// landed, so the rewrite cannot take its lock while `--get-all` still answers.
    func testARefusedRegistryRewriteRepublishesTheStoredRegistry() async throws {
        manager.createGroup(named: "Keep")
        try await waitForRegistry(["Keep"])
        let gitDir = try repo.gitDir(ofWorktreeAt: repo.root)
        let previousMode = try GitRepoFixture.setPermissions(0o555, of: gitDir)
        defer { _ = try? GitRepoFixture.setPermissions(previousMode, of: gitDir) }

        manager.createGroup(named: "Doomed")
        await settle()

        XCTAssertEqual(
            try repo.localValues(ofKey: WorktreeConfigStore.groupOrderKey),
            ["Keep"],
            "git refused the rewrite"
        )
        XCTAssertEqual(
            recordedWriteAlerts,
            [WorktreeGroupWriteAlert(group: "Doomed", path: nil)],
            "the half-applied registry is what the user is told about"
        )
        XCTAssertEqual(
            manager.groups.map(\.name),
            ["Keep"],
            "the refusal reconciles against git at once, so the new group is gone with no relaunch"
        )
    }

    /// The reconcile costs a `git config` read per worktree plus the two repo-level ones, so a
    /// gesture that landed must start none. The handle is the only way to observe that; nothing in
    /// production reads it.
    func testAGestureWhoseWritesLandStartsNoReconcile() async throws {
        let path = try repo.addWorktree(branch: "member")
        let member = makeWorktree(branch: "member", path: path)
        manager.createGroup(named: "Group")
        manager.addWorktree(member, toGroupNamed: "Group")
        try await waitForStoredValue("Group", ofKey: WorktreeConfigStore.groupKey, at: path)

        await settle()

        XCTAssertNil(manager.reconcileTask, "a gesture whose writes all land reconciles nothing")
    }

    /// The reconcile republishes `names`, `statuses` and `placement` wholesale, so its targets have
    /// to include every worktree the manager holds a value for *when the reads run*, not when the
    /// refusal was seen. Beta carries no `clearway.*` value at the refusal and takes its first
    /// gesture once the reconcile is under way: with the targets fixed earlier it is outside them,
    /// and the value git has just accepted for it is erased from memory.
    ///
    /// Which side of the reconcile's reads beta's gesture lands on is the scheduler's to decide,
    /// and the case is a pin either way: arriving during them replaces `writeChain` and restarts
    /// the reload, which re-resolves; arriving before them puts beta in the published maps the
    /// resolution reads. Both fail against targets fixed at the refusal.
    func testAFirstGestureMadeDuringTheReconcileSurvivesIt() async throws {
        let alphaPath = try repo.addWorktree(branch: "alpha")
        let betaPath = try repo.addWorktree(branch: "beta")
        let alpha = makeWorktree(branch: "alpha", path: alphaPath)
        let beta = makeWorktree(branch: "beta", path: betaPath)
        try repo.enableWorktreeConfig()
        await restartManager()
        let alphaGitDir = try repo.gitDir(ofWorktreeAt: alphaPath)
        let previousMode = try GitRepoFixture.setPermissions(0o555, of: alphaGitDir)
        defer { _ = try? GitRepoFixture.setPermissions(previousMode, of: alphaGitDir) }

        manager.setStatus(.inProgress, for: alpha)
        try await waitFor(true, describing: "the refused write started a reconcile") {
            self.manager.reconcileTask != nil
        }
        manager.setName("Beta", for: beta)
        await settle()

        XCTAssertEqual(
            try repo.value(ofKey: WorktreeConfigStore.nameKey, atWorktree: betaPath),
            "Beta",
            "beta's write landed"
        )
        XCTAssertEqual(manager.name(for: beta), "Beta", "memory holds what git holds for beta")
        XCTAssertNil(manager.status(for: alpha), "and git's nothing for alpha, whose write did not")
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

        await manager.reconcile([ghosted], openIds: []).value

        XCTAssertEqual(manager.name(for: ghosted), "Ghosted", "published name for \(ghosted.id)")
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
        await manager.reconcile([main, staying], openIds: []).value
        await settle()

        XCTAssertEqual(manager.groupNames, [staying.id: "Group"], "published memberships")
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
        // Awaited, not left running: the reconcile the refusal starts reads git in `plainRoot`,
        // which the `defer` above removes.
        await first.reconcileTask?.value
        XCTAssertTrue(first.groups.isEmpty, "and is then reconciled away, since git stored nothing")

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
        // Reads git back, so the manager's queued writes must have landed first.
        await settle()
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
        // Reads git back, so the manager's queued writes must have landed first.
        await settle()
        try await waitFor(expected, describing: key, file: file, line: line) {
            try self.repo.value(ofLocalKey: key)
        }
    }
}
