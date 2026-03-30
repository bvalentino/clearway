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
    @State private var pendingSave: DispatchWorkItem?
    @State private var reloadingCount = 0
    @State private var showCopiedFeedback = false
    @State private var terminalHeight: CGFloat = 200
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
                Group {
                    if editorMode == .edit {
                        TextField("Title", text: $title)
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

                if !task.status.isBacklog {
                    WorkTaskAgentMetadata(task: task)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                Divider()

                Group {
                    switch editorMode {
                    case .edit:
                        MarkdownEditorView(text: $bodyText)
                    case .preview:
                        MarkdownPreviewView(markdown: bodyText)
                    }
                }

                if terminalVisible, let surface = terminalManager.existingTaskSurface(for: taskId) {
                    Divider()
                        .padding(.vertical, 2)
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
                                    terminalHeight = max(80, terminalHeight - value.translation.height)
                                }
                        )

                    TaskTerminalSurface(surfaceView: surface, showBorder: settings.showFocusBorder && ghosttyApp.appIsActive)
                        .frame(height: terminalHeight)
                }

                pathBar(for: task)
            }
            .onAppear {
                title = task.title
                bodyText = task.body
                if terminalVisible {
                    editorMode = .edit
                } else {
                    editorMode = task.body.isEmpty ? .edit : .preview
                }
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
            .onChange(of: task.body) { newBody in
                guard newBody != bodyText, pendingSave == nil else { return }
                reloadingCount += 1
                bodyText = newBody
            }
            .onChange(of: task.title) { newTitle in
                guard newTitle != title, pendingSave == nil else { return }
                reloadingCount += 1
                title = newTitle
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
        return task.title != title || task.body != bodyText
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
        guard isDirty, var updated = task else { return }
        updated.title = title
        updated.body = bodyText
        workTaskManager.updateTask(updated)
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
