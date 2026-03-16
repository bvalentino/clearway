import Foundation

/// A markdown note persisted in the worktree's `.wtpad/` directory.
struct Note: Identifiable {
    /// The filename (e.g., `20260315-142129.md`), used as a stable identifier.
    let id: String
    /// The full markdown content of the note.
    let content: String
    /// When the file was last modified on disk.
    let modificationDate: Date

    /// Whether the note has a `# ` heading line.
    var hasHeading: Bool {
        if let firstLine = content.split(separator: "\n", maxSplits: 1).first {
            return firstLine.hasPrefix("# ")
        }
        return false
    }

    /// Title derived from the first `# ` heading, falling back to the body preview or "New Note".
    var title: String {
        Self.title(from: content)
    }

    /// Body text after the title line, for use as a preview snippet.
    var preview: String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let body = lines.drop { $0.hasPrefix("# ") }
        return body.prefix(3).joined(separator: " ")
    }

    /// Creation date parsed from the timestamp filename (e.g., `20260315-142129.md`).
    var creationDate: Date? {
        Self.filenameParser.date(from: String(id.dropLast(".md".count)))
    }

    /// Extracts a title from markdown content. Used by both Note and NoteWindow.
    static func title(from content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        if let firstLine = lines.first, firstLine.hasPrefix("# ") {
            return String(firstLine.dropFirst(2))
        }
        let preview = lines.prefix(3).joined(separator: " ")
        return preview.isEmpty ? "New Note" : preview
    }

    private static let filenameParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

extension Note: Hashable {
    static func == (lhs: Note, rhs: Note) -> Bool {
        lhs.id == rhs.id && lhs.modificationDate == rhs.modificationDate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(modificationDate)
    }
}
