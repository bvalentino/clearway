import SwiftUI

/// Identifies a task for opening in its own window.
struct WorkTaskIdentifier: Codable, Hashable {
    let projectPath: String
    let taskId: UUID
}

/// Notification names and keys for task actions dispatched from the task window.
/// The notification object is the task UUID, and userInfo contains `WorkTaskNotification.taskKey`
/// with the latest WorkTask data to avoid race conditions with the receiver's manager.
enum WorkTaskNotification {
    static let start = Notification.Name("startWorkTask")
    static let openWorktree = Notification.Name("openWorkTaskWorktree")

    /// Posted when the planning terminal is opened for a task so the inline editor
    /// can switch to preview beside it. The object is the task UUID.
    static let planningTerminalOpened = Notification.Name("planningTerminalOpened")

    /// Key used in notification userInfo to pass the WorkTask value.
    static let taskKey = "task"
}

/// A standalone task editor window with traffic lights and toolbar.
struct WorkTaskWindow: View {
    @StateObject private var workTaskManager: WorkTaskManager
    @StateObject private var worktreeManager: WorktreeManager
    let taskId: UUID

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var editorText: String = ""
    @State private var frontmatterError: Bool = false
    @State private var pendingSave: DispatchWorkItem?
    @State private var reloadingCount = 0
    @State private var showDeleteConfirmation = false
    @State private var deleted = false
    @State private var editorMode: EditorMode = .edit
    @State private var showCopiedFeedback = false
    @AppStorage("showFrontmatter") private var showFrontmatter: Bool = false
    @FocusState private var isTitleFocused: Bool

    private enum EditorMode {
        case edit, preview
    }

    init(identifier: WorkTaskIdentifier) {
        let wm = WorktreeManager(projectPath: identifier.projectPath)
        let taskMgr = WorkTaskManager(projectPath: identifier.projectPath)
        // This standalone window builds its own managers. Without a resolver the task manager only
        // scans central and can't find a task that now lives in a worktree's `TASK.md` — the cause
        // of "Task not found" for started tasks. Wire it exactly like ProjectWindow.
        taskMgr.worktreeResolver = { [weak wm] in wm?.taskResolverPairs() ?? [] }
        _worktreeManager = StateObject(wrappedValue: wm)
        _workTaskManager = StateObject(wrappedValue: taskMgr)
        taskId = identifier.taskId
    }

    private var task: WorkTask? {
        workTaskManager.tasks.first { $0.id == taskId }
    }

