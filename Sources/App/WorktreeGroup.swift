import Foundation

// MARK: - Model

struct WorktreeGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var worktreeIds: [String]
    let createdAt: Date
}

// MARK: - Helpers

extension WorktreeGroup {
    /// Returns groups sorted oldest-first by creation date.
    static func sortedByCreation(_ groups: [WorktreeGroup]) -> [WorktreeGroup] {
        groups.sorted { $0.createdAt < $1.createdAt }
    }

    /// Whether `name` may be created, or renamed to. `renaming` is the current name of the group
    /// being renamed, which is allowed to keep its own name.
    static func isNameAvailable(_ name: String, in existing: [String], renaming: String? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !existing.contains { $0 == trimmed && $0 != renaming }
    }
}
