import AppKit
import SwiftUI

/// Displays and manages markdown notes for the current worktree.
struct NotesView: View {
    @EnvironmentObject private var notesManager: NotesManager
    @Environment(\.openWindow) private var openWindow
    @State private var selectedNoteId: String?
    @State private var clipboardPath: String?
    @State private var activeObserver: Any?
    @State private var lastChangeCount: Int = 0
    @State private var clipboardTimer: Timer?
    @State private var dismissedPaths: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if let path = clipboardPath {
                ClipboardImportBanner(
                    filename: (path as NSString).lastPathComponent,
                    onImport: {
                        notesManager.importNote(from: path)
                        clipboardPath = nil
                    },
                    onDismiss: {
                        dismissedPaths.insert(path)
                        clipboardPath = nil
                    }
                )
            }

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
                        }
                    }
                    .padding(8)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            actionButtons
        }
        .onAppear {
            checkClipboard()
            clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                let count = NSPasteboard.general.changeCount
                if count != lastChangeCount {
                    lastChangeCount = count
                    checkClipboard()
                }
            }
        }
        .onDisappear {
            clipboardTimer?.invalidate()
            clipboardTimer = nil
        }
    }

    private func checkClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string) else {
            clipboardPath = nil
            return
        }
        let path = (string as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasSuffix(".md"),
              !dismissedPaths.contains(path),
              FileManager.default.fileExists(atPath: path),
              !alreadyImported(path: path) else {
            clipboardPath = nil
            return
        }
        clipboardPath = path
    }

    private func alreadyImported(path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return false }
        return notesManager.notes.contains { $0.content == content }
    }

    private var actionButtons: some View {
        HStack(spacing: 0) {
            Button {
                if let id = notesManager.createNote(),
                   let note = notesManager.notes.first(where: { $0.id == id }) {
                    openNote(note)
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 36, height: 36)
            }

            Divider()
                .frame(height: 20)

            Button {
                importNote()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 36, height: 36)
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .background(.thinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .padding(12)
    }

    private func importNote() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Select markdown files to import"

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            notesManager.importNote(from: url.path)
        }
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

private struct ClipboardImportBanner: View {
    let filename: String
    let onImport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)

            Text(filename)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button("Import") { onImport() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}
