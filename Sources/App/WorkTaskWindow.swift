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
    static let `continue` = Notification.Name("continueWorkTask")
    static let openWorktree = Notification.Name("openWorkTaskWorktree")

    /// Key used in notification userInfo to pass the WorkTask value.
    static let taskKey = "task"
}

/// A standalone task editor window with traffic lights and toolbar.
struct WorkTaskWindow: View {
    @StateObject private var workTaskManager: WorkTaskManager
    let taskId: UUID

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var pendingSave: DispatchWorkItem?
    @State private var showDeleteConfirmation = false
    @State private var deleted = false
    @State private var editorMode: EditorMode = .edit
    @FocusState private var isTitleFocused: Bool

    private enum EditorMode {
        case edit, preview
    }

    init(identifier: WorkTaskIdentifier) {
        _workTaskManager = StateObject(wrappedValue: WorkTaskManager(projectPath: identifier.projectPath))
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
                if task?.worktree == nil {
                    primaryActionButton
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Picker("Mode", selection: $editorMode) {
                    Image(systemName: "pencil").tag(EditorMode.edit)
                    Image(systemName: "eye").tag(EditorMode.preview)
                }
                .pickerStyle(.segmented)
                .help("Toggle edit/preview (⌘⇧P)")
            }

            ToolbarItem(placement: .destructiveAction) {
                if task?.worktree == nil {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete task")
                }
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
        .onAppear {
            if let task {
                title = task.title
                bodyText = task.body
                editorMode = task.body.isEmpty ? .edit : .preview
                if task.title.isEmpty {
                    DispatchQueue.main.async { isTitleFocused = true }
                }
            }
        }
        .onChange(of: title) { _ in scheduleSave() }
        .onChange(of: bodyText) { _ in scheduleSave() }
        .onDisappear {
            pendingSave?.cancel()
            guard !deleted, task != nil else { return }
            saveNow()
        }
        .background {
            Button("") {
                editorMode = editorMode == .edit ? .preview : .edit
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .hidden()
        }
    }

    // MARK: - Editor

    private func taskEditor(_ task: WorkTask) -> some View {
        VStack(spacing: 0) {
            // Title field
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isTitleFocused)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            // Agent metadata
            if task.status != .open {
                WorkTaskAgentMetadata(task: task)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()

            // Body editor / preview
            Group {
                switch editorMode {
                case .edit:
                    MarkdownEditorView(text: $bodyText)
                case .preview:
                    MarkdownPreviewView(markdown: bodyText)
                }
            }
            .id(taskId)
        }
    }

    // MARK: - Primary Action

    @ViewBuilder
    private var primaryActionButton: some View {
        if let task {
            switch task.status {
            case .open:
                Button("Start") { saveAndPost(WorkTaskNotification.start) }
                    .applyPrimaryActionStyle()
            case .stopped:
                Button("Restart") { saveAndPost(WorkTaskNotification.start) }
                    .applyPrimaryActionStyle(tint: .orange)
            case .done where task.worktree != nil:
                Button("Continue") { saveAndPost(WorkTaskNotification.continue) }
                    .applyPrimaryActionStyle()
            case .done:
                EmptyView()
            case .started:
                Button("Open") { saveAndPost(WorkTaskNotification.openWorktree) }
                    .applyPrimaryActionStyle()
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
        let work = DispatchWorkItem { saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private var isDirty: Bool {
        guard let task else { return false }
        return task.title != title || task.body != bodyText
    }

    private func saveNow() {
        guard !deleted, isDirty, var updated = task else { return }
        updated.title = title
        updated.body = bodyText
        workTaskManager.updateTask(updated)
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
