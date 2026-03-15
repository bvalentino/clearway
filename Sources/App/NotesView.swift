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
                    .padding(8)
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
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(12)
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
    @State private var lastClickTime: Date = .distantPast

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

                if note.hasHeading {
                    Text(note.preview.isEmpty ? "No additional text" : note.preview)
                        .foregroundStyle(.tertiary)
                }
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
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(lastClickTime) < 0.3 {
                onOpen()
            } else {
                onSelect()
            }
            lastClickTime = now
        }
        .overlay(alignment: .bottom) {
            Divider().padding(.horizontal, 12)
        }
    }
}
