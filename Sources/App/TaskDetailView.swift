import SwiftUI

enum TaskEditorMode {
    case edit, preview
}

/// Inline task editor for the 3-column layout detail pane.
/// Follows the Notes/Mail pattern: click a task in the list, edit it directly here.
struct TaskDetailView: View {
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var settings: SettingsManager

    let taskId: UUID
    @Binding var editorMode: TaskEditorMode

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var editorText: String = ""
    @State private var frontmatterError: Bool = false
    @State private var pendingSave: DispatchWorkItem?
    @State private var reloadingCount = 0
    @State private var showCopiedFeedback = false
    @AppStorage("showFrontmatter") private var showFrontmatter: Bool = false
    @FocusState private var isTitleFocused: Bool

    private var task: WorkTask? {
        workTaskManager.tasks.first { $0.id == taskId }
    }

    private var terminalVisible: Bool {
        terminalManager.isTaskTerminalVisible(for: taskId)
    }

    var body: some View {
        if let task {
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

                if !task.status.isBacklog {
                    WorkTaskAgentMetadata(task: task)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                Divider()

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

                if terminalVisible, let surface = terminalManager.existingTaskSurface(for: taskId) {
                    VStack(spacing: 0) {
                        Divider()
                        Capsule()
                            .fill(.tertiary)
                            .frame(width: 36, height: 5)
                            .padding(.vertical, 3)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newHeight = max(80, terminalManager.taskTerminalHeight(for: taskId) - value.translation.height)
                                terminalManager.setTaskTerminalHeight(newHeight, for: taskId)
                            }
                    )

                    TaskTerminalSurface(surfaceView: surface, showBorder: settings.showFocusBorder && ghosttyApp.appIsActive)
                        .frame(height: terminalManager.taskTerminalHeight(for: taskId))
                }

                pathBar(for: task)
            }
            .onAppear {
                title = task.title
                bodyText = task.body
                editorText = task.serialized()
                if task.title.isEmpty {
                    DispatchQueue.main.async { isTitleFocused = true }
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
                guard pendingSave == nil else { return }
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
                    var updated = task
                    updated.title = title
                    updated.body = bodyText
                    editorText = updated.serialized()
                    frontmatterError = false
                } else {
                    // YAML.bodyText falls back to the full document when frontmatter
                    // delimiters are malformed, so a bad buffer would turn into body
                    // text and get committed by the body-only autosave. Keep the
                    // error raised instead; saveNow blocks writes until it's fixed.
                    guard WorkTask.parse(
                        from: editorText,
                        id: taskId,
                        createdAt: task.createdAt
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
                saveNow()
            }
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

    // MARK: - Save

    private var isDirty: Bool {
        guard let task else { return false }
        if showFrontmatter {
            return editorText != task.serialized()
        }
        return title != task.title || bodyText != task.body
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

    private func saveNow() {
        guard let existing = task else { return }
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

/// Wrapper that observes a surface's focus state for the focus border setting.
private struct TaskTerminalSurface: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let showBorder: Bool

    var body: some View {
        TerminalSurface(surfaceView: surfaceView)
            .overlay {
                if showBorder && surfaceView.focused {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}
