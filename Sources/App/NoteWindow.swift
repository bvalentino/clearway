import AppKit
import SwiftUI

/// Identifies a note file for opening in its own window.
struct NoteIdentifier: Codable, Hashable {
    let worktreePath: String
    let filename: String

    var filePath: String {
        let wtpadDir = (worktreePath as NSString).appendingPathComponent(".wtpad")
        return (wtpadDir as NSString).appendingPathComponent(filename)
    }

    var displayName: String {
        filename.hasSuffix(".md") ? String(filename.dropLast(".md".count)) : filename
    }
}

/// A standalone note editor window, styled like Apple Notes.
struct NoteWindow: View {
    let identifier: NoteIdentifier
    @State private var content: String = ""
    @State private var loaded = false
    @State private var showDeleteConfirmation = false
    @State private var deleted = false
    @AppStorage("noteFontSize") private var fontSize: Double = 14
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TextEditor(text: $content)
            .font(.system(size: fontSize))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 4) {
                        Button { fontSize = max(10, fontSize - 1) } label: {
                            Image(systemName: "textformat.size.smaller")
                        }
                        .help("Decrease font size (⌘−)")
                        .keyboardShortcut("-", modifiers: .command)
                        .disabled(fontSize <= 10)

                        Button { fontSize = min(28, fontSize + 1) } label: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .help("Increase font size (⌘+)")
                        .keyboardShortcut("=", modifiers: .command)
                        .disabled(fontSize >= 28)
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            save()
                            revealInFinder()
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Note", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                }
            }
            .confirmationDialog(
                "Delete this note?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deleted = true
                    try? FileManager.default.removeItem(atPath: identifier.filePath)
                    dismiss()
                }
            } message: {
                Text("This action cannot be undone.")
            }
            .onAppear { loadIfNeeded() }
            .onDisappear { save() }
    }

    private var title: String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        if let firstLine = lines.first, firstLine.hasPrefix("# ") {
            return String(firstLine.dropFirst(2))
        }
        let preview = lines.prefix(3).joined(separator: " ")
        return preview.isEmpty ? "New Note" : preview
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = FileManager.default.contents(atPath: identifier.filePath),
           let text = String(data: data, encoding: .utf8) {
            content = text
        }
    }

    private func save() {
        guard !deleted, FileManager.default.fileExists(atPath: identifier.filePath) else { return }
        let data = content.data(using: .utf8) ?? Data()
        FileManager.default.createFile(
            atPath: identifier.filePath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
    }

    private func revealInFinder() {
        NSWorkspace.shared.selectFile(identifier.filePath, inFileViewerRootedAtPath: "")
    }
}
