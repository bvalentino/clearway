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
        XCTAssertFalse(groupsFileExists, "a status must write nothing into groups.json")
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
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(manager.statuses.isEmpty)
        XCTAssertFalse(groupsFileExists, "a main-worktree status must write nothing")
        XCTAssertFalse(
            try repo.localConfigContents().contains("worktreeConfig"),
            "a main-worktree status must not even bootstrap the extension"
        )
    }

    /// `setStatus` is not the only way an entry lands in `statuses`: a `groups.json` written
    /// before statuses moved can still carry main's id, and the migration deliberately does not
    /// filter it out. Honouring one would drop main out of the top of the by-status order with
    /// no badge or menu to explain it.
    func testStatusStoredAgainstMainIsIgnoredOnTheReadPath() async throws {
        let main = makeWorktree(branch: "main", path: repo.root, isMain: true)
        let alpha = makeWorktree(branch: "alpha", path: "/tmp/alpha")
        try writeGroupsFile(legacyStatuses: [main.id: .done], grouping: .status)

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

    // MARK: - The one-shot groups.json migration

    func testLegacyStatusesMigrateIntoWorktreeConfigAndLeaveTheFile() async throws {
        let path = try repo.addWorktree(branch: "feature")
        let wt = makeWorktree(branch: "feature", path: path)
        try writeGroupsFile(legacyStatuses: [wt.id: .onHold], grouping: .status)

        let reopened = try await reopenedManager()

        XCTAssertEqual(
            reopened.statuses,
            [wt.id: .onHold],
            "published before any subprocess runs, so a launch is never briefly unstatused"
        )
        XCTAssertEqual(reopened.grouping, .status)
        try await waitForStoredStatus(.onHold, at: path)
        try await waitForGroupsFileWithoutStatuses()
    }

    /// The migration writes one worktree at a time and a key that is no longer a worktree path
    /// fails inside `git`. The live one must still land.
    func testLegacyMigrationSkipsAPathThatNoLongerExists() async throws {
        let path = try repo.addWorktree(branch: "feature")
        let wt = makeWorktree(branch: "feature", path: path)
        try writeGroupsFile(
            legacyStatuses: [wt.id: .inReview, "/tmp/gone-\(UUID().uuidString)": .done],
            grouping: .group
        )

        _ = try await reopenedManager()

        try await waitForStoredStatus(.inReview, at: path)
        try await waitForGroupsFileWithoutStatuses()
    }

    func testInitLoadsAFileThatNeverCarriedStatuses() async throws {
        try writeGroupsFile(json: #"{"groups":[],"defaultOrder":["/a","/b"],"grouping":"none"}"#)

        let reopened = try await reopenedManager()

        XCTAssertEqual(reopened.defaultOrder, ["/a", "/b"])
        XCTAssertEqual(reopened.grouping, .none)
        XCTAssertTrue(reopened.statuses.isEmpty)
    }

    /// The watcher republishes what the file still owns and nothing else: a hand-edited
    /// `statuses` key is no longer a source of truth.
    func testExternalWriteRepublishesGroupingAndIgnoresAStatusesKey() async throws {
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature")

        try writeGroupsFile(legacyStatuses: [wt.id: .inProgress], grouping: .none)

        let deadline = Date().addingTimeInterval(5)
        while manager.grouping == .group, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(manager.grouping, .none)
        XCTAssertTrue(
            manager.statuses.isEmpty,
            "the watcher no longer republishes statuses from the file"
        )
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

        manager.reconcile([alive])

        try await waitForPublishedStatuses([alive.id: .inReview])
    }

    /// A status whose worktree has gone leaves the published map because the reload rebuilds it
    /// from the live list — not because `reconcile` prunes it, which is why nothing is saved.
    func testReconcileDropsAnAbsentWorktreeWithoutSaving() async throws {
        let alivePath = try repo.addWorktree(branch: "alive")
        let deadPath = try repo.addWorktree(branch: "dead")
        let alive = makeWorktree(branch: "alive", path: alivePath)
        let dead = makeWorktree(branch: "dead", path: deadPath)

        manager.setStatus(.todo, for: alive)
        manager.setStatus(.onHold, for: dead)
        try await waitForStoredStatus(.onHold, at: deadPath)

        manager.reconcile([alive])

        try await waitForPublishedStatuses([alive.id: .todo])
        XCTAssertFalse(groupsFileExists, "reconcile no longer saves a status prune")
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

        XCTAssertTrue(manager.matches(wt, query: "review", taskTitle: nil))
        XCTAssertFalse(manager.matches(wt, query: "hold", taskTitle: nil))
    }

    // MARK: - Helpers

    /// Writes the pre-change wire format by hand: the payload can no longer encode `statuses`,
    /// which is the whole point of the migration these cases exercise.
    private func writeGroupsFile(
        legacyStatuses: [String: WorktreeStatus],
        grouping: WorktreeGrouping
    ) throws {
        let entries = legacyStatuses
            .map { "\"\($0.key)\":\"\($0.value.rawValue)\"" }
            .joined(separator: ",")
        try writeGroupsFile(
            json: """
            {"groups":[],"defaultOrder":[],"statuses":{\(entries)},"grouping":"\(grouping.rawValue)"}
            """
        )
    }

    private func writeGroupsFile(json: String) throws {
        try FileManager.default.createDirectory(
            atPath: (groupsFilePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: URL(fileURLWithPath: groupsFilePath), options: .atomic)
    }

    /// A second manager over the same root, standing in for a relaunch.
    private func reopenedManager() async throws -> WorktreeGroupManager {
        let reopened = WorktreeGroupManager(projectPath: tempRoot)
        try await Task.sleep(nanoseconds: 150_000_000)
        return reopened
    }

    /// Polls rather than sleeping a fixed span: a status write is a git subprocess, behind the
    /// extension bootstrap on its first call.
    private func waitForStoredStatus(
        _ expected: WorktreeStatus?,
        at path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitFor(
            expected?.rawValue,
            describing: "stored status at \(path)",
            file: file,
            line: line
        ) {
            try self.repo.value(ofKey: WorktreeConfigStore.statusKey, atWorktree: path)
        }
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

    private func waitForGroupsFileWithoutStatuses(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitFor(false, describing: "groups.json still carries statuses", file: file, line: line) {
            try String(contentsOfFile: self.groupsFilePath, encoding: .utf8).contains("statuses")
        }
    }

    private func waitFor<Value: Equatable>(
        _ expected: Value,
        describing subject: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        reading read: () throws -> Value
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last = try read()
        while last != expected, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            last = try read()
        }
        XCTAssertEqual(last, expected, subject, file: file, line: line)
    }
}
