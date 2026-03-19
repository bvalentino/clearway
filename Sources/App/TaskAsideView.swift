import SwiftUI

/// Displays the task linked to the current worktree in the aside panel.
/// Read-only view of task details with agent metadata and action buttons.
struct TaskAsideView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager

    let worktreeBranch: String
    var onContinue: ((WorkTask) -> Void)?
    var onRestart: ((WorkTask) -> Void)?
    var onMarkDone: ((WorkTask) -> Void)?

    private var task: WorkTask? {
        workTaskManager.task(forWorktree: worktreeBranch)
    }

    var body: some View {
        if let task {
            taskContent(task)
        } else {
            emptyState
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No task linked")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Task Content

    private func taskContent(_ task: WorkTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title and status
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.title)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    WorkTaskStatusBadge(status: task.status)
                }

                // Agent metadata
                if task.status != .open {
                    WorkTaskAgentMetadata(task: task)
                }

                // Action buttons
                actionButtons(task)

                if !task.body.isEmpty {
                    Divider()

                    // Body (read-only)
                    Text(task.body)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                // Last updated
                Text("Updated \(task.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtons(_ task: WorkTask) -> some View {
        if task.status != .open {
            HStack(spacing: 8) {
                if task.status == .stopped {
                    Button {
                        onRestart?(task)
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                }

                if task.status == .done, task.worktree != nil {
                    Button {
                        onContinue?(task)
                    } label: {
                        Label("Continue", systemImage: "play")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                if task.status != .done {
                    Button {
                        onMarkDone?(task)
                    } label: {
                        Label("Mark Done", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}
