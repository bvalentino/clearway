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
                    showStatusBadge: false,
                    onEdit: { openTaskWindow(task) }
                )

                Divider()

                HStack {
                    Text("Status")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker(selection: Binding(
                        get: { task.status },
                        set: { workTaskManager.setStatus(task, to: $0) }
                    )) {
                        ForEach(allowedStatuses(for: task), id: \.self) { status in
                            Text(status.label).tag(status)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                // Agent metadata (show for tasks that have been worked on)
                if !task.status.isBacklog {
                    WorkTaskAgentMetadata(task: task)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Actions

    private func openTaskWindow(_ task: WorkTask) {
        openWindow(value: WorkTaskIdentifier(projectPath: projectPath, taskId: task.id))
    }

    private func allowedStatuses(for task: WorkTask) -> [WorkTask.Status] {
        [.inProgress, .readyForReview, .done, .canceled]
    }
}
