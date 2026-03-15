import SwiftUI

/// Displays and manages markdown notes for the current worktree.
struct NotesView: View {
    @EnvironmentObject private var notesManager: NotesManager
    @State private var editingNoteId: String?
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
                            if editingNoteId == note.id {
                                NoteEditor(
                                    content: $editContent,
                                    onSave: { saveAndClose(note) },
                                    onDelete: { deleteAndClose(note) }
                                )
                            } else {
                                NoteRow(note: note)
                                    .contentShape(Rectangle())
                                    .onTapGesture { beginEditing(note) }
                                    .contextMenu {
                                        Button("Delete", role: .destructive) {
                                            notesManager.deleteNote(note)
                                        }
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
        .onDisappear {
            saveEditingNote()
        }
    }

    private var createButton: some View {
        Button(action: {
            saveEditingNote()
            if let id = notesManager.createNote() {
                editingNoteId = id
                editContent = ""
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

    private func beginEditing(_ note: Note) {
        saveEditingNote()
        editingNoteId = note.id
        editContent = note.content
    }

    private func saveAndClose(_ note: Note) {
        notesManager.updateNote(note, content: editContent)
        editingNoteId = nil
        editContent = ""
    }

    private func deleteAndClose(_ note: Note) {
        editingNoteId = nil
        editContent = ""
        notesManager.deleteNote(note)
    }

    private func saveEditingNote() {
        guard let previousId = editingNoteId,
              let previous = notesManager.notes.first(where: { $0.id == previousId }) else { return }
        notesManager.updateNote(previous, content: editContent)
        editingNoteId = nil
        editContent = ""
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

private struct NoteEditor: View {
    @Binding var content: String
    let onSave: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $content)
                .font(.body)
                .frame(minHeight: 120, maxHeight: 300)
                .scrollContentBackground(.hidden)

            HStack {
                Button("Done") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Spacer()

                Button("Delete", role: .destructive) { onDelete() }
                    .controlSize(.small)
            }
        }
        .padding(12)
    }
}
