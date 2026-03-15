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

    var body: some View {
        TextEditor(text: $content)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .navigationTitle(title)
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
}
