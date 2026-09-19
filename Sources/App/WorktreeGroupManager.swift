import Foundation
import SwiftUI

// MARK: - Manager

/// Manages the in-memory state of worktree groups for a single project.
///
/// All mutations go through this class; persistence is delegated to `WorktreeGroupStore`.
/// The `groups` array is always sorted ascending by `createdAt`.
@MainActor
final class WorktreeGroupManager: ObservableObject {
    @Published private(set) var groups: [WorktreeGroup] = []
    /// User-defined order of non-main worktrees in the ungrouped "default" section.
    /// Main is always pinned to the top and is not tracked here.
    @Published private(set) var defaultOrder: [String] = []
    /// Per-worktree status, keyed by `Worktree.id`, backed by each worktree's own git config.
    /// Main is never a key.
    @Published private(set) var statuses: [String: WorktreeStatus] = [:]
    /// Per-worktree display name, keyed by `Worktree.id`, backed by each worktree's own git
    /// config. Main is never a key.
    @Published private(set) var names: [String: String] = [:]
    /// The axis the sidebar sections its worktrees by.
    @Published private(set) var grouping: WorktreeGrouping = .group

    private let store: WorktreeGroupStore
    private let configStore: WorktreeConfigStore

    /// Config writes run one after another, and every config read awaits the chain first.
    /// Creating a worktree writes a name and also changes the live worktree list, which fires the
    /// reload in the same turn; without the chain that reload can read the worktree's config
    /// before the write lands and publish an empty name over the one just typed.
    private var writeChain: Task<Void, Never>?