    var body: some View {
        Group {
            if let task {
                taskEditor(task)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Task not found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 500, minHeight: 350)
        .background(.ultraThinMaterial)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                primaryActionButton
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        let body = showFrontmatter ? YAML.bodyText(in: editorText) : bodyText
                        let text = "# \(title)\n\n\(body)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label("Copy Task", systemImage: "doc.on.doc")
                    }

                    if let task, task.worktree == nil {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Task", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("More actions")
            }

            ToolbarItem(placement: .primaryAction) {
                Picker("Mode", selection: $editorMode) {
                    Image(systemName: "pencil").tag(EditorMode.edit)
                    Image(systemName: "eye").tag(EditorMode.preview)
                }
                .pickerStyle(.segmented)
                .help("Toggle edit/preview")
            }
        }
        .alert(
            "Delete \"\(title)\"?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                deleted = true
                if let task { workTaskManager.deleteTask(task) }
                DispatchQueue.main.async {
                    NSApplication.shared.keyWindow?.close()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .onChange(of: worktreeManager.worktrees) { worktrees in
            // Worktrees load asynchronously; re-merge so a task living in a worktree's `TASK.md`
            // is found (the `.onChange(of: task)` below then populates the editor), and watch
            // those worktrees so external edits to `TASK.md` flow into the open window.
            workTaskManager.setWatchedWorktrees(worktrees.compactMap(\.path))
        }
        .onAppear {
            if let task {
                title = task.title
                bodyText = task.body
                editorText = task.serialized()
                editorMode = task.body.isEmpty ? .edit : .preview
                if task.title.isEmpty {
                    DispatchQueue.main.async { isTitleFocused = true }
                }
            }
        }
        .onChange(of: title) { _ in
            guard TaskEditorBuffers.shouldAutosave(reloadingCount: &reloadingCount) else { return }
            scheduleSave()
        }
        .onChange(of: bodyText) { _ in
            guard TaskEditorBuffers.shouldAutosave(reloadingCount: &reloadingCount) else { return }
            scheduleSave()
        }
        .onChange(of: editorText) { _ in
            guard showFrontmatter else { return }
            guard TaskEditorBuffers.shouldAutosave(reloadingCount: &reloadingCount) else { return }
            scheduleSave()
        }
        .onChange(of: task) { newTask in
            guard let newTask else { return }
            pendingSave?.cancel()
            pendingSave = nil
            withBuffers { state in
                TaskEditorBuffers.adoptFromPool(newTask, state: &state, showFrontmatter: showFrontmatter)
            }
        }
        .onChange(of: showFrontmatter) { newValue in
            withBuffers { state in
                TaskEditorBuffers.setShowFrontmatter(newValue, task: task, taskId: taskId, state: &state)
            }
        }
        .onDisappear {
            pendingSave?.cancel()
            guard !deleted, task != nil else { return }
            saveNow()
        }
    }

    // MARK: - Editor

    private func taskEditor(_ task: WorkTask) -> some View {
        VStack(spacing: 0) {
            if editorMode == .preview {
                Text(title.isEmpty ? "Title" : title)
                    .foregroundStyle(title.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.title3)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            } else if !showFrontmatter {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .focused($isTitleFocused)
                    .font(.title3)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }

            if editorMode == .edit, frontmatterError {
                Text("Invalid frontmatter — changes won't save until fixed")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }

            // Agent metadata (show for tasks that have been worked on)
            if task.worktree != nil, WorkTaskAgentMetadata.hasContent(for: task) {
                WorkTaskAgentMetadata(task: task)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()

            // Body editor / preview
            Group {
                switch editorMode {
                case .edit:
                    if showFrontmatter {
                        MarkdownEditorView(text: $editorText)
                    } else {
                        MarkdownEditorView(text: $bodyText)
                    }
                case .preview:
                    MarkdownPreviewView(markdown: showFrontmatter ? YAML.bodyText(in: editorText) : bodyText)
                }
            }
            .id(taskId)

            pathBar(for: task)
        }
    }

    // MARK: - Path Bar

    private func pathBar(for task: WorkTask) -> some View {
        let path = workTaskManager.filePath(for: task)
        return HStack(spacing: 0) {
            Text(showCopiedFeedback ? "Copied!" : path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(showCopiedFeedback ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .animation(.easeInOut(duration: 0.15), value: showCopiedFeedback)
                .contentShape(Rectangle())
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                    showCopiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        showCopiedFeedback = false
                    }
                }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Primary Action

    @ViewBuilder
    private var primaryActionButton: some View {
        if let task {
            switch task.status {
            case WorkTask.ReservedStatus.new:
                Menu("Start Now") {
                    Button("Ready to Start") {
                        saveNow()
                        workTaskManager.setStatus(task, to: WorkTask.ReservedStatus.readyToStart)
                    }
                } primaryAction: {
                    saveAndPost(WorkTaskNotification.start)
                }
                .applyPrimaryActionStyle()
            case WorkTask.ReservedStatus.readyToStart:
                Menu("Ready to Start") {
                    Button("Cancel Ready to Start") {
                        saveNow()
                        workTaskManager.setStatus(task, to: WorkTask.ReservedStatus.new)
                    }
                } primaryAction: {
                    saveAndPost(WorkTaskNotification.start)
                }
                .applyPrimaryActionStyle()
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Helpers

    private func saveAndPost(_ name: Notification.Name) {
        saveNow()
        guard let task else { return }
        let projectPath = workTaskManager.projectPath
        NSApplication.shared.keyWindow?.close()
        // Async so the notification fires after the window closes.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: name,
                object: projectPath,
                userInfo: [WorkTaskNotification.taskKey: task]
            )
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem {
            saveNow()
            pendingSave = nil
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private var isDirty: Bool {
        guard let task else { return false }
        return TaskEditorBuffers.isDirty(task: task, state: bufferState, showFrontmatter: showFrontmatter)
    }

    private var bufferState: TaskEditorBufferState {
        TaskEditorBufferState(
            title: title,
            bodyText: bodyText,
            editorText: editorText,
            frontmatterError: frontmatterError,
            reloadingCount: reloadingCount
        )
    }

    private func withBuffers(_ body: (inout TaskEditorBufferState) -> Void) {
        var state = bufferState
        body(&state)
        reloadingCount = state.reloadingCount
        title = state.title
        bodyText = state.bodyText
        editorText = state.editorText
        frontmatterError = state.frontmatterError
    }

    private func saveNow() {
        guard !deleted, let existing = task else { return }
        withBuffers { state in
            TaskEditorBuffers.save(
                taskId: taskId,
                existing: existing,
                state: &state,
                showFrontmatter: showFrontmatter,
                manager: workTaskManager
            )
        }
    }
}

// MARK: - Glass Styling

extension View {
    @ViewBuilder
    func applyPrimaryActionStyle(tint: Color = .accentColor) -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .tint(tint)
        } else {
            self.buttonStyle(.borderedProminent)
                .tint(tint)
        }
    }
}
