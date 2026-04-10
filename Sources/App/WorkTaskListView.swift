import GhosttyKit
import SwiftUI

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
    @State private var showDeleteConfirmation = false
    @State private var isCopied = false
    @State private var taskToForceDelete: WorkTask?

    private var selectedTask: WorkTask? {
        guard let id = selection else { return nil }
        return workTaskManager.tasks.first { $0.id == id }
    }

    private var backlogTasks: [WorkTask] {
        workTaskManager.tasks.filter { $0.status.isBacklog }
    }

    private var activeTaskCount: Int {
        workTaskManager.tasks.filter { $0.status.isActive }.count
    }

    private var activeTaskLabel: String {
        "\(activeTaskCount) task\(activeTaskCount == 1 ? "" : "s") in worktrees"
    }

    private var inProgressCount: Int {
        let liveBranches = Set(worktreeManager.worktrees.compactMap(\.branch))
        return workTaskManager.tasks.filter { task in
            task.status == .inProgress && task.worktree.map { liveBranches.contains($0) } == true
        }.count
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
            HStack(spacing: 8) {
                Button {
                    createAndEdit()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.thinMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .help("New task")

                if workTaskCoordinator.isAutoProcessingEnabled {
                    AutoProcessButton(
                        isAutoProcessing: workTaskCoordinator.isAutoProcessing,
                        tickGeneration: workTaskCoordinator.tickGeneration,
                        pollingSeconds: workTaskCoordinator.pollingInterval.rawValue,
                        inProgressCount: inProgressCount,
                        maxConcurrent: workTaskCoordinator.maxConcurrent
                    ) {
                        workTaskCoordinator.isAutoProcessing.toggle()
                    }
                }
            }
            .padding(12)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                let isReady = selectedTask?.status == .readyToStart
                Button {
                    guard let task = selectedTask else { return }
                    workTaskManager.setStatus(task, to: isReady ? .new : .readyToStart)
                } label: {
                    Label("Ready to Start", systemImage: isReady ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .disabled(selectedTask == nil || selectedTask?.status.isBacklog != true)

                Button("Start Now") {
                    if let task = selectedTask { startTask(task) }
                }
                .applyPrimaryActionStyle()
                .disabled(selectedTask == nil || selectedTask?.status.isBacklog != true)
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
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(isCopied ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                }
                .help("Copy task")
                .disabled(selectedTask == nil)
                .animation(.easeInOut(duration: 0.15), value: isCopied)
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
                    if workTaskCoordinator.planningConfig != nil {
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
                .help("Toggle edit/preview (⌘⇧P)")
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
                        if task.status == .new {
                            Button { workTaskManager.setStatus(task, to: .readyToStart) } label: {
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

        if let planningConfig = workTaskCoordinator.planningConfig {
            let taskPath = workTaskManager.filePath(for: task)
            let prompt = planningConfig.renderPrompt(task: task, taskPath: taskPath, attempt: task.attempt)
            let agentCmd = planningConfig.agentCommand ?? "claude"

            // Write prompt to temp file to handle long prompts safely
            let tempDir = NSTemporaryDirectory()
            let promptFile = (tempDir as NSString).appendingPathComponent("clearway-plan-\(task.id.uuidString).md")
            FileManager.default.createFile(atPath: promptFile, contents: prompt.data(using: .utf8), attributes: [.posixPermissions: 0o600])

            let command = "/bin/sh -c " + shellEscape("export PATH=\"$3\"; set -f; cat \"$2\" | $1") + " -- " + shellEscape(agentCmd) + " " + shellEscape(promptFile) + " " + shellEscape(ShellEnvironment.path)
            terminalManager.openTaskTerminalWithCommand(for: task.id, app: app, projectPath: projectPath, command: command)
        } else {
            // No PLANNING.md — open terminal with Main Terminal command
            let command = UserDefaults.standard.string(forKey: SettingsKey.mainTerminalCommand) ?? ""
            if !command.isEmpty {
                terminalManager.openTaskTerminalWithCommand(for: task.id, app: app, projectPath: projectPath, command: command)
            } else {
                terminalManager.toggleTaskTerminal(for: task.id, app: app, projectPath: projectPath)
            }
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
                    WorkTaskStatusBadge(status: task.status)
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
            if let onStartNow, task.status == .new || task.status == .readyToStart {
                Button { onStartNow() } label: {
                    Label("Start Now", systemImage: "play.fill")
                }
            }
            if let onReadyToStart, task.status == .new {
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
                WorkTaskStatusBadge(status: task.status)
            }
            Text(task.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
    }
}

// MARK: - Auto-Process Button

private struct AutoProcessButton: View {
    let isAutoProcessing: Bool
    let tickGeneration: Int
    let pollingSeconds: Int
    let inProgressCount: Int
    let maxConcurrent: Int
    let action: () -> Void

    @State private var progress: CGFloat = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.15), lineWidth: 2)
                        .frame(width: 18, height: 18)

                    if isAutoProcessing {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 18, height: 18)
                            .rotationEffect(.degrees(-90))
                    }

                    Image(systemName: isAutoProcessing ? "pause.fill" : "play.fill")
                        .font(.system(size: 7, weight: .bold))
                }

                Text("\(inProgressCount)/\(maxConcurrent)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(.thinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .onChange(of: tickGeneration) { _ in
            progress = 0
            withAnimation(.linear(duration: Double(pollingSeconds))) {
                progress = 1
            }
        }
        .onChange(of: isAutoProcessing) { running in
            if running {
                progress = 0
                withAnimation(.linear(duration: Double(pollingSeconds))) {
                    progress = 1
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    progress = 0
                }
            }
        }
    }
}

// MARK: - Status Badge

struct WorkTaskStatusBadge: View {
    let status: WorkTask.Status
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            if status == .readyToStart {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
            } else if status == .inProgress {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .scaleEffect(pulsing ? 1.3 : 1.0)
                    .opacity(pulsing ? 0.6 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
            }
            Text(status.label)
        }
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(badgeColor)
        .background(badgeColor.opacity(0.12), in: Capsule())
    }

    private var badgeColor: Color { status.badgeColor }
}

extension WorkTask.Status {
    var badgeColor: Color {
        switch self {
        case .new: return .blue
        case .readyToStart: return .indigo
        case .inProgress: return .green
        case .readyForReview: return .orange
        case .done: return .secondary
        case .canceled: return .red
        }
    }
}
