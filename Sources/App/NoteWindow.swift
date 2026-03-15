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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TextEditor(text: $content)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Note", systemImage: "trash")
                        }

                        Divider()

                        Button {
                            save()
                            revealInFinder()
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
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
        if let firstLine = content.split(separator: "\n", maxSplits: 1).first,
           firstLine.hasPrefix("# ") {
            return String(firstLine.dropFirst(2))
        }
        return identifier.displayName
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
