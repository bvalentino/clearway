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

    private let store: WorktreeGroupStore

    init(projectPath: String) {
        self.store = WorktreeGroupStore(projectPath: projectPath)

        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.store.load()
            self.groups = WorktreeGroup.sortedByCreation(loaded.groups)
            self.defaultOrder = loaded.defaultOrder

            self.store.startWatching { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let reloaded = await self.store.load()
                    let sortedGroups = WorktreeGroup.sortedByCreation(reloaded.groups)
                    if sortedGroups != self.groups { self.groups = sortedGroups }
                    if reloaded.defaultOrder != self.defaultOrder {
                        self.defaultOrder = reloaded.defaultOrder
                    }
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

    /// Replaces the ungrouped section's order. Caller should pass non-main worktree
    /// IDs in their new display order.
    func setDefaultOrder(_ ids: [String]) {
        guard ids != defaultOrder else { return }
        defaultOrder = ids
        save()
    }

    /// Replaces the order of worktrees inside a group.
    func setGroupOrder(id groupId: UUID, ids: [String]) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        guard groups[index].worktreeIds != ids else { return }
        var updated = groups
        updated[index].worktreeIds = ids
        groups = updated
        save()
    }

    /// Returns the ID of the group that contains the given worktree ID, or `nil` if ungrouped.
    func groupId(for worktreeId: String) -> UUID? {
        groups.first(where: { $0.worktreeIds.contains(worktreeId) })?.id
    }

    /// Strips any stored worktree ID that is no longer present in the live list.
    /// Saves only if any IDs were removed.
    func reconcile(knownWorktreeIds: Set<String>) {
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

    /// Returns worktrees in the order used by both the sidebar and keyboard shortcuts.
    ///
    /// Default-section worktrees (ungrouped, including main) come first, followed by each
    /// group's worktrees in `createdAt` ascending order. Within the default section the
    /// main worktree is pinned first, then entries follow `defaultOrder`; any ungrouped
    /// worktree not yet recorded in `defaultOrder` (newly created) is appended in
    /// `Worktree.sorted` order. Within a group, `worktreeIds` is the canonical order.
    /// The `matches` closure acts as the search predicate.
    func sidebarOrderedWorktrees(
        _ worktrees: [Worktree],
        openIds: [String],
        matches: (Worktree) -> Bool
    ) -> [Worktree] {
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

        return result
    }

    // MARK: - Private Helpers

    /// Fire-and-forget save. Logs errors; does not crash or revert in-memory state.
    private func save() {
        let payload = WorktreeGroupsPayload(groups: groups, defaultOrder: defaultOrder)
        Task {
            do {
                try await store.save(payload)
            } catch {
                Ghostty.logger.error("WorktreeGroupManager: failed to save groups: \(error)")
            }
        }
    }
}
