import SwiftUI

/// Displays the task linked to the current worktree in the aside panel.
/// Shows a clickable task card that opens the full task window.
struct TaskAsideView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator
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

                if workTaskCoordinator.isWorkflowJSONProject,
                   let definition = workTaskCoordinator.workflowDefinition {
                    Divider()
                    workflowActionCards(for: task, definition: definition)
                }

                // Agent metadata (show for tasks that have been worked on; never for placeholders)
                if !task.hidden, task.worktree != nil, WorkTaskAgentMetadata.hasContent(for: task) {
                    WorkTaskAgentMetadata(task: task)
                }
            }
            .padding(16)
        }
    }

    /// The worktree's journey through `WORKFLOW.json`: one card per action in flow order, each showing
    /// its derived progress (completed / current / next / upcoming) and a "more" menu that steers or
    /// runs that step. All three menu items pause autopilot — manual per-card control and the loop are
    /// mutually exclusive. Replaces the old single Status picker + play button; shown only for a valid
    /// JSON-workflow project, so non-JSON projects show no status UI at all.
    private func workflowActionCards(for task: WorkTask, definition: WorkflowDefinition) -> some View {
        VStack(spacing: 8) {
            ForEach(definition.actionProgress(currentStatus: task.status, completed: task.completed == true), id: \.slug) { progress in
                if let action = definition.actions[progress.slug] {
                    WorkflowSidebarActionCard(
                        name: action.name,
                        instructions: action.instructions,
                        state: progress.state,
                        onSetCurrent: {
                            workTaskCoordinator.setWorkflowActionCurrent(task, to: progress.slug)
                        },
                        onRunInCurrentTerminal: {
                            workTaskCoordinator.runWorkflowAction(
                                forBranch: worktreeBranch, slug: progress.slug, inNewTerminal: false
                            )
                        },
                        onRunInNewTerminal: {
                            workTaskCoordinator.runWorkflowAction(
                                forBranch: worktreeBranch, slug: progress.slug, inNewTerminal: true
                            )
                        }
                    )
                }
            }
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
}
