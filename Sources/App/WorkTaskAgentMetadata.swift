import SwiftUI

/// Displays agent metadata for a task: token usage, attempt count, and error message.
/// Shared between `TaskAsideView` (aside panel) and `WorkTaskDetailView` (detail sheet).
struct WorkTaskAgentMetadata: View {
    let task: WorkTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let input = task.inputTokens, let output = task.outputTokens {
                    Label {
                        Text("\(WorkTask.formatTokenCount(input)) in / \(WorkTask.formatTokenCount(output)) out")
                    } icon: {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let attempt = task.attempt, attempt > 0 {
                    Label("Attempt \(attempt + 1)", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = task.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
