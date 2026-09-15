import SwiftUI

/// Displays a task's attempt count, for the views that show a started task's agent metadata.
struct WorkTaskAgentMetadata: View {
    let task: WorkTask

    static func hasContent(for task: WorkTask) -> Bool {
        (task.attempt ?? 0) > 0
    }

    var body: some View {
        if let attempt = task.attempt, attempt > 0 {
            Label("Attempt \(attempt + 1)", systemImage: "arrow.counterclockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
