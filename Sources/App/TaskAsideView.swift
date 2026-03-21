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

                // Agent metadata (show for tasks that have been worked on)
                if !task.status.isBacklog {
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
        HStack(spacing: 8) {
            switch task.status {
            case .inProgress:
                Button {
                    workTaskManager.setStatus(task, to: .readyForReview)
                } label: {
                    Label("Ready for Review", systemImage: "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .readyForReview:
                Button {
                    workTaskManager.setStatus(task, to: .inProgress)
                } label: {
                    Label("Back to In Progress", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .done where task.worktree != nil:
                Button {
                    onContinue?(task)
                } label: {
                    Label("Continue", systemImage: "play")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .canceled:
                Button {
                    onRestart?(task)
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)

            default:
                EmptyView()
            }

            Spacer()

            if task.status.isActive {
                Button {
                    workTaskManager.setStatus(task, to: .canceled)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)

                Button {
                    workTaskManager.setStatus(task, to: .done)
                } label: {
                    Label("Mark Done", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
