import SwiftUI

/// Displays and manages markdown notes for the current worktree.
struct NotesView: View {
    @EnvironmentObject private var notesManager: NotesManager
    @Environment(\.openWindow) private var openWindow
    @State private var selectedNoteId: String?

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
                    LazyVStack(spacing: 0) {
                        ForEach(notesManager.notes) { note in
                            NoteRow(
                                note: note,
                                isSelected: selectedNoteId == note.id,
                                onSelect: { selectedNoteId = note.id },
                                onOpen: { openNote(note) }
                            )
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        notesManager.deleteNote(note)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 8)
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
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.body)
                .fontWeight(.bold)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture(count: 1) { onSelect() }
        .overlay(alignment: .bottom) {
            Divider().padding(.horizontal, 12)
        }
    }
}
