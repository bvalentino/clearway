import SwiftUI

/// A worktree's workflow state. The case names are the slugs persisted in a project's
/// `groups.json`, so renaming one changes the on-disk format.
enum WorktreeStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case todo
    case inProgress
    case inReview
    case done
    case onHold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .todo: return "Todo"
        case .inProgress: return "In progress"
        case .inReview: return "In review"
        case .done: return "Done"
        case .onHold: return "On hold"
        }
    }

    var color: Color {
        switch self {
        case .todo: return .gray
        case .inProgress: return .blue
        case .inReview: return .purple
        case .done: return .green
        case .onHold: return .orange
        }
    }
}

/// How the sidebar sections its worktrees. Persisted beside the statuses under the same slug rule.
enum WorktreeGrouping: String, Codable, CaseIterable, Identifiable, Hashable {
    case group
    case status
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .group: return "Group"
        case .status: return "Status"
        case .none: return "None"
        }
    }
}
