import SwiftUI

/// The project home — a backlog showing tasks that need shaping or haven't started.
/// Once a task has a worktree it lives in that worktree's aside panel.
struct WorkTaskListView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var savedCommandManager: SavedCommandManager
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @Binding var selection: UUID?
    @Binding var editorMode: TaskEditorMode
    /// One-shot creation-focus signal owned by `ContentView`; set when this list creates
    /// a task so the detail view focuses its title (creation is exempt from no-auto-focus).
    @Binding var newlyCreatedTaskId: UUID?
    @State private var showDeleteConfirmation = false
    @State private var isCopied = false
    @State private var taskToForceDelete: WorkTask?

    private var selectedTask: WorkTask? {
        guard let id = selection else { return nil }
        return workTaskManager.tasks.first { $0.id == id }
    }

    /// Backlog = tasks not yet associated with a worktree. Location encodes association, so a
    /// `worktree == nil` task is one that still lives centrally (shadow tasks always carry a
    /// worktree, so they're excluded without a separate `hidden` check).
    private var backlogTasks: [WorkTask] {
        workTaskManager.tasks.filter { $0.worktree == nil }
    }

    private var activeTaskCount: Int {
        workTaskManager.tasks.filter { $0.worktree != nil }.count
    }

    private var activeTaskLabel: String {
        "\(activeTaskCount) task\(activeTaskCount == 1 ? "" : "s") in worktrees"
    }

    var body: some View {
        Group {
            if backlogTasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createAndEdit()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New task")
            }

            ToolbarGroupBreak()

            ToolbarItem(placement: .primaryAction) {
                planMenu(for: selectedTask)
            }

            ToolbarItem(placement: .primaryAction) {
                Button("Start Now") {
                    if let task = selectedTask { startTask(task) }
                }
                .applyPrimaryActionStyle()
                .disabled(selectedTask == nil || selectedTask?.worktree != nil)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let task = selectedTask {
                        let text = "# \(task.title)\n\n\(task.body)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        isCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isCopied = false
                        }
                    }
                } label: {
                    Group {
                        if isCopied {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                    .frame(width: 16)
                }
                .help("Copy task")
                .disabled(selectedTask == nil)
                .animation(.easeInOut(duration: 0.15), value: isCopied)
                .onChange(of: selection) { _ in isCopied = false }
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleTaskTerminal) {
                    Image(systemName: "rectangle.bottomhalf.inset.filled")
                        .opacity(taskTerminalOpen ? 1 : 0.5)
                }
                .help(taskTerminalOpen ? "Hide terminal" : "Show terminal")
                .disabled(selectedTask == nil || ghosttyApp.readiness != .ready)
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(role: .destructive) {
                        if let task = selectedTask {
                            confirmDeleteTask(task)
                        }
                    } label: {
                        Label("Delete Task", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("More actions")
                .disabled(selectedTask == nil)
            }

            ToolbarItem(placement: .primaryAction) {
                Picker("Mode", selection: $editorMode) {
                    Image(systemName: "pencil").tag(TaskEditorMode.edit)
                    Image(systemName: "eye").tag(TaskEditorMode.preview)
                }
                .pickerStyle(.segmented)
                .help("Toggle edit/preview")
                .disabled(selectedTask == nil)
            }
        }
        .alert(
            "Delete \"\(selectedTask?.title ?? "Untitled")\"?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                if let task = selectedTask {
                    terminalManager.closeTaskTerminal(task.id)
                    workTaskManager.deleteTask(task)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .confirmationDialog(
            "Delete \"\(taskToForceDelete?.title ?? "Untitled")\"?",
            isPresented: Binding(
                get: { taskToForceDelete != nil },
                set: { if !$0 { taskToForceDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let task = taskToForceDelete {
                    terminalManager.closeTaskTerminal(task.id)
                    workTaskManager.deleteTask(task)
                }
                taskToForceDelete = nil
            }
        } message: {
            Text("There are processes still running in this task's terminal.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(activeTaskCount > 0 ? "Backlog is empty" : "No tasks yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            if activeTaskCount > 0 {
                Text(activeTaskLabel)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var taskList: some View {
        List(selection: $selection) {
            ForEach(backlogTasks) { task in
                WorkTaskRow(task: task, hasActiveTerminal: terminalManager.taskHasActiveProcess(task.id))
                    .tag(task.id)
                    .contextMenu {
                        planMenu(for: task)
                        Button { startTask(task) } label: {
                            Label("Start Now", systemImage: "play.fill")
                        }
                        Divider()
                        Button(role: .destructive) {
                            selection = task.id
                            confirmDeleteTask(task)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }

        }
        .listStyle(.inset)
    }

    // MARK: - Plan

    private var agentCommands: [SavedCommand] {
        SavedCommand.filter(savedCommandManager.commands, by: .agent)
    }

    /// The Plan dropdown, rendered by both the toolbar and the row context menu. The task is a
    /// parameter so the context menu plans the right-clicked row rather than the selection; a nil
    /// task is the toolbar with nothing selected.
    ///
    /// `primaryAction:` is declared only while the project has a plan default, so the first click
    /// opens the list when there is nothing to repeat.
    @ViewBuilder
    private func planMenu(for task: WorkTask?) -> some View {
        if let preferred = savedCommandManager.planCommand {
            Menu {
                planItems(for: task)
            } label: {
                Text("Plan")
            } primaryAction: {
                plan(task, using: preferred)
            }
            .disabled(planIsUnavailable(for: task))
        } else {
            Menu {
                planItems(for: task)
            } label: {
                Text("Plan")
            }
            .disabled(planIsUnavailable(for: task))
        }
    }

    @ViewBuilder
    private func planItems(for task: WorkTask?) -> some View {
        ForEach(agentCommands) { command in
            Button(command.name) { plan(task, using: command) }
        }
    }

    private func planIsUnavailable(for task: WorkTask?) -> Bool {
        task == nil || agentCommands.isEmpty || ghosttyApp.app == nil
    }

    private func plan(_ task: WorkTask?, using command: SavedCommand) {
        guard let task, let app = ghosttyApp.app else { return }
        workTaskCoordinator.planTask(task, using: command, app: app)
        savedCommandManager.setPlanDefault(command.id)
    }

    private func createAndEdit() {
        if let task = workTaskManager.createTask() {
            selection = task.id
            newlyCreatedTaskId = task.id   // one-shot focus signal (creation only)
        }
    }

    private var taskTerminalOpen: Bool {
        guard let id = selection else { return false }
        return terminalManager.isTaskTerminalVisible(for: id)
    }

    private func toggleTaskTerminal() {
        guard let id = selection, let app = ghosttyApp.app else { return }
        workTaskCoordinator.toggleTaskTerminal(taskId: id, app: app)
    }

    private func confirmDeleteTask(_ task: WorkTask) {
        if terminalManager.taskHasActiveProcess(task.id) {
            taskToForceDelete = task
        } else {
            showDeleteConfirmation = true
        }
    }

    private func startTask(_ task: WorkTask) {
        NotificationCenter.default.post(
            name: WorkTaskNotification.start,
            object: worktreeManager.projectPath,
            userInfo: [WorkTaskNotification.taskKey: task]
        )
    }
}

// MARK: - Task Card

struct WorkTaskCard: View {
    let task: WorkTask
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title.isEmpty ? "Untitled" : task.title)
                .font(.headline)
                .foregroundStyle(task.title.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(task.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }
}

// MARK: - Task Row (for List selection)

private struct WorkTaskRow: View {
    let task: WorkTask
    var hasActiveTerminal: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title.isEmpty ? "Untitled" : task.title)
                    .font(.body)
                    .foregroundStyle(task.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                if hasActiveTerminal {
                    Image(systemName: "terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(task.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
    }
}
