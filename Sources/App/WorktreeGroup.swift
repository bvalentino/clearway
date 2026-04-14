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
}
