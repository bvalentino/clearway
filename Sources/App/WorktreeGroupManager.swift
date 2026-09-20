import Foundation
import os
import SwiftUI

// MARK: - Manager

/// Manages the in-memory state of worktree groups for a single project.
///
/// All mutations go through this class; every value it owns lives in git config, reached through
/// `WorktreeConfigStore`. The registry — the repo-level `clearway.groupOrder` — is the only source
/// of which groups exist, and `groups` holds it in registry order.
@MainActor
final class WorktreeGroupManager: ObservableObject {
    @Published private(set) var groups: [WorktreeGroup] = []

    /// Where each non-main worktree sits in the sidebar. A drop changes both halves at once, and
    /// `mutatePlacement` is the only way either changes, so one gesture publishes one value.
    private struct Placement: Equatable {
        /// Group membership, keyed by `Worktree.id`, backed by each worktree's own
        /// `clearway.group`. A worktree naming a group the registry does not list is absent here,
        /// so it renders ungrouped. Main is never a key.
        var groupNames: [String: String] = [:]
        /// Position within a section, keyed by `Worktree.id` and backed by each worktree's own
        /// `clearway.position`. A worktree without one sorts after those that have one. Main is
        /// never a key.
        var positions: [String: Int] = [:]
    }

    @Published private var placement = Placement()

    var groupNames: [String: String] { placement.groupNames }
    var positions: [String: Int] { placement.positions }

    /// Per-worktree status, keyed by `Worktree.id`, backed by each worktree's own git config.
    /// Main is never a key.
    @Published private(set) var statuses: [String: WorktreeStatus] = [:]
    /// Per-worktree display name, keyed by `Worktree.id`, backed by each worktree's own git
    /// config. Main is never a key.
    @Published private(set) var names: [String: String] = [:]
    /// The axis the sidebar sections its worktrees by.
    @Published private(set) var grouping: WorktreeGrouping = .group

    /// Shows the user that a rename or delete abandoned its registry write. Defaults to the real
    /// alert, so production wires nothing; the test base replaces it, because a modal raised on the
    /// write chain would stall the chain the rest of a test waits on.
    var presentWriteAlert: @MainActor @Sendable (WorktreeGroupWriteAlert) -> Void = { $0.present() }

    private let configStore: WorktreeConfigStore

    /// Config writes run one after another, and every config read awaits the chain first.
    /// Creating a worktree writes a name and also changes the live worktree list, which fires the
    /// reload in the same turn; without the chain that reload can read the worktree's config
    /// before the write lands and publish an empty name over the one just typed.
    private var writeChain: Task<Void, Never>?

    /// The initial load, awaited by every config read — and by the test base, which must not
    /// mutate state the load would then republish over.
    private(set) var loadTask: Task<Void, Never>?

    init(projectPath: String) {
        self.configStore = WorktreeConfigStore(projectPath: projectPath)

        loadTask = Task { [weak self] in
            guard let self else { return }
            let configStore = self.configStore
            async let modeRead = configStore.localValue(forKey: WorktreeConfigStore.groupingKey)
            async let registryRead = configStore.localValues(forKey: WorktreeConfigStore.groupOrderKey)
            let mode = await modeRead
            let registry = await registryRead
            // A gesture made while the two reads were in flight has already published and queued
            // its write, and publishing what git held before it would drop it for the session —
            // the guard `reloadConfig` makes against the same race.
            guard self.writeChain == nil else { return }
            if let mode, let grouping = WorktreeGrouping(rawValue: mode) {
                self.grouping = grouping
            }
            if let registry { self.groups = Self.registered(registry) }
        }
    }

    // MARK: - Public API

    /// Creates a new group with the given name, trimmed, and appends it to the registry.
    ///
    /// A group is identified by its name, so a name `WorktreeGroup.available` rejects creates
    /// nothing: the name-keyed lookups below would otherwise be ambiguous whenever a call site
    /// forgot to check.
    func createGroup(named name: String) {
        guard let trimmed = WorktreeGroup.available(name, in: groups.map(\.name)) else { return }
        groups.append(WorktreeGroup(name: trimmed))
        writeRegistry(affecting: trimmed)
    }

