import SwiftUI

/// Displays agent metadata for a task: the attempt count.
/// Shared between `TaskAsideView` (aside panel) and `WorkTaskWindow` (task editor window).
struct WorkTaskAgentMetadata: View {
    let task: WorkTask

    static func hasContent(for task: WorkTask) -> Bool {
        (task.attempt ?? 0) > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attempt = task.attempt, attempt > 0 {
                Label("Attempt \(attempt + 1)", systemImage: "arrow.counterclockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
