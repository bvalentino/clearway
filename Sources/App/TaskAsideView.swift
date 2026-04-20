import SwiftUI

/// Displays the task linked to the current worktree in the aside panel.
/// Shows a clickable task card that opens the full task window.
struct TaskAsideView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator
    @EnvironmentObject private var terminalManager: TerminalManager
    @Environment(\.openWindow) private var openWindow

    let worktreeBranch: String
    let projectPath: String
    var onRequestTrust: ((@escaping () -> Void) -> Void)?

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
        // have somewhere to land. The coordinator no-ops when a task already links the branch.
        .onAppear { workTaskCoordinator.ensureShadowTask(forBranch: worktreeBranch) }
    }

    // MARK: - Task Content

    private func taskContent(_ task: WorkTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if task.hidden {
                    createTaskPlaceholder(for: task)
                } else {
                    WorkTaskCard(
                        task: task,
                        showStatusBadge: false,
                        showContextMenu: false,
                        onEdit: { openTaskWindow(task) }
                    )
                }

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
                    let hasStateCommand = workTaskCoordinator.workflowConfig?.hasStateCommand(for: task.status) == true
                    let hasWorktree = workTaskCoordinator.worktreeForTask(task) != nil
                    if hasStateCommand && hasWorktree {
                        SendToTerminalButton(
                            action: { sendStateCommandToTerminal(task) },
                            disabled: terminalManager.activeSurfaceId == nil
                        )
                    }
                }

                // Agent metadata (show for tasks that have been worked on; never for placeholders)
                if !task.hidden, !task.status.isBacklog, WorkTaskAgentMetadata.hasContent(for: task) {
                    WorkTaskAgentMetadata(task: task)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Create Task CTA

    /// Replaces the task card when the linked task is still a hidden placeholder. The status
    /// picker below stays live — users can track state without surfacing the task in Planning.
    private func createTaskPlaceholder(for task: WorkTask) -> some View {
        VStack(spacing: 10) {
            Text("No task for this worktree")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                let exposed = workTaskManager.expose(task)
                openTaskWindow(exposed)
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

    private func sendStateCommandToTerminal(_ task: WorkTask) {
        guard let config = workTaskCoordinator.workflowConfig,
              config.hasStateCommand(for: task.status) else { return }
        if !config.isTrusted(forProject: projectPath) {
            // Bind the retry to the pane that was active when the user clicked.
            // If they switch worktrees before approving trust, drop the action
            // rather than paste into the wrong terminal.
            let expectedPaneId = terminalManager.activeSurfaceId
            onRequestTrust?({
                guard terminalManager.activeSurfaceId == expectedPaneId else { return }
                sendStateCommandToTerminal(task)
            })
            return
        }
        guard let rendered = config.renderStateCommand(
            for: task.status,
            task: task,
            taskPath: workTaskManager.filePath(for: task)
        ) else { return }
        terminalManager.sendToActiveMainTab(rendered, asCommand: false)
    }

    /// `.new` and `.readyToStart` are reserved for Planning (pre-worktree). Once a worktree
    /// exists, its task starts at `.inProgress` and can only move forward through these states.
    private func allowedStatuses(for task: WorkTask) -> [WorkTask.Status] {
        [.inProgress, .qa, .readyForReview, .done, .canceled]
    }
}
