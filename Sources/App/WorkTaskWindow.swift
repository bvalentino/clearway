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
            guard reloadingCount <= 0 else { reloadingCount -= 1; return }
            scheduleSave()
        }
        .onChange(of: bodyText) { _ in
            guard reloadingCount <= 0 else { reloadingCount -= 1; return }
            scheduleSave()
        }
        .onChange(of: editorText) { _ in
            guard showFrontmatter else { return }
            guard reloadingCount <= 0 else { reloadingCount -= 1; return }
            scheduleSave()
        }
        .onChange(of: task) { newTask in
            guard let newTask, pendingSave == nil else { return }
            if newTask.title != title {
                reloadingCount += 1
                title = newTask.title
            }
            if newTask.body != bodyText {
                reloadingCount += 1
                bodyText = newTask.body
            }
            if showFrontmatter, !frontmatterError {
                let newSer = newTask.serialized()
                if newSer != editorText {
                    reloadingCount += 1
                    editorText = newSer
                }
            }
        }
        .onChange(of: showFrontmatter) { newValue in
            if newValue {
                if var updated = task {
                    updated.title = title
                    updated.body = bodyText
                    editorText = updated.serialized()
                }
                frontmatterError = false
            } else {
                // YAML.bodyText falls back to the full document when frontmatter
                // delimiters are malformed, so a bad buffer would turn into body
                // text and get committed by the body-only autosave. Keep the
                // error raised instead; saveNow blocks writes until it's fixed.
                let createdAt = task?.createdAt ?? Date()
                guard WorkTask.parse(
                    from: editorText,
                    id: taskId,
                    createdAt: createdAt
                ) != nil else {
                    frontmatterError = true
                    return
                }
                if let parsed = WorkTask.parseTitle(from: editorText) {
                    title = parsed
                }
                bodyText = YAML.bodyText(in: editorText)
                frontmatterError = false
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
        guard let task else { return false }
        if showFrontmatter {
            return editorText != task.serialized()
        }
        return title != task.title || bodyText != task.body
    }

    private func saveNow() {
        guard !deleted, let existing = task else { return }
        if showFrontmatter {
            guard editorText != existing.serialized() else { return }
            let success = workTaskManager.applyEditorBuffer(editorText, expectedId: taskId)
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
        } else {
            // Honor the "changes won't save until fixed" banner: if the last known
            // buffer had invalid frontmatter, a body-only write would silently clear
            // the error and commit state the user was told wouldn't save.
            guard !frontmatterError else { return }
            guard title != existing.title || bodyText != existing.body else { return }
            var updated = existing
            updated.title = title
            updated.body = bodyText
            workTaskManager.updateTask(updated)
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
