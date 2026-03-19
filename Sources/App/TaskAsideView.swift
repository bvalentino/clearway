import SwiftUI

/// Displays the task linked to the current worktree in the aside panel.
/// Shows a clickable task card that opens the full task window.
struct TaskAsideView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @Environment(\.openWindow) private var openWindow

    let worktreeBranch: String
    let projectPath: String
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
                WorkTaskCard(
                    task: task,
                    onEdit: { openTaskWindow(task) }
                )

                // Agent metadata
                if task.status != .open {
                    WorkTaskAgentMetadata(task: task)
                }

                // Action buttons
                actionButtons(task)

                // Last updated
                Text("Updated \(task.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    // MARK: - Actions

    private func openTaskWindow(_ task: WorkTask) {
        openWindow(value: WorkTaskIdentifier(projectPath: projectPath, taskId: task.id))
    }

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
