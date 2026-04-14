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

    private let store: WorktreeGroupStore

    init(projectPath: String) {
        self.store = WorktreeGroupStore(projectPath: projectPath)

        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.store.load()
            self.groups = WorktreeGroup.sortedByCreation(loaded)

            self.store.startWatching { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let reloaded = await self.store.load()
                    let sorted = WorktreeGroup.sortedByCreation(reloaded)
                    guard sorted != self.groups else { return }
                    self.groups = sorted
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
        save()
    }

    /// Removes a worktree ID from every group it appears in.
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
        guard changed else { return }
        groups = updated
        save()
    }

    /// Returns worktrees in the order used by both the sidebar and keyboard shortcuts.
    ///
    /// Default-section worktrees (ungrouped, including main) come first, followed by each
    /// group's worktrees in `createdAt` ascending order. Within each slice, ordering follows
    /// `Worktree.sorted(_:openIds:)`. The `matches` closure acts as the search predicate;
    /// callers supply the closure (including the empty-search bypass) to decouple this
    /// manager from subtitle data sources.
    func sidebarOrderedWorktrees(
        _ worktrees: [Worktree],
        openIds: [String],
        matches: (Worktree) -> Bool
    ) -> [Worktree] {
        // Default section: worktrees not in any group (includes main).
        let defaultSlice = worktrees.filter { groupId(for: $0.id) == nil }
        let sortedDefault = Worktree.sorted(defaultSlice, openIds: openIds).filter(matches)

        // Group sections in createdAt ascending order (groups is already sorted).
        var result = sortedDefault
        for group in groups {
            let groupSlice = worktrees.filter { group.worktreeIds.contains($0.id) }
            let sortedGroup = Worktree.sorted(groupSlice, openIds: openIds).filter(matches)
            result.append(contentsOf: sortedGroup)
        }

        return result
    }

    // MARK: - Private Helpers

    /// Fire-and-forget save. Logs errors; does not crash or revert in-memory state.
    private func save() {
        let snapshot = groups
        Task {
            do {
                try await store.save(snapshot)
            } catch {
                Ghostty.logger.error("WorktreeGroupManager: failed to save groups: \(error)")
            }
        }
    }
}
