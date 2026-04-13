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
                    showContextMenu: false,
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
                    if workTaskCoordinator.workflowConfig?.hasStateCommand(for: task.status) == true {
                        SendToTerminalButton(
                            action: { sendStateCommandToTerminal(task) },
                            disabled: terminalManager.activeMainSurface == nil
                        )
                    }
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
        ),
        let surface = terminalManager.activeMainSurface else { return }
        surface.sendPaste(rendered)
        surface.window?.makeFirstResponder(surface)
    }

    private func allowedStatuses(for task: WorkTask) -> [WorkTask.Status] {
        [.inProgress, .qa, .readyForReview, .done, .canceled]
    }
}
