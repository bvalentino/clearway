import SwiftUI

/// Displays Claude Code tasks for the current worktree, grouped by session.
struct ClaudeTasksView: View {
    @EnvironmentObject private var claudeTaskManager: ClaudeTaskManager

    var body: some View {
        if claudeTaskManager.sessions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("No Claude tasks")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(claudeTaskManager.sessions) { session in
                        SessionSection(session: session)
                    }
                }
                .padding()
            }
        }
    }
}

private struct SessionSection: View {
    let session: ClaudeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())

            ForEach(session.tasks) { task in
                TaskRow(task: task)
            }
        }
    }
}

private struct TaskRow: View {
    let task: ClaudeTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: task.statusSymbol)
                .font(.system(size: 16))
                .foregroundStyle(statusColor)
                .frame(width: 20)

            Text(task.subject)
                .font(.body)
                .foregroundStyle(task.status == .completed ? .secondary : .primary)
                .strikethrough(task.status == .completed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .completed: return .green
        case .inProgress: return .orange
        case .pending: return .secondary
        }
    }
}