    init(projectPath: String) {
        self.store = WorktreeGroupStore(projectPath: projectPath)
        self.configStore = WorktreeConfigStore(projectPath: projectPath)

        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.store.load()
            self.groups = WorktreeGroup.sortedByCreation(loaded.groups)
            self.defaultOrder = loaded.defaultOrder
            self.grouping = loaded.grouping
            self.migrateLegacyStatuses(loaded.legacyStatuses)

            self.store.startWatching { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let reloaded = await self.store.load()
                    let sortedGroups = WorktreeGroup.sortedByCreation(reloaded.groups)
                    if sortedGroups != self.groups { self.groups = sortedGroups }
                    if reloaded.defaultOrder != self.defaultOrder {
                        self.defaultOrder = reloaded.defaultOrder
                    }
                    if reloaded.grouping != self.grouping { self.grouping = reloaded.grouping }
                }
            }
        }
    }

    deinit {
        store.stopWatching()
    }

    // MARK: - Public API

    /// Creates a new group with the given name and appends it to the sorted list.
    func createGroup(named name: String) {
        let group = WorktreeGroup(id: UUID(), name: name, worktreeIds: [], createdAt: Date())
        groups.append(group)
        groups = WorktreeGroup.sortedByCreation(groups)
        save()
    }

    /// Renames the group with the given ID. No-ops if the ID is not found.
    func renameGroup(id: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
        save()
    }

    /// Deletes the group with the given ID. No-ops if the ID is not found.
    func deleteGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        save()
    }

    /// Adds a worktree to the specified group.
    ///
    /// The main worktree is silently ignored — it can never be placed in a group.
    /// The worktree is removed from any existing group before being added to the target.
    func addWorktree(_ wt: Worktree, toGroup groupId: UUID) {
        guard !wt.isMain else { return }
        let worktreeId = wt.id
        // No-op when the worktree is already in the target group. Without this guard,
        // SwiftUI's List animates a remove+insert round-trip that can crash the backing
        // NSTableView mid-drag when the drop lands on the worktree's own group header.
        if groups.first(where: { $0.id == groupId })?.worktreeIds.contains(worktreeId) == true { return }
        // Mutate a local copy and publish a single `groups` assignment. Per-index writes
        // against the @Published array would fire objectWillChange N times during a drop,
        // which can re-enter the sidebar's NSTableView mid-animation and crash.
        var updated = groups
        for index in updated.indices {
            updated[index].worktreeIds.removeAll { $0 == worktreeId }
        }
        guard let targetIndex = updated.firstIndex(where: { $0.id == groupId }) else { return }
        updated[targetIndex].worktreeIds.append(worktreeId)
        groups = updated
        // Moving into a group removes the worktree from the default section's order.
        if defaultOrder.contains(worktreeId) {
            defaultOrder.removeAll { $0 == worktreeId }
        }
        save()
    }

    /// Removes a worktree ID from every group it appears in. Does not add it to
    /// `defaultOrder` — the view treats any non-main worktree missing from
    /// `defaultOrder` as a new arrival and appends it at render time.
    func removeWorktreeFromAllGroups(_ worktreeId: String) {
        var updated = groups
        var changed = false
        for index in updated.indices where updated[index].worktreeIds.contains(worktreeId) {
            updated[index].worktreeIds.removeAll { $0 == worktreeId }
            changed = true
        }
        guard changed else { return }
        groups = updated
        save()
    }

    /// Repositions the given non-main worktree IDs within the ungrouped section's order.
    /// Callers pass the rows the sidebar rendered, which is a subset whenever the detached
    /// filter hides one, so stored IDs the caller omits keep their slot.
    func setDefaultOrder(_ ids: [String]) {
        let reordered = Self.repositioned(defaultOrder, with: ids)
        guard reordered != defaultOrder else { return }
        defaultOrder = reordered
        save()
    }

    /// Appends newly-discovered non-main, ungrouped worktrees to `defaultOrder` so
    /// click-to-open never re-sorts the sidebar. Idempotent: IDs already recorded
    /// in `defaultOrder` or in any group are left in place. New IDs are appended in
    /// `Worktree.sorted` order — the same rule `sidebarOrderedWorktrees` used to
    /// render them before they were persisted.
    func seedDefaultOrder(with worktrees: [Worktree], openIds: [String]) {
        let missing = worktrees.filter { wt in
            !wt.isMain
                && groupId(for: wt.id) == nil
                && !defaultOrder.contains(wt.id)
        }
        guard !missing.isEmpty else { return }
        let ordered = Worktree.sorted(missing, openIds: openIds).map(\.id)
        defaultOrder += ordered
        save()
    }

    /// Repositions the given worktree IDs within a group, on the same terms as `setDefaultOrder`.
    func setGroupOrder(id groupId: UUID, ids: [String]) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        let reordered = Self.repositioned(groups[index].worktreeIds, with: ids)
        guard reordered != groups[index].worktreeIds else { return }
        var updated = groups
        updated[index].worktreeIds = reordered
        groups = updated
        save()
    }

    /// Returns the ID of the group that contains the given worktree ID, or `nil` if ungrouped.
    func groupId(for worktreeId: String) -> UUID? {
        groups.first(where: { $0.worktreeIds.contains(worktreeId) })?.id
    }

    /// Takes a `Worktree` rather than an ID so main's "no status" rule is enforced on the read
    /// path too: `setStatus` refuses main, but a hand-edited or merged `groups.json` can still
    /// carry its path into `migrateLegacyStatuses`, which deliberately does not filter it out,
    /// and no gesture in the app could then clear it. Honouring it would drop main out of the
    /// top of the by-status order and move `⌘1` with it.
    func status(for wt: Worktree) -> WorktreeStatus? {
        wt.isMain ? nil : statuses[wt.id]
    }

    /// Publishes the status at once and writes it to the worktree's own git config behind the
    /// write chain, on the same terms as `setName`. Clears both when `status` is `nil`. The main
    /// worktree can never carry one, so it is silently ignored.
    func setStatus(_ status: WorktreeStatus?, for wt: Worktree) {
        guard !wt.isMain, let path = wt.path else { return }
        guard statuses[wt.id] != status else { return }
        statuses[wt.id] = status
        enqueueWrite { configStore in
            await configStore.set(
                status?.rawValue,
                forKey: WorktreeConfigStore.statusKey,
                worktreeAt: path
            )
        }
    }

    /// Takes a `Worktree` so main's "no name" rule is enforced on the read path too, on the same
    /// terms as `status(for:)`. Every writer of `names` trims first and drops what is left empty,
    /// so there is nothing to normalise here.
    func name(for wt: Worktree) -> String? {
        wt.isMain ? nil : names[wt.id]
    }

    /// Publishes the name at once and writes it to the worktree's own git config behind the write
    /// chain, so the sidebar never waits on `git`. A `nil`, empty or whitespace-only name clears
    /// both. The main worktree can never carry one, so it is silently ignored.
    func setName(_ name: String?, for wt: Worktree) {
        guard !wt.isMain, let path = wt.path else { return }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = trimmed.isEmpty ? nil : trimmed
        guard names[wt.id] != stored else { return }
        if let stored {
            names[wt.id] = stored
        } else {
            names.removeValue(forKey: wt.id)
        }
        enqueueWrite { configStore in
            await configStore.set(trimmed, forKey: WorktreeConfigStore.nameKey, worktreeAt: path)
        }
    }

    func setGrouping(_ grouping: WorktreeGrouping) {
        guard grouping != self.grouping else { return }
        self.grouping = grouping
        save()
    }

    /// Strips any grouped or ordered worktree ID that is no longer present in the live list, and
    /// re-reads the live worktrees' own git config. Saves only if any IDs were removed; the
    /// config reload runs either way, because it is what publishes a name or status written
    /// outside this manager's lifetime. Names and statuses are never pruned here — `git worktree
    /// remove` deletes the worktree's `config.worktree` with it.
    func reconcile(_ worktrees: [Worktree]) {
        Task { await self.reloadConfig(for: worktrees) }
        let knownWorktreeIds = Set(worktrees.map(\.id))
        var updated = groups
        var changed = false
        for index in updated.indices {
            let before = updated[index].worktreeIds
            let after = before.filter { knownWorktreeIds.contains($0) }
            if after != before {
                updated[index].worktreeIds = after
                changed = true
            }
        }
        let prunedDefault = defaultOrder.filter { knownWorktreeIds.contains($0) }
        let defaultChanged = prunedDefault != defaultOrder
        guard changed || defaultChanged else { return }
        groups = updated
        defaultOrder = prunedDefault
        save()
    }

    /// True when the worktree should survive the sidebar's search field.
    ///
    /// An empty query matches everything. Otherwise the query is compared, case-insensitively,
    /// against the worktree's display name, its stored name, the task title the caller resolved
    /// for its branch, the name of the group holding it, and its status's display name.
    func matches(_ wt: Worktree, query: String, taskTitle: String?) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if wt.displayName.localizedCaseInsensitiveContains(query) { return true }
        if let name = name(for: wt), name.localizedCaseInsensitiveContains(query) { return true }
        if let taskTitle, taskTitle.localizedCaseInsensitiveContains(query) { return true }
        if let group = groups.first(where: { $0.worktreeIds.contains(wt.id) }),
           group.name.localizedCaseInsensitiveContains(query) { return true }
        if let status = status(for: wt),
           status.displayName.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    /// Returns worktrees in the order used by both the sidebar and keyboard shortcuts.
    ///
    /// Default-section worktrees (ungrouped, including main) come first, followed by each
    /// group's worktrees in `createdAt` ascending order. Within the default section the
    /// main worktree is pinned first, then entries follow `defaultOrder`; any ungrouped
    /// worktree not yet recorded in `defaultOrder` (newly created) is appended in
    /// `Worktree.sorted` order. Within a group, `worktreeIds` is the canonical order.
    /// The `matches` closure acts as the search predicate.
    ///
    /// The view mode is this manager's own `grouping` rather than a parameter, for the same
    /// reason `Worktree.visible` is applied here: the rows, the ⌘N badge and the ⌘1…9 buttons
    /// must not be able to disagree about which worktrees exist or in what order. For the same
    /// reason no worktree is emitted twice, whatever a stored order records.
    /// `.group` and `.none` both return that order — they differ only in how the sidebar
    /// sections it. `.status` stably partitions it into no-status first then the five
    /// statuses in `allCases` order, so each bucket keeps its members' relative order and
    /// main (which `status(for:)` never reports a status for) stays first.
    func sidebarOrderedWorktrees(
        _ worktrees: [Worktree],
        showingDetached: Bool,
        openIds: [String],
        matches: (Worktree) -> Bool
    ) -> [Worktree] {
        let worktrees = Worktree.visible(worktrees, showingDetached: showingDetached, openIds: openIds)

        // Default section: worktrees not in any group (includes main).
        let defaultSlice = worktrees.filter { groupId(for: $0.id) == nil }
        let defaultById = Dictionary(uniqueKeysWithValues: defaultSlice.map { ($0.id, $0) })
        let main = defaultSlice.first(where: { $0.isMain })
        let orderedNonMain = defaultOrder.compactMap { id -> Worktree? in
            guard let wt = defaultById[id], !wt.isMain else { return nil }
            return wt
        }
        let knownDefaultIds = Set(defaultOrder).union(main.map { [$0.id] } ?? [])
        let newDefault = defaultSlice.filter { !knownDefaultIds.contains($0.id) && !$0.isMain }
        let sortedNew = Worktree.sorted(newDefault, openIds: openIds)
        var result: [Worktree] = []
        if let main { result.append(main) }
        result.append(contentsOf: orderedNonMain)
        result.append(contentsOf: sortedNew)
        result = result.filter(matches)

        // Group sections in createdAt ascending order (groups is already sorted).
        for group in groups {
            let groupById = Dictionary(
                uniqueKeysWithValues: worktrees
                    .filter { group.worktreeIds.contains($0.id) }
                    .map { ($0.id, $0) }
            )
            let ordered = group.worktreeIds.compactMap { groupById[$0] }
            let unknown = worktrees.filter { wt in
                group.worktreeIds.contains(wt.id) == false &&
                groupId(for: wt.id) == group.id
            }
            let sortedUnknown = Worktree.sorted(unknown, openIds: openIds)
            result.append(contentsOf: (ordered + sortedUnknown).filter(matches))
        }

        let ordered = Self.deduplicated(result)
        guard grouping == .status else { return ordered }
        return partitionedByStatus(ordered)
    }

    /// Emits each worktree once, keeping its first position. A `groups.json` can record the
    /// same id twice in `defaultOrder` or in a group's `worktreeIds` (see `repositioned`), and a
    /// row emitted twice traps `SidebarView.shortcutIndexes` on its uniquely-keyed dictionary.
    private static func deduplicated(_ worktrees: [Worktree]) -> [Worktree] {
        var seen = Set<String>()
        return worktrees.filter { seen.insert($0.id).inserted }
    }

    /// `Dictionary(grouping:)` keeps each bucket in input order, so the partition is stable.
    private func partitionedByStatus(_ worktrees: [Worktree]) -> [Worktree] {
        let buckets = Dictionary(grouping: worktrees) { status(for: $0) }
        return (buckets[nil] ?? []) + WorktreeStatus.allCases.flatMap { buckets[$0] ?? [] }
    }

    // MARK: - Worktree config

    /// Re-reads every non-main worktree's `clearway.*` config, one process per worktree and all of
    /// them concurrently. Awaiting the write chain first is what stops the reload a freshly
    /// created worktree triggers from publishing over a name that has not been written yet.
    private func reloadConfig(for worktrees: [Worktree]) async {
        await writeChain?.value
        let targets = worktrees.compactMap { wt -> (id: String, path: String)? in
            guard !wt.isMain, let path = wt.path else { return nil }
            return (wt.id, path)
        }
        let configStore = configStore
        var reloadedNames: [String: String] = [:]
        var reloadedStatuses: [String: WorktreeStatus] = [:]
        await withTaskGroup(of: (String, [String: String]).self) { group in
            for target in targets {
                group.addTask { (target.id, await configStore.values(forWorktreeAt: target.path)) }
            }
            for await (id, values) in group {
                // Trimmed here because this is where a hand-written config value enters the map,
                // and `name(for:)` and the sidebar both rely on what it holds already being clean.
                let name = values[WorktreeConfigStore.nameKey]?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty { reloadedNames[id] = name }
                // An unrecognised slug is dropped rather than published, the same rule the payload's
                // decoder applied while `groups.json` held these.
                if let slug = values[WorktreeConfigStore.statusKey],
                   let status = WorktreeStatus(rawValue: slug) {
                    reloadedStatuses[id] = status
                }
            }
        }
        if reloadedNames != names { names = reloadedNames }
        if reloadedStatuses != statuses { statuses = reloadedStatuses }
    }

    /// The one-shot migration of statuses out of `groups.json`. They are published before any
    /// subprocess runs, so a launch is never briefly unstatused, enqueued on the write chain that
    /// the first reload awaits, and the file is rewritten at once without the key. A key that is
    /// no longer a worktree path fails inside `git` and is skipped.
    private func migrateLegacyStatuses(_ legacy: [String: WorktreeStatus]) {
        guard !legacy.isEmpty else { return }
        statuses = legacy
        enqueueWrite { configStore in
            for (path, status) in legacy {
                await configStore.set(
                    status.rawValue,
                    forKey: WorktreeConfigStore.statusKey,
                    worktreeAt: path
                )
            }
        }
        save()
    }

    /// Serialises config writes: each one awaits the previous, so two gestures on the same key
    /// land in the order they were made and a read can await the whole chain. The store is handed
    /// to `work` rather than captured by it, because a `@MainActor` caller cannot reach `self` from
    /// inside the `@Sendable` body.
    private func enqueueWrite(_ work: @escaping @Sendable (WorktreeConfigStore) async -> Void) {
        let previous = writeChain
        let configStore = configStore
        writeChain = Task {
            await previous?.value
            await work(configStore)
        }
    }

    // MARK: - Private Helpers

    /// Places `ids` into the slots `stored` gives them, in the new order, leaving every other
    /// stored ID where it was. IDs `stored` does not hold yet are appended.
    private static func repositioned(_ stored: [String], with ids: [String]) -> [String] {
        let moving = Set(ids)
        var incoming = ids[...]
        var result: [String] = []
        for id in stored {
            if moving.contains(id) {
                // A slot with no id left to take it is a duplicate of one already placed; dropping
                // it heals a `groups.json` that recorded the same id twice.
                if let next = incoming.popFirst() { result.append(next) }
            } else {
                result.append(id)
            }
        }
        result.append(contentsOf: incoming)
        return result
    }

    /// Fire-and-forget save. Logs errors; does not crash or revert in-memory state.
    private func save() {
        let payload = WorktreeGroupsPayload(
            groups: groups,
            defaultOrder: defaultOrder,
            grouping: grouping
        )
        Task {
            do {
                try await store.save(payload)
            } catch {
                Ghostty.logger.error("WorktreeGroupManager: failed to save groups: \(error)")
            }
        }
    }
}
