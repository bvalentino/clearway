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
    /// Whether `name` may be created, or renamed to. `renaming` is the current name of the group
    /// being renamed, which is allowed to keep its own name.
    static func isNameAvailable(_ name: String, in existing: [String], renaming: String? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !existing.contains { $0 == trimmed && $0 != renaming }
    }
}
