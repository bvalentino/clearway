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

    @State private var editorText: String = ""
    @State private var frontmatterError: Bool = false
    @State private var pendingSave: DispatchWorkItem?
    @State private var reloadingCount = 0
    @State private var showCopiedFeedback = false
    @FocusState private var isTitleFocused: Bool

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

    private var terminalVisible: Bool {
        terminalManager.isTaskTerminalVisible(for: taskId)
    }

    var body: some View {
        if let task {
            VStack(spacing: 0) {
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

                if !task.status.isBacklog {
                    WorkTaskAgentMetadata(task: task)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                Divider()

                Group {
                    switch editorMode {
                    case .edit:
                        MarkdownEditorView(text: $editorText)
                    case .preview:
                        MarkdownPreviewView(markdown: WorkTask.parse(from: editorText)?.body ?? "")
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
                editorText = task.serialized()
                if task.title.isEmpty {
                    DispatchQueue.main.async { isTitleFocused = true }
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
        task.map { editorText != $0.serialized() } ?? false
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
        guard let existing = task, editorText != existing.serialized() else { return }
        let success = workTaskManager.updateFromRawContent(editorText, expectedId: taskId)
        if success {
            frontmatterError = false
            // Resync editorText to pick up the new updated_at stamp. Only bump
            // reloadingCount when the string actually changes, otherwise
            // onChange won't fire to decrement it and the next user edit gets swallowed.
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
