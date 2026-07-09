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
    /// One-shot creation-focus signal owned by `ContentView`. Focus the title only when
    /// this view *is* the just-created task; plain re-selection leaves it untouched.
    @Binding var newlyCreatedTaskId: UUID?

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

    /// The Markdown rendered in preview — mirrors the editor's live buffer so it
    /// reflects unsaved edits rather than the last autosaved value.
    private var previewMarkdown: String {
        showFrontmatter ? YAML.bodyText(in: editorText) : bodyText
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

                if task.worktree != nil, WorkTaskAgentMetadata.hasContent(for: task) {
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
                        MarkdownPreviewView(markdown: previewMarkdown)
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
                if newlyCreatedTaskId == taskId {
                    newlyCreatedTaskId = nil
                    DispatchQueue.main.async { isTitleFocused = true }
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
                // Keep in-flight local edits. A pending autosave means the user has typed
                // since the last flush; adopting would clobber those keystrokes (including
                // when our own write echoes through the pool). External rewrites still land
                // once the debounce clears, and save CAS blocks ghost-clobber of agent content.
                guard pendingSave == nil else { return }
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
                saveNow()
            }
            .onReceive(NotificationCenter.default.publisher(for: WorkTaskNotification.planningTerminalOpened)) { note in
                guard note.object as? UUID == taskId else { return }
                // Show the rendered task beside the planning terminal, but only
                // when there's content to preview (mirrors the empty-body guard).
                if !previewMarkdown.isEmpty {
                    editorMode = .preview
                }
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
