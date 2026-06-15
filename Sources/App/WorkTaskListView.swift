import GhosttyKit
import SwiftUI
import os

private let planLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.getclearway.mac",
    category: "plan"
)

/// The project home — a backlog showing tasks that need shaping or haven't started.
/// Started/stopped/done tasks live in their worktree's aside panel.
struct WorkTaskListView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    let projectPath: String
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
        .overlay(alignment: .bottomTrailing) {
            Button {
                createAndEdit()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .help("New task")
            .padding(12)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                let isReady = selectedTask?.status == WorkTask.ReservedStatus.readyToStart
                Button {
                    guard let task = selectedTask else { return }
                    workTaskManager.setStatus(task, to: isReady ? WorkTask.ReservedStatus.new : WorkTask.ReservedStatus.readyToStart)
                } label: {
                    Label("Ready to Start", systemImage: isReady ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .disabled(selectedTask == nil || selectedTask?.worktree != nil)

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
                Button(action: planTask) {
                    if workTaskCoordinator.planningInstructions != nil {
                        Text("Plan")
                    } else {
                        Image(systemName: "rectangle.bottomhalf.inset.filled")
                            .opacity(taskTerminalOpen ? 1 : 0.5)
                    }
                }
                .help(taskTerminalOpen ? "Hide planning terminal" : "Plan task")
                .disabled(selectedTask == nil || ghosttyApp.readiness != .ready)
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
                        Button { startTask(task) } label: {
                            Label("Start Now", systemImage: "play.fill")
                        }
                        if task.status == WorkTask.ReservedStatus.new {
                            Button { workTaskManager.setStatus(task, to: WorkTask.ReservedStatus.readyToStart) } label: {
                                Label("Ready to Start", systemImage: "clock.arrow.circlepath")
                            }
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
        terminalManager.toggleTaskTerminal(for: id, app: app, projectPath: projectPath)
    }

    private func planTask() {
        guard let task = selectedTask, let app = ghosttyApp.app else { return }

        // If already visible, toggle off
        if taskTerminalOpen {
            toggleTaskTerminal()
            return
        }

        if let instructions = workTaskCoordinator.planningInstructions {
            let taskPath = workTaskManager.filePath(for: task)
            let prompt = PlanningConfig.renderPlanningPrompt(instructions: instructions, task: task, taskPath: taskPath)
            let agentCmd = workTaskCoordinator.planningAgentCommand

            // Write prompt to temp file to handle long prompts safely
            let tempDir = NSTemporaryDirectory()
            let promptFile = (tempDir as NSString).appendingPathComponent("clearway-plan-\(task.id.uuidString).md")
            FileManager.default.createFile(atPath: promptFile, contents: prompt.data(using: .utf8), attributes: [.posixPermissions: 0o600])

            let resolvedPath = ShellEnvironment.path
            let command = "/bin/sh -c " + shellEscape("export PATH=\"$3\"; set -f; cat \"$2\" | $1") + " -- " + shellEscape(agentCmd) + " " + shellEscape(promptFile) + " " + shellEscape(resolvedPath)
            planLogger.info("plan agent=\(agentCmd, privacy: .public) promptFile=\(promptFile, privacy: .public)")
            planLogger.info("plan path=\(resolvedPath, privacy: .public)")
            planLogger.debug("plan command: \(command, privacy: .public)")
            terminalManager.openTaskTerminalWithCommand(for: task.id, app: app, projectPath: projectPath, command: command)
        } else {
            // No planning instruction — open terminal with the Main Terminal command
            let command = UserDefaults.standard.string(forKey: SettingsKey.mainTerminalCommand) ?? ""
            if !command.isEmpty {
                terminalManager.openTaskTerminalWithCommand(for: task.id, app: app, projectPath: projectPath, command: command)
            } else {
                terminalManager.toggleTaskTerminal(for: task.id, app: app, projectPath: projectPath)
            }
        }

        // Opening the planning terminal — tell the editor to switch to preview so
        // the rendered task sits beside it. The editor owns the live (possibly
        // unsaved) body buffer, so it decides whether there's anything to preview.
        NotificationCenter.default.post(name: WorkTaskNotification.planningTerminalOpened, object: task.id)
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
            object: projectPath,
            userInfo: [WorkTaskNotification.taskKey: task]
        )
    }
}

// MARK: - Task Card

struct WorkTaskCard: View {
    let task: WorkTask
    var showStatusBadge: Bool = true
    var showContextMenu: Bool = true
    var onEdit: () -> Void
    var onStartNow: (() -> Void)?
    var onReadyToStart: (() -> Void)?
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator

    /// Whether the task sits on a **defined, routeless** WORKFLOW.json action — the derived "done"
    /// end-state of the loop. Drives the badge's terminal coloring so a finished loop doesn't read
    /// as "active green". Reads the coordinator's cached definition (no per-render disk load);
    /// `false` for legacy projects (`nil` definition) and for unknown slugs (a halted/off-graph
    /// value isn't "done", so it keeps the running fallback).
    private var isTerminalAction: Bool {
        workTaskCoordinator.workflowDefinition.map {
            $0.actions[task.status] != nil && $0.isTerminal(task.status)
        } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.title.isEmpty ? "Untitled" : task.title)
                    .font(.headline)
                    .foregroundStyle(task.title.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if showStatusBadge {
                    Spacer()
                    WorkTaskStatusBadge(status: task.status, isTerminalAction: isTerminalAction)
                }
            }

            Text(task.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .contextMenu(showContextMenu ? ContextMenu {
            if let onStartNow, task.status == WorkTask.ReservedStatus.new || task.status == WorkTask.ReservedStatus.readyToStart {
                Button { onStartNow() } label: {
                    Label("Start Now", systemImage: "play.fill")
                }
            }
            if let onReadyToStart, task.status == WorkTask.ReservedStatus.new {
                Button { onReadyToStart() } label: {
                    Label("Ready to Start", systemImage: "clock.arrow.circlepath")
                }
            }
            Divider()
            Button(role: .destructive) {
                workTaskManager.deleteTask(task)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } : nil)
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
                if task.status == WorkTask.ReservedStatus.readyToStart {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .help("Ready to Start")
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

// MARK: - Status Badge

struct WorkTaskStatusBadge: View {
    let status: String
    /// Whether `status` is a defined, routeless WORKFLOW.json action (the loop's derived "done").
    /// Supplied by the caller (the badge stays environment-free) so a terminal action gets the
    /// done-style secondary color instead of the running-green fallback. `false` for legacy
    /// projects and reserved/legacy slugs, whose colors come from the explicit switch arms.
    var isTerminalAction: Bool = false
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            if status == WorkTask.ReservedStatus.readyToStart {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
            } else if status == WorkTask.ReservedStatus.inProgress {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .scaleEffect(pulsing ? 1.3 : 1.0)
                    .opacity(pulsing ? 0.6 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
            }
            Text(WorkTask.displayLabel(for: status))
        }
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(Self.badgeColor(for: status, isTerminalAction: isTerminalAction))
        .background(Self.badgeColor(for: status, isTerminalAction: isTerminalAction).opacity(0.12), in: Capsule())
    }

    /// Accent color for a status slug. Known reserved/legacy slugs keep their existing colors. An
    /// arbitrary action slug is colored by loop position: a **terminal** (routeless) action is the
    /// loop's derived "done", so it matches the legacy `done` secondary; anything else falls back
    /// to the running-state accent (mid-loop actions are by definition in flight).
    static func badgeColor(for status: String, isTerminalAction: Bool = false) -> Color {
        switch status {
        case WorkTask.ReservedStatus.new: return .blue
        case WorkTask.ReservedStatus.readyToStart: return .indigo
        case WorkTask.ReservedStatus.inProgress: return .green
        case WorkTask.ReservedStatus.qa: return .purple
        case WorkTask.ReservedStatus.readyForReview: return .orange
        case WorkTask.ReservedStatus.done: return .secondary
        case WorkTask.ReservedStatus.canceled: return .red
        default: return isTerminalAction ? .secondary : .green
        }
    }
}
