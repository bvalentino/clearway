import SwiftUI

/// A worktree's workflow state. The case names are the slugs stored as `clearway.status` in each
/// worktree's own git config, so renaming one changes the stored format.
enum WorktreeStatus: String, CaseIterable, Identifiable, Hashable {
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
        case .inProgress: return .yellow
        case .inReview: return .green
        case .done: return .indigo
        case .onHold: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .todo: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .inReview: return "circle.inset.filled"
        case .done: return "checkmark.circle.fill"
        case .onHold: return "pause.circle"
        }
    }
}

/// One status as a picker row: the tinted symbol beside the display name. The sidebar's Status
/// submenu is its one renderer — an `NSMenu` cannot host a SwiftUI view, so the create sheet's
/// `FullWidthPicker` draws an `NSMenuItem` from the same `displayName` / `symbol` / `color`.
struct WorktreeStatusLabel: View {
    let status: WorktreeStatus

    var body: some View {
        Label {
            Text(status.displayName)
        } icon: {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
        }
    }
}

/// How the sidebar sections its worktrees. The case names are the slugs stored as the repo-level
/// `clearway.grouping`, under the same rule.
enum WorktreeGrouping: String, CaseIterable, Identifiable, Hashable {
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