    /// Renames the group with the given name. No-ops if no group carries it, or if the new name
    /// is one `createGroup` would have refused.
    func renameGroup(named name: String, to newName: String) {
        guard let index = groups.firstIndex(where: { $0.name == name }),
              let trimmed = WorktreeGroup.available(newName, in: groups.map(\.name), renaming: name)
        else { return }
        let members = members(ofGroupNamed: name)
        groups[index].name = trimmed
        mutatePlacement { placement in
            for id in members { placement.groupNames[id] = trimmed }
        }
        writeRegistry(affecting: trimmed, settingGroup: trimmed, on: members)
    }

    /// Deletes the group with the given name. No-ops if no group carries it.
    ///
    /// Its members are appended to the ungrouped section, keeping their order, the way
    /// `removeWorktreeFromGroup` appends one: every section numbers its positions from zero, so
    /// members carrying their in-group values into the ungrouped one would share slots with the
    /// rows already there and be interleaved among them on every launch.
    func deleteGroup(named name: String) {
        guard groups.contains(where: { $0.name == name }) else { return }
        let members = members(ofGroupNamed: name)
        var next = (maxPosition(inSectionNamed: nil) ?? -1) + 1
        var appended: [String: Int] = [:]
        for id in members {
            appended[id] = next
            next += 1
        }
        groups.removeAll { $0.name == name }
        mutatePlacement { placement in
            for id in members { placement.groupNames.removeValue(forKey: id) }
            for (id, position) in appended { placement.positions[id] = position }
        }
        writePositions(appended)
        writeRegistry(affecting: name, settingGroup: nil, on: members)
    }

    /// Adds a worktree to the specified group, at the end of it.
    ///
    /// The main worktree is silently ignored — it can never be placed in a group. So is a group
    /// the registry does not list, which would otherwise render its member ungrouped.
    func addWorktree(_ wt: Worktree, toGroupNamed name: String) {
        guard !wt.isMain, let path = wt.path, groups.contains(where: { $0.name == name }) else { return }
        // No-op when the worktree is already in the target group. Without this guard,
        // SwiftUI's List animates a remove+insert round-trip that can crash the backing
        // NSTableView mid-drag when the drop lands on the worktree's own group header.
        guard groupNames[wt.id] != name else { return }
        let position = (maxPosition(inSectionNamed: name) ?? -1) + 1
        mutatePlacement { placement in
            placement.groupNames[wt.id] = name
            placement.positions[wt.id] = position
        }
        enqueueWrite { configStore in
            await Self.write(name, forKey: WorktreeConfigStore.groupKey, worktreeAt: path, in: configStore)
            await Self.write(
                String(position),
                forKey: WorktreeConfigStore.positionKey,
                worktreeAt: path,
                in: configStore
            )
        }
    }

    /// Removes the worktree from its group and appends it to the ungrouped section.
    func removeWorktreeFromGroup(_ wt: Worktree) {
        guard let path = wt.path, groupNames[wt.id] != nil else { return }
        let position = (maxPosition(inSectionNamed: nil) ?? -1) + 1
        mutatePlacement { placement in
            placement.groupNames.removeValue(forKey: wt.id)
            placement.positions[wt.id] = position
        }
        enqueueWrite { configStore in
            await Self.write(nil, forKey: WorktreeConfigStore.groupKey, worktreeAt: path, in: configStore)
            await Self.write(
                String(position),
                forKey: WorktreeConfigStore.positionKey,
                worktreeAt: path,
                in: configStore
            )
        }
    }

    /// Repositions the given non-main worktree IDs within the ungrouped section's order.
    /// Callers pass the rows the sidebar rendered, which is a subset whenever the detached
    /// filter or the search field hides one, so IDs the caller omits keep their slot.
    ///
    /// `worktrees` is the whole live list, not the rendered subset: the slots being reassigned are
    /// the ones the section occupies on screen, and a row the caller omitted has to be in it to
    /// keep the slot it had.
    func setUngroupedOrder(_ ids: [String], in worktrees: [Worktree], openIds: [String]) {
        applyPositions(
            Self.reassignedPositions(
                section: section(named: nil, in: worktrees, openIds: openIds),
                newOrder: ids
            )
        )
    }

