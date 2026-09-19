import Foundation

// MARK: - Model

/// A sidebar group. The name is the identity: it is unique per repository, and it is what each
/// member worktree stores as `clearway.group`.
struct WorktreeGroup: Identifiable, Hashable {
    var name: String

    var id: String { name }
}

// MARK: - Helpers

extension WorktreeGroup {
    /// The name a group would be stored under, or `nil` when `name` may not be created or renamed
    /// to. `renaming` is the current name of the group being renamed, which may keep its own name.
    ///
    /// Returns the trimmed name rather than a `Bool` so the caller that stores it cannot normalise
    /// it differently from the caller that validated it — the name is the group's identity and what
    /// every member worktree stores as `clearway.group`.
    static func available(_ name: String, in existing: [String], renaming: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !existing.contains(where: { $0 == trimmed && $0 != renaming })
        else { return nil }
        return trimmed
    }
}
