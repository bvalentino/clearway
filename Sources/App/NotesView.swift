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
                List {
                    ForEach(notesManager.notes) { note in
                        NoteRow(note: note)
                            .contentShape(Rectangle())
                            .onTapGesture { openNote(note) }
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    notesManager.deleteNote(note)
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.inset)
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
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.body)
                .fontWeight(.semibold)
                .lineLimit(1)

            HStack(spacing: 0) {
                if let date = note.creationDate {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .fontWeight(.medium)
                    Text("  ")
                }

                Text(note.preview.isEmpty ? "No additional text" : note.preview)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}