    /// Repositions the given worktree IDs within a group, on the same terms as `setUngroupedOrder`.
    func setGroupOrder(named name: String, ids: [String], in worktrees: [Worktree], openIds: [String]) {
        guard groups.contains(where: { $0.name == name }) else { return }
        applyPositions(
            Self.reassignedPositions(
                section: section(named: name, in: worktrees, openIds: openIds),
                newOrder: ids
            )
        )
    }

    /// Gives every non-main worktree that has no position one, so click-to-open never re-sorts the
    /// sidebar. The second half of `reconcile`, which is the only caller that is not a test.
    /// Idempotent: a worktree that already carries one is left alone. New IDs are
    /// appended to their own section in `Worktree.sorted` order — the same rule
    /// `sidebarOrderedWorktrees` renders them by while they are unpositioned.
    func seedPositions(for worktrees: [Worktree], openIds: [String]) {
        let missing = worktrees.filter { !$0.isMain && $0.path != nil && positions[$0.id] == nil }
        guard !missing.isEmpty else { return }
        var next: [String?: Int] = [:]
        var seeded: [String: Int] = [:]
        for wt in Worktree.sorted(missing, openIds: openIds) {
            let section = groupNames[wt.id]
            let position = next[section] ?? (maxPosition(inSectionNamed: section) ?? -1) + 1
            seeded[wt.id] = position
            next[section] = position + 1
        }
        applyPositions(seeded)
    }

    func groupName(for worktreeId: String) -> String? {
        groupNames[worktreeId]
    }

