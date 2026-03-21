import AppKit
import SwiftUI

/// Displays and manages reusable prompts. Used in both the sidebar detail and worktree aside panel.
struct PromptsView: View {
    @EnvironmentObject private var promptManager: PromptManager
    @Environment(\.openWindow) private var openWindow
    @State private var selectedPromptId: String?

    /// When set, shows a Play button per row for terminal injection.
    var onSendToTerminal: ((Prompt) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if promptManager.prompts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No prompts")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let lastId = promptManager.prompts.last?.id
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(promptManager.prompts) { prompt in
                            PromptRow(
                                prompt: prompt,
                                isSelected: selectedPromptId == prompt.id,
                                isLast: prompt.id == lastId,
                                onSelect: { selectedPromptId = prompt.id },
                                onOpen: { openPrompt(prompt) },
                                onDelete: { promptManager.deletePrompt(prompt) },
                                onPlay: onSendToTerminal.map { send in { send(prompt) } }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            createButton
        }
    }

    private var createButton: some View {
        Button {
            if let prompt = promptManager.createPrompt() {
                openPrompt(prompt)
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
        .padding(12)
    }

    private func openPrompt(_ prompt: Prompt) {
        let identifier = PromptIdentifier(promptsDirectory: promptManager.directory, promptId: prompt.id)
        openWindow(value: identifier)
    }
}

// MARK: - Prompt Row

private struct PromptRow: View {
    let prompt: Prompt
    let isSelected: Bool
    let isLast: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    var onPlay: (() -> Void)?
    @State private var lastClickTime: Date = .distantPast

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.title.isEmpty ? "Untitled" : prompt.title)
                    .font(.body)
                    .fontWeight(.bold)
                    .foregroundStyle(prompt.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)

                if !prompt.preview.isEmpty {
                    Text(prompt.preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            CopyPromptButton(content: prompt.content)

            if let onPlay {
                SendToTerminalButton(action: onPlay)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval {
                onOpen()
            } else {
                onSelect()
            }
            lastClickTime = now
        }
        .contextMenu {
            Button { onOpen() } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt.content, forType: .string)
            } label: {
                Label("Copy Prompt", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast { Divider().padding(.horizontal, 12) }
        }
    }
}

// MARK: - Copy Button

struct CopyPromptButton: View {
    let content: String
    var fontSize: CGFloat = 10
    @State private var isCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            isCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                isCopied = false
            }
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: fontSize))
                .frame(width: fontSize + 4, height: fontSize + 4)
                .foregroundStyle(isCopied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy prompt to clipboard")
        .animation(.easeInOut(duration: 0.15), value: isCopied)
    }
}
