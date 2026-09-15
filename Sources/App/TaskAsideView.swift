import SwiftUI

/// Displays the task linked to the current worktree in the aside panel.
/// Shows a clickable task card that opens the full task window.
struct TaskAsideView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @Environment(\.openWindow) private var openWindow

    let worktreeBranch: String
    let projectPath: String

    private var task: WorkTask? {
        workTaskManager.task(forWorktree: worktreeBranch)
    }

    var body: some View {
        Group {
            if let task {
                taskContent(task)
            } else {
                unlinkedCreateTaskCTA
            }
        }
        // Ensure every worktree has a persistent (possibly hidden) task so status changes
        // have somewhere to land. `createShadowTask` is idempotent.
        .onAppear { workTaskManager.createShadowTask(forBranch: worktreeBranch) }
    }

    // MARK: - Task Content

    private func taskContent(_ task: WorkTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if task.hidden {
                    createTaskPlaceholder(for: task)
                } else {
                    WorkTaskCard(task: task, onEdit: { openTaskWindow(task) })
                }

                if !task.hidden, task.worktree != nil, WorkTaskAgentMetadata.hasContent(for: task) {
                    WorkTaskAgentMetadata(task: task)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Create Task CTA

    /// Replaces the task card when the linked task is still a hidden placeholder.
    private func createTaskPlaceholder(for task: WorkTask) -> some View {
        VStack(spacing: 10) {
            Text("No task for this worktree")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                openTaskWindow(workTaskManager.expose(task))
            } label: {
                Label("Create Task", systemImage: "plus")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// Fallback when no task MD exists at all (e.g. pre-change worktree whose shadow
    /// hasn't been created yet). `onAppear` will usually create one before this is seen.
    private var unlinkedCreateTaskCTA: some View {
        VStack(spacing: 10) {
            Text("No task for this worktree")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                if let created = workTaskManager.createExposedTask(forBranch: worktreeBranch) {
                    openTaskWindow(created)
                }
            } label: {
                Label("Create Task", systemImage: "plus")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func openTaskWindow(_ task: WorkTask) {
        openWindow(value: WorkTaskIdentifier(projectPath: projectPath, taskId: task.id))
    }
}
