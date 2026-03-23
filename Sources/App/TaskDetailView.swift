import SwiftUI

enum TaskEditorMode {
    case edit, preview
}

/// Inline task editor for the 3-column layout detail pane.
/// Follows the Notes/Mail pattern: click a task in the list, edit it directly here.
struct TaskDetailView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager

    let taskId: UUID
    @Binding var editorMode: TaskEditorMode

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var pendingSave: DispatchWorkItem?
    @State private var showCopiedFeedback = false
    @FocusState private var isTitleFocused: Bool

    private var task: WorkTask? {
        workTaskManager.tasks.first { $0.id == taskId }
    }

    var body: some View {
        if let task {
            VStack(spacing: 0) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isTitleFocused)
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
                .id(taskId)

                pathBar(for: task)
            }
            .onAppear {
                title = task.title
                bodyText = task.body
                editorMode = task.body.isEmpty ? .edit : .preview
                if task.title.isEmpty {
                    DispatchQueue.main.async { isTitleFocused = true }
                }
            }
            .onChange(of: title) { _ in scheduleSave() }
            .onChange(of: bodyText) { _ in scheduleSave() }
            .onDisappear {
                pendingSave?.cancel()
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
        let work = DispatchWorkItem { saveNow() }
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
