import SwiftUI

/// Displays a task's attempt count. Shared between `TaskAsideView` (aside panel) and
/// `WorkTaskWindow` (task editor window), both of which gate on `hasContent(for:)`.
struct WorkTaskAgentMetadata: View {
    let task: WorkTask

    static func hasContent(for task: WorkTask) -> Bool {
        (task.attempt ?? 0) > 0
    }

    var body: some View {
        Label("Attempt \((task.attempt ?? 0) + 1)", systemImage: "arrow.counterclockwise")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
