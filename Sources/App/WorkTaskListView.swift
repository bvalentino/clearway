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
    @EnvironmentObject private var agentActivity: AgentActivityMonitor
    @Binding var selection: UUID?
    @Binding var editorMode: TaskEditorMode
    /// One-shot creation-focus signal owned by `ContentView`; set when this list creates
    /// a task so the detail view focuses its title (creation is exempt from no-auto-focus).
    @Binding var newlyCreatedTaskId: UUID?
    @State private var showDeleteConfirmation = false
    @State private var isCopied = false
    @State private var taskToForceDelete: WorkTask?
    @State private var showCommandEditor = false
    @State private var planToConfirm: PlanRequest?

    /// A plan waiting on the operator's confirmation because it would replace a running process.
    private struct PlanRequest {
        let task: WorkTask
        let command: SavedCommand
    }

    private var selectedTask: WorkTask? {
        guard let id = selection else { return nil }
        return workTaskManager.tasks.first { $0.id == id }
    }

    /// The selection when Start Now's primary action applies to it. A task that already has a
    /// worktree is not startable, and the toolbar's split button stays enabled regardless so its
    /// chevron keeps opening the menu, so the guard has to be a value the action reads.
    private var startableTask: WorkTask? {
        guard let task = selectedTask, task.worktree == nil else { return nil }
        return task
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
                Menu {
                    startNowItems(for: nil)
                } label: {
                    Text("Start Now")
                } primaryAction: {
                    if let task = startableTask { startTask(task) }
                }
                .applyPrimaryActionStyle()
            }

            ToolbarGroupBreak()

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
        .sheet(isPresented: $showCommandEditor) {
            CommandEditorSheet(command: nil, newCommandKind: .agent)
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
        .confirmationDialog(
            "Replace the terminal for \"\(planToConfirm?.task.title ?? "Untitled")\"?",
            isPresented: Binding(
                get: { planToConfirm != nil },
                set: { if !$0 { planToConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                if let request = planToConfirm {
                    runPlan(request.task, using: request.command)
                }
                planToConfirm = nil
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
                WorkTaskRow(
                    task: task,
                    hasActiveTerminal: terminalManager.taskHasActiveProcess(task.id),
                    phase: agentActivity.taskPhases[task.id] ?? .idle
                )
                    .tag(task.id)
                    .contextMenu {
                        Menu {
                            Button("Start Task…") { startTask(task) }
                            startNowItems(for: task)
                        } label: {
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

    // MARK: - Start Now

    /// The dropdown half of Start Now: one item per agent command, each planning the task in its
    /// own bottom terminal, then the editor door.
    ///
    /// The command items are **omitted** when there is nothing to plan, never rendered disabled:
    /// a macOS toolbar menu updates an existing `NSMenuItem`'s enabled flag unreliably, so a menu
    /// first built with nothing selected kept its commands greyed out after a task was selected.
    /// Omitting them changes the content's structural identity, which rebuilds the menu.
    /// The terminal half of the gate is `readiness` and not `ghosttyApp.app`: `readiness` is
    /// `@Published`, while `app` is a plain computed property with no change to publish, so a menu
    /// built before it was non-nil had nothing to re-evaluate against.
    ///
    /// That same retention is why an item may not **capture** a `WorkTask` either: the closures
    /// built with the menu outlive the selection they were built under, so an item carrying a task
    /// value planned whatever was selected when the menu was first built — replacing that task's
    /// terminal, killing the agent in it, and snapping the selection back to it. This takes the
    /// *row* it is built for instead — `nil` from the toolbar, the row's own task from a context
    /// menu — and every item resolves its target through
    /// `WorkTaskCoordinator.startNowTarget(row:selection:)` **inside** its action, against the
    /// live `selectedTask`. No test can catch a regression here; this docstring is the guard.
    ///
    /// The editor door is unconditional because a project with no agent commands yet would
    /// otherwise open an empty menu, which AppKit renders as nothing happening at all.
    @ViewBuilder
    private func startNowItems(for row: WorkTask?) -> some View {
        let commands = savedCommandManager.agentCommands
        if WorkTaskCoordinator.startNowTarget(row: row, selection: selectedTask) != nil,
           ghosttyApp.readiness == .ready, !commands.isEmpty {
            ForEach(commands) { command in
                Button(command.name) {
                    if let task = WorkTaskCoordinator.startNowTarget(row: row, selection: selectedTask) {
                        plan(task, using: command)
                    }
                }
            }
            Divider()
        }
        Button("Add Agent Command…") { showCommandEditor = true }
    }

    private func plan(_ task: WorkTask, using command: SavedCommand) {
        if WorkTaskCoordinator.planNeedsConfirmation(
            hasActiveProcess: terminalManager.taskHasActiveProcess(task.id)
        ) {
            planToConfirm = PlanRequest(task: task, command: command)
        } else {
            runPlan(task, using: command)
        }
    }

    /// Selecting the task is part of running it: the terminal the plan opens is the one
    /// `TaskDetailView` renders for the selection, so planning a row the user only right-clicked
    /// would otherwise run out of sight.
    private func runPlan(_ task: WorkTask, using command: SavedCommand) {
        guard let app = ghosttyApp.app else { return }
        selection = task.id
        workTaskCoordinator.planTask(task, using: command, app: app)
    }

    private func createAndEdit() {
        if let task = workTaskManager.createTask() {
            selection = task.id
            newlyCreatedTaskId = task.id   // one-shot focus signal (creation only)
        }
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

struct WorkTaskRow: View {
    let task: WorkTask
    var hasActiveTerminal: Bool = false
    var phase: AgentPhase = .idle

    /// Which dot the row carries, or none. No `hasNotification` and no `isOpen`: a task terminal
    /// raises no notification, and a retired surface has already left the store.
    static func dot(phase: AgentPhase) -> AgentActivityDot.Kind? {
        switch phase {
        case .waiting: return .waiting
        case .working: return .working
        case .idle: return nil
        }
    }

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
                Group {
                    if let kind = Self.dot(phase: phase) {
                        AgentActivityDot(kind: kind)
                    }
                }
                .animation(.easeOut(duration: 0.6), value: phase)
            }
            Text(task.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
    }
}
