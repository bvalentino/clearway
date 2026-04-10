import SwiftUI

/// Prompt list for the content column — mirrors WorkTaskListView's pattern.
struct PromptListView: View {
    @EnvironmentObject private var promptManager: PromptManager
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: String?
    @Binding var editorMode: TaskEditorMode
    @State private var showDeleteConfirmation = false
    @State private var isCopied = false

    private var selectedPrompt: Prompt? {
        guard let id = selection else { return nil }
        return promptManager.prompts.first { $0.id == id }
    }

    var body: some View {
        Group {
            if promptManager.prompts.isEmpty {
                emptyState
            } else {
                promptList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            Button {
                if let prompt = promptManager.createPrompt() {
                    selection = prompt.id
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .help("New prompt")
            .padding(12)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let prompt = selectedPrompt {
                        let text = "# \(prompt.title)\n\n\(prompt.content)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        isCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isCopied = false
                        }
                    }
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(isCopied ? .green : .primary)
                }
                .help("Copy prompt")
                .disabled(selectedPrompt == nil)
                .animation(.easeInOut(duration: 0.15), value: isCopied)
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
                .disabled(selectedPrompt == nil)
            }

            ToolbarItem(placement: .primaryAction) {
                Picker("Mode", selection: $editorMode) {
                    Image(systemName: "pencil").tag(TaskEditorMode.edit)
                    Image(systemName: "eye").tag(TaskEditorMode.preview)
                }
                .pickerStyle(.segmented)
                .help("Toggle edit/preview (⌘⇧P)")
                .disabled(selectedPrompt == nil)
            }
        }
        .alert(
            "Delete \"\(selectedPrompt?.title ?? "Untitled")\"?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                if let prompt = selectedPrompt {
                    selection = nil
                    promptManager.deletePrompt(prompt)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No prompts")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private var promptList: some View {
        List(selection: $selection) {
            ForEach(promptManager.prompts) { prompt in
                PromptListRow(prompt: prompt)
                    .tag(prompt.id)
                    .id(prompt)
                    .contextMenu {
                        Button {
                            openPrompt(prompt)
                        } label: {
                            Label("Open in Window", systemImage: "arrow.up.right.square")
                        }
                        Button {
                            let text = "# \(prompt.title)\n\n\(prompt.content)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        } label: {
                            Label("Copy Prompt", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            selection = prompt.id
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.inset)
    }

    private func openPrompt(_ prompt: Prompt) {
        let identifier = PromptIdentifier(promptsDirectory: promptManager.directory, promptId: prompt.id)
        openWindow(value: identifier)
    }
}

// MARK: - Row

private struct PromptListRow: View {
    let prompt: Prompt

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(prompt.title.isEmpty ? "Untitled" : prompt.title)
                .font(.body)
                .foregroundStyle(prompt.title.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            if !prompt.preview.isEmpty {
                Text(prompt.preview)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
    }
}
