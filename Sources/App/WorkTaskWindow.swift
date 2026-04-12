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

    /// Editor binding — full serialized text when frontmatter is shown, body-only
    /// when hidden (writes merge back into `editorText`, preserving frontmatter).
    private var editorBinding: Binding<String> {
        if showFrontmatter {
            return $editorText
        }
        return Binding(
            get: { YAML.bodyText(in: editorText) },
            set: { newBody in editorText = YAML.replacingBody(in: editorText, with: newBody) }
        )
    }

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

    private var title: String {
        WorkTask.parseTitle(from: editorText) ?? ""
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { title },
            set: { newTitle in
                editorText = WorkTask.replacingTitle(in: editorText, with: newTitle)
            }
        )
    }

    private var taskSerialized: String {
        task?.serialized() ?? ""
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
                        let parsedBody = WorkTask.parse(from: editorText)?.body ?? ""
                        let text = "# \(title)\n\n\(parsedBody)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label("Copy Task", systemImage: "doc.on.doc")
                    }

                    if let task, task.status.isBacklog {
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
        .onAppear {
            if let task {
                editorText = task.serialized()
                editorMode = task.body.isEmpty ? .edit : .preview
                if task.title.isEmpty {
                    DispatchQueue.main.async { isTitleFocused = true }
                }
            }
        }
        .onChange(of: editorText) { _ in
            guard reloadingCount <= 0 else { reloadingCount -= 1; return }
            scheduleSave()
        }
        .onChange(of: taskSerialized) { newSerialized in
            // Preserve in-flight user edits: skip sync while a save is pending,
            // and skip while the buffer holds invalid frontmatter the user is still fixing.
            guard newSerialized != editorText, pendingSave == nil, !frontmatterError else { return }
            reloadingCount += 1
            editorText = newSerialized
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
            // Title field
            Group {
                if editorMode == .edit {
                    TextField("Title", text: titleBinding)
                        .textFieldStyle(.plain)
                        .focused($isTitleFocused)
                } else {
                    Text(title.isEmpty ? "Title" : title)
                        .foregroundStyle(title.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.title3)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if editorMode == .edit, frontmatterError {
                Text("Invalid frontmatter — changes won't save until fixed")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }

            // Agent metadata (show for tasks that have been worked on)
            if !task.status.isBacklog {
                WorkTaskAgentMetadata(task: task)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()

            // Body editor / preview
            Group {
                switch editorMode {
                case .edit:
                    MarkdownEditorView(text: editorBinding)
                case .preview:
                    MarkdownPreviewView(markdown: WorkTask.parse(from: editorText)?.body ?? "")
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
            case .new:
                Menu("Start Now") {
                    Button("Ready to Start") {
                        saveNow()
                        workTaskManager.setStatus(task, to: .readyToStart)
                    }
                } primaryAction: {
                    saveAndPost(WorkTaskNotification.start)
                }
                .applyPrimaryActionStyle()
            case .readyToStart:
                Menu("Ready to Start") {
                    Button("Cancel Ready to Start") {
                        saveNow()
                        workTaskManager.setStatus(task, to: .new)
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
        task.map { editorText != $0.serialized() } ?? false
    }

    private func saveNow() {
        guard !deleted, let existing = task, editorText != existing.serialized() else { return }
        let success = workTaskManager.updateFromRawContent(editorText, expectedId: taskId)
        if success {
            frontmatterError = false
            if let updated = task {
                let newSerialized = updated.serialized()
                if newSerialized != editorText {
                    reloadingCount += 1
                    editorText = newSerialized
                }
            }
        } else {
            frontmatterError = true
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
