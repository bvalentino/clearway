import SwiftUI

/// Inline prompt editor for the 3-column layout detail pane.
/// Mirrors TaskDetailView: click a prompt in the list, edit it directly here.
struct PromptDetailView: View {
    @EnvironmentObject private var promptManager: PromptManager

    let promptId: String
    @Binding var editorMode: TaskEditorMode

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var pendingSave: DispatchWorkItem?
    @State private var showCopiedFeedback = false
    @FocusState private var isTitleFocused: Bool

    private var prompt: Prompt? {
        promptManager.prompts.first { $0.id == promptId }
    }

    var body: some View {
        if let prompt {
            VStack(spacing: 0) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isTitleFocused)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                Divider()

                Group {
                    switch editorMode {
                    case .edit:
                        MarkdownEditorView(text: $bodyText)
                    case .preview:
                        MarkdownPreviewView(markdown: bodyText)
                    }
                }

                pathBar(for: prompt)
            }
            .onAppear {
                title = prompt.title
                bodyText = prompt.content
                editorMode = prompt.content.isEmpty ? .edit : .preview
                if prompt.title.isEmpty {
                    DispatchQueue.main.async { isTitleFocused = true }
                }
            }
            .onChange(of: title) { _ in scheduleSave() }
            .onChange(of: bodyText) { _ in scheduleSave() }
            .onDisappear {
                pendingSave?.cancel()
                saveNow()
            }
        }
    }

    // MARK: - Path Bar

    private func pathBar(for prompt: Prompt) -> some View {
        let path = promptManager.filePath(for: prompt)
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
        guard let prompt else { return false }
        return prompt.title != title || prompt.content != bodyText
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        guard isDirty, var updated = prompt else { return }
        updated.title = title
        updated.content = bodyText
        promptManager.updatePrompt(updated)
    }
}
