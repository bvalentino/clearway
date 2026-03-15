import SwiftUI

/// Displays and manages markdown notes for the current worktree.
struct NotesView: View {
    @EnvironmentObject private var notesManager: NotesManager
    @Environment(\.openWindow) private var openWindow

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
        guard let worktreePath = notesManager.worktreePath else { return }
        let identifier = NoteIdentifier(worktreePath: worktreePath, filename: note.id)
        openWindow(value: identifier)
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

            if let date = note.creationDate {
                Text(date, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
