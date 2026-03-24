import SwiftUI

/// Identifies a prompt for opening in its own window.
struct PromptIdentifier: Codable, Hashable {
    let promptsDirectory: String
    let promptId: String
}

/// A standalone prompt editor window.
struct PromptWindow: View {
    @StateObject private var promptManager: PromptManager
    let promptId: String

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var pendingSave: DispatchWorkItem?
    @State private var showDeleteConfirmation = false
    @State private var deleted = false
    @State private var isLoaded = false
    @State private var editorMode: TaskEditorMode = .edit
    @FocusState private var isTitleFocused: Bool

    init(identifier: PromptIdentifier) {
        _promptManager = StateObject(wrappedValue: PromptManager(directory: identifier.promptsDirectory))
        promptId = identifier.promptId
    }

    private var prompt: Prompt? {
        promptManager.prompts.first { $0.id == promptId }
    }

    var body: some View {
        Group {
            if let prompt {
                promptEditor(prompt)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Prompt not found")
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
                Picker("Mode", selection: $editorMode) {
                    Image(systemName: "pencil").tag(TaskEditorMode.edit)
                    Image(systemName: "eye").tag(TaskEditorMode.preview)
                }
                .pickerStyle(.segmented)
                .help("Toggle edit/preview")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Prompt", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("More actions")
            }
        }
        .alert(
            "Delete \"\(title.isEmpty ? "Untitled" : title)\"?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                deleted = true
                if let prompt { promptManager.deletePrompt(prompt) }
                DispatchQueue.main.async {
                    NSApplication.shared.keyWindow?.close()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .onAppear {
            promptManager.startWatching()
            if let prompt {
                loadFields(from: prompt)
            }
        }
        .onChange(of: prompt) { newPrompt in
            guard let newPrompt, !isLoaded else { return }
            loadFields(from: newPrompt)
        }
        .onChange(of: title) { _ in scheduleSave() }
        .onChange(of: content) { _ in scheduleSave() }
        .onDisappear {
            pendingSave?.cancel()
            guard !deleted, prompt != nil else { return }
            saveNow()
        }
    }

    private func loadFields(from prompt: Prompt) {
        isLoaded = true
        title = prompt.title
        content = prompt.content
        editorMode = prompt.content.isEmpty ? .edit : .preview
        if prompt.title.isEmpty {
            DispatchQueue.main.async { isTitleFocused = true }
        }
    }

    // MARK: - Editor

    private func promptEditor(_ prompt: Prompt) -> some View {
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
                    MarkdownEditorView(text: $content)
                case .preview:
                    MarkdownPreviewView(markdown: content)
                }
            }
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private var isDirty: Bool {
        guard let prompt else { return false }
        return prompt.title != title || prompt.content != content
    }

    private func saveNow() {
        guard !deleted, isDirty, let prompt else { return }
        let updated = Prompt(id: prompt.id, title: title, content: content, modificationDate: Date())
        promptManager.updatePrompt(updated)
    }
}