    /// Takes a `Worktree` rather than an ID so main's "no status" rule is enforced on the read
    /// path too: `setStatus` refuses main, and so does the read path, but honouring a status
    /// hand-written into main's own config would drop it out of the top of the by-status order
    /// and move `⌘1` with it.
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
            await configStore.set(stored, forKey: WorktreeConfigStore.nameKey, worktreeAt: path)
        }
    }

    func setGrouping(_ grouping: WorktreeGrouping) {
        guard grouping != self.grouping else { return }
        self.grouping = grouping
        enqueueWrite { configStore in
            let wrote = await configStore.setLocal(grouping.rawValue, forKey: WorktreeConfigStore.groupingKey)
            if !wrote { Self.logFailure("clearway.grouping was not saved") }
        }
    }

    /// Re-reads what git holds for the live worktrees and then gives any worktree still without a
    /// position one. Nothing is pruned: a worktree that has gone simply stops being read, and
    /// `git worktree remove` deletes its `config.worktree` with it.
    ///
    /// The seed runs **after** the reload, which is why the two are one entry point rather than two
    /// calls a view makes in a row: on a relaunch `positions` is empty until the reload publishes
    /// it, so a seed racing ahead of it renumbers every worktree in `Worktree.sorted` order and the
    /// reload reads the values it just wrote back over the user's order.
    func reconcile(_ worktrees: [Worktree], openIds: [String]) {
        Task {
            await self.reloadConfig(for: worktrees)
            self.seedPositions(for: worktrees, openIds: openIds)
        }
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
        if let group = groupName(for: wt.id),
           group.localizedCaseInsensitiveContains(query) { return true }
        if let status = status(for: wt),
           status.displayName.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    /// Returns worktrees in the order used by both the sidebar and keyboard shortcuts.
    ///
    /// Ungrouped worktrees (including main) come first, followed by each group's worktrees in
    /// registry order. Within a section the main worktree is pinned first, then entries follow
    /// `positions` ascending; a worktree without a position follows those that have one, in
    /// `Worktree.sorted` order, which is also the tie-break. The `matches` closure acts as the
    /// search predicate.
    ///
    /// The view mode is this manager's own `grouping` rather than a parameter, for the same
    /// reason `Worktree.visible` is applied here: the rows, the ⌘N badge and the ⌘1…9 buttons
    /// must not be able to disagree about which worktrees exist or in what order.
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

        let ungrouped = worktrees.filter { groupNames[$0.id] == nil }
        var result: [Worktree] = []
        if let main = ungrouped.first(where: { $0.isMain }) { result.append(main) }
        result.append(contentsOf: ordered(ungrouped.filter { !$0.isMain }, openIds: openIds))
        result = result.filter(matches)

        for group in groups {
            let members = worktrees.filter { groupNames[$0.id] == group.name }
            result.append(contentsOf: ordered(members, openIds: openIds).filter(matches))
        }

        guard grouping == .status else { return result }
        return partitionedByStatus(result)
    }

    /// `Dictionary(grouping:)` keeps each bucket in input order, so the partition is stable.
    private func partitionedByStatus(_ worktrees: [Worktree]) -> [Worktree] {
        let buckets = Dictionary(grouping: worktrees) { status(for: $0) }
        return (buckets[nil] ?? []) + WorktreeStatus.allCases.flatMap { buckets[$0] ?? [] }
    }

    // MARK: - Worktree config

    /// Re-reads the repo-level registry and every non-main worktree's `clearway.*` config, one
    /// process per worktree and all of them concurrently — the two repo-level reads included, since
    /// neither depends on the other — and publishes the result.
    ///
    /// The reads are bracketed by the write chain rather than merely preceded by it: awaiting it
    /// first is what stops a freshly created worktree's reload from reading before the name lands,
    /// and re-checking it afterwards is what stops a rename made *during* the reads from being
    /// published over by the older values. Nothing re-reads until the worktree list changes again,
    /// so a lost gesture would stay lost for the session.
    private func reloadConfig(for worktrees: [Worktree]) async {
        let targets = worktrees.compactMap { wt -> (id: String, path: String)? in
            guard !wt.isMain, let path = wt.path else { return nil }
            return (wt.id, path)
        }
        let configStore = configStore
        while true {
            await loadTask?.value
            let chain = writeChain
            await chain?.value
            async let modeRead = configStore.localValue(forKey: WorktreeConfigStore.groupingKey)
            async let registryRead = configStore.localValues(forKey: WorktreeConfigStore.groupOrderKey)
            let reloaded = await readConfig(for: targets)
            let mode = await modeRead
            let registry = await registryRead
            guard writeChain == chain else { continue }

            if let mode, let grouping = WorktreeGrouping(rawValue: mode), grouping != self.grouping {
                self.grouping = grouping
            }
            let reloadedGroups = registry.map(Self.registered) ?? groups
            if reloadedGroups != groups { groups = reloadedGroups }
            // The registry is the only source of which groups exist, so a membership naming one it
            // does not list is dropped rather than rendering a phantom section.
            let listed = Set(reloadedGroups.map(\.name))
            let reloadedNames = reloaded.groupNames.filter { listed.contains($0.value) }
            mutatePlacement { placement in
                placement.groupNames = reloadedNames
                placement.positions = reloaded.positions
            }
            if reloaded.names != names { names = reloaded.names }
            if reloaded.statuses != statuses { statuses = reloaded.statuses }
            return
        }
    }

    /// What one `--worktree --list` read per worktree yields, split by key.
    private struct WorktreeConfig {
        var names: [String: String] = [:]
        var statuses: [String: WorktreeStatus] = [:]
        var groupNames: [String: String] = [:]
        var positions: [String: Int] = [:]
    }

    /// A worktree whose read failed keeps what is published: `values(forWorktreeAt:)` answers
    /// `nil` only when git could not say what is stored, and treating that as "stores nothing"
    /// would clear a name from the sidebar that git still holds.
    private func readConfig(for targets: [(id: String, path: String)]) async -> WorktreeConfig {
        let configStore = configStore
        var read: [(id: String, values: [String: String]?)] = []
        await withTaskGroup(of: (String, [String: String]?).self) { group in
            for target in targets {
                group.addTask { (target.id, await configStore.values(forWorktreeAt: target.path)) }
            }
            for await (id, values) in group { read.append((id, values)) }
        }

        var reloaded = WorktreeConfig()
        for (id, values) in read {
            guard let values else {
                reloaded.names[id] = names[id]
                reloaded.statuses[id] = statuses[id]
                reloaded.groupNames[id] = groupNames[id]
                reloaded.positions[id] = positions[id]
                continue
            }
            // Trimmed here because this is where a hand-written config value enters the map,
            // and `name(for:)` and the sidebar both rely on what it holds already being clean.
            let name = values[WorktreeConfigStore.nameKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { reloaded.names[id] = name }
            // An unrecognised slug is dropped rather than published: `config.worktree` is
            // hand-editable and a slug rename is a format change.
            if let slug = values[WorktreeConfigStore.statusKey],
               let status = WorktreeStatus(rawValue: slug) {
                reloaded.statuses[id] = status
            }
            // Compared against the registry exactly, so a stored name is either one of the groups
            // or nothing — there is no normalisation that could make a near-miss match.
            if let group = values[WorktreeConfigStore.groupKey], !group.isEmpty {
                reloaded.groupNames[id] = group
            }
            if let raw = values[WorktreeConfigStore.positionKey], let position = Int(raw) {
                reloaded.positions[id] = position
            }
        }
        return reloaded
    }

    /// Serialises config writes: each one awaits the previous, so two gestures on the same key
    /// land in the order they were made and a read can await the whole chain. The store is handed
    /// to `work` rather than captured by it, so the common case reaches it without capturing the
    /// manager at all from inside the `@Sendable` body.
    private func enqueueWrite(_ work: @escaping @Sendable (WorktreeConfigStore) async -> Void) {
        let previous = writeChain
        let configStore = configStore
        writeChain = Task {
            await previous?.value
            await work(configStore)
        }
    }

    /// Names the gesture a failed config write lost. `WorktreeConfigStore` has already logged why
    /// git refused, under its own `worktree config:` prefix, and hands back only a `Bool` — so this
    /// line cannot repeat it. The message is public because the worktree it names is the point of
    /// it; a release build would otherwise redact the path.
    private nonisolated static func logFailure(_ message: String) {
        Ghostty.logger.warning("worktree groups: \(message, privacy: .public)")
    }

    /// Writes one worktree-scoped value, naming the gesture if git refused.
    ///
    /// `writeRegistry`'s member write stays bespoke: it abandons the loop and raises an alert, and
    /// its one line names both the registry it gave up on and the member write that lost it.
    private nonisolated static func write(
        _ value: String?,
        forKey key: String,
        worktreeAt path: String,
        in configStore: WorktreeConfigStore
    ) async {
        let wrote = await configStore.set(value, forKey: key, worktreeAt: path)
        if !wrote { logFailure("\(key) for \(path) was not saved") }
    }

    /// Writes `name` to each member's `clearway.group` — `nil` clears it — and then rewrites the
    /// registry, and only if every member write landed: a worktree naming an unlisted group renders
    /// ungrouped, so a half-applied rename that published the registry first would empty the group
    /// on the next launch.
    ///
    /// `group` is the group the gesture acted on, which the member value is not: a delete writes
    /// `nil` to its members and the alert must still name what was deleted.
    private func writeRegistry(
        affecting group: String,
        settingGroup name: String? = nil,
        on members: [String] = []
    ) {
        let registry = groups.map(\.name)
        let presentAlert = presentWriteAlert
        enqueueWrite { configStore in
            for path in members {
                guard await configStore.set(name, forKey: WorktreeConfigStore.groupKey, worktreeAt: path)
                else {
                    Self.logFailure(
                        "clearway.groupOrder was not rewritten: clearway.group for \(path) was not saved"
                    )
                    // Awaited, not fired and forgotten: nothing should keep writing behind a
                    // message saying a write failed.
                    await presentAlert(WorktreeGroupWriteAlert(group: group, path: path))
                    return
                }
            }
            let wrote = await configStore.replaceLocalValues(registry, forKey: WorktreeConfigStore.groupOrderKey)
            if !wrote { Self.logFailure("clearway.groupOrder was not saved") }
        }
    }

    // MARK: - Ordering

    /// Places `ids` into the slots `stored` gives them, in the new order, leaving every other
    /// stored ID where it was. IDs `stored` does not hold yet are appended.
    static func repositioned(_ stored: [String], with ids: [String]) -> [String] {
        let moving = Set(ids)
        var incoming = ids[...]
        var result: [String] = []
        for id in stored {
            if moving.contains(id) {
                // A slot with no id left to take it is a duplicate of one already placed; dropping
                // it heals a stored order that recorded the same id twice.
                if let next = incoming.popFirst() { result.append(next) }
            } else {
                result.append(id)
            }
        }
        result.append(contentsOf: incoming)
        return result
    }

    /// The position each member of `section` should carry once the rendered rows have been moved
    /// into `newOrder`, limited to the ones that changed.
    ///
    /// A drag reassigns exactly the values the section already occupied: the permuted IDs take
    /// them in ascending order, so a row the caller omitted — hidden by the detached filter or the
    /// search field — keeps the slot it had. A member without a value, and any ID the section did
    /// not hold, takes the next integer above the section's maximum. A value two members share
    /// counts once, so a section that came to hold a duplicate is healed by the first drag rather
    /// than handed the same collision back.
    static func reassignedPositions(
        section: [(id: String, position: Int?)],
        newOrder: [String]
    ) -> [String: Int] {
        let permuted = repositioned(section.map(\.id), with: newOrder)
        var pool = Set(section.compactMap(\.position)).sorted()
        var next = (pool.last ?? -1) + 1
        while pool.count < permuted.count {
            pool.append(next)
            next += 1
        }
        let current = Dictionary(section.map { ($0.id, $0.position) }, uniquingKeysWith: { lhs, _ in lhs })
        var changed: [String: Int] = [:]
        for (id, position) in zip(permuted, pool) where (current[id] ?? nil) != position {
            changed[id] = position
        }
        return changed
    }

    // MARK: - Private Helpers

    /// The registry as groups, in file order, without a repeat or a blank — a hand-edited
    /// `.git/config` can hold either. Two sections with the same `id` trap the sidebar's `ForEach`,
    /// and a blank one renders a nameless section whose drops `set` discards as a clear.
    private static func registered(_ names: [String]) -> [WorktreeGroup] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }.map(WorktreeGroup.init(name:))
    }

    /// A member's ID is its path: `Worktree.id` is the path for every worktree that has one, and
    /// both writers of `groupNames` skip a worktree that has none. Ordered by position so a delete
    /// renumbers them into the ungrouped section in the order the group showed them.
    private func members(ofGroupNamed name: String) -> [String] {
        groupNames.compactMap { $0.value == name ? $0.key : nil }
            .sorted { (positions[$0] ?? Int.max, $0) < (positions[$1] ?? Int.max, $1) }
    }

    /// `nil` names the ungrouped section.
    private func maxPosition(inSectionNamed name: String?) -> Int? {
        positions.compactMap { groupNames[$0.key] == name ? $0.value : nil }.max()
    }

    /// The section's members in the order the sidebar renders them, for `reassignedPositions`.
    /// `nil` names the ungrouped section; main is never a member, since it is pinned first and
    /// carries no position.
    ///
    /// Ordered by `ordered` rather than by ID: the slots a drag reassigns are the ones the rows
    /// occupy on screen, and an unpositioned row sits where `Worktree.sorted` puts it. Sourced from
    /// the live worktrees rather than from `positions`, so an unpositioned ungrouped row is in its
    /// section on the same terms as an unpositioned member of a group.
    private func section(
        named name: String?,
        in worktrees: [Worktree],
        openIds: [String]
    ) -> [(id: String, position: Int?)] {
        let members = worktrees.filter { !$0.isMain && $0.path != nil && groupNames[$0.id] == name }
        return ordered(members, openIds: openIds).map { (id: $0.id, position: positions[$0.id]) }
    }

    private func mutatePlacement(_ change: (inout Placement) -> Void) {
        var next = placement
        change(&next)
        guard next != placement else { return }
        placement = next
    }

    private func applyPositions(_ changed: [String: Int]) {
        mutatePlacement { placement in
            for (id, position) in changed { placement.positions[id] = position }
        }
        writePositions(changed)
    }

    private func writePositions(_ changed: [String: Int]) {
        guard !changed.isEmpty else { return }
        enqueueWrite { configStore in
            for (path, position) in changed {
                await Self.write(
                    String(position),
                    forKey: WorktreeConfigStore.positionKey,
                    worktreeAt: path,
                    in: configStore
                )
            }
        }
    }

    /// Positions ascending, then the unpositioned; `Worktree.sorted` is both the fallback order
    /// and the tie-break, so `enumerated()` supplies a stable secondary key.
    private func ordered(_ worktrees: [Worktree], openIds: [String]) -> [Worktree] {
        Worktree.sorted(worktrees, openIds: openIds)
            .enumerated()
            .sorted { lhs, rhs in
                let left = positions[lhs.element.id] ?? Int.max
                let right = positions[rhs.element.id] ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }
}
