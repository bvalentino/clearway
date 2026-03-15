import SwiftUI

/// Displays and manages markdown notes for the current worktree.
struct NotesView: View {
    @EnvironmentObject private var notesManager: NotesManager
    @State private var editingNote: Note?
    @State private var editContent: String = ""

    var body: some View {
        Group {
            if notesManager.notes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No notes")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(notesManager.notes) { note in
                            NoteRow(note: note)
                                .contentShape(Rectangle())
                                .onTapGesture { openNote(note) }
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        notesManager.deleteNote(note)
                                    }
                                }
                            Divider()
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            createButton
        }
        .sheet(item: $editingNote) { note in
            NoteEditorSheet(
                content: $editContent,
                title: note.title,
                onDismiss: { save in
                    if save { notesManager.updateNote(note, content: editContent) }
                    editingNote = nil
                },
                onDelete: {
                    editingNote = nil
                    notesManager.deleteNote(note)
                }
            )
        }
    }

    private var createButton: some View {
        Button(action: {
            if let id = notesManager.createNote(),
               let note = notesManager.notes.first(where: { $0.id == id }) {
                openNote(note)
            }
        }) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.blue, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(16)
    }

    private func openNote(_ note: Note) {
        editContent = note.content
        editingNote = note
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)

            Text(note.modificationDate, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct NoteEditorSheet: View {
    @Binding var content: String
    let title: String
    let onDismiss: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.isEmpty ? "New Note" : title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button("Done") { onDismiss(true) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()

            Divider()

            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("Delete", role: .destructive) { onDelete() }
                Spacer()
                Button("Cancel") { onDismiss(false) }
                Button("Save") { onDismiss(true) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
