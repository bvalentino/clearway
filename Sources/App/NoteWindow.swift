import AppKit
import SwiftUI

/// Identifies a note file for opening in its own window.
struct NoteIdentifier: Codable, Hashable {
    let worktreePath: String
    let filename: String

    var filePath: String {
        let clearwayDir = (worktreePath as NSString).appendingPathComponent(".clearway")
        return (clearwayDir as NSString).appendingPathComponent(filename)
    }
}

/// A standalone note editor window, styled like Apple Notes.
struct NoteWindow: View {
    let identifier: NoteIdentifier
    @State private var content: String = ""
    @State private var loaded = false
    @State private var showDeleteConfirmation = false
    @State private var deleted = false
    @State private var editorMode: EditorMode = .edit
    @State private var showCopiedFeedback = false
    @Environment(\.dismiss) private var dismiss

    private enum EditorMode {
        case edit, preview
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch editorMode {
                case .edit:
                    MarkdownEditorView(text: $content)
                case .preview:
                    MarkdownPreviewView(markdown: Note.contentWithoutFrontmatter(content))
                }
            }
            .id(identifier.filename)

            pathBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .navigationTitle(identifier.filename)
        .toolbar {
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

            ToolbarItem(placement: .primaryAction) {
                Picker("Mode", selection: $editorMode) {
                    Image(systemName: "pencil").tag(EditorMode.edit)
                    Image(systemName: "eye").tag(EditorMode.preview)
                }
                .pickerStyle(.segmented)
                .help("Toggle edit/preview")
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
                DispatchQueue.main.async {
                    NSApplication.shared.keyWindow?.close()
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .onAppear { loadIfNeeded() }
        .onDisappear { save() }
    }

    // MARK: - Path Bar

    private var pathBar: some View {
        let path = identifier.filePath
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

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = FileManager.default.contents(atPath: identifier.filePath),
           let text = String(data: data, encoding: .utf8) {
            content = text
        }
        editorMode = content.isEmpty ? .edit : .preview
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
