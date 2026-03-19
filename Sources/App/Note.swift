import Foundation

/// A markdown note persisted in the worktree's `.wtpad/` directory.
struct Note: Identifiable {
    /// The filename (e.g., `20260315-142129.md`), used as a stable identifier.
    let id: String
    /// The full markdown content of the note.
    let content: String
    /// When the file was last modified on disk.
    let modificationDate: Date

    /// Content with YAML frontmatter stripped, used for title/preview extraction.
    private var body: String { Self.contentWithoutFrontmatter(content) }

    /// Whether the note has a `# ` heading line.
    var hasHeading: Bool {
        if let firstLine = body.split(separator: "\n", omittingEmptySubsequences: true).first {
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
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
        let rest = lines.drop { $0.hasPrefix("# ") }
        return rest.prefix(3).joined(separator: " ")
    }

    /// Creation date parsed from the timestamp filename (e.g., `20260315-142129.md`).
    var creationDate: Date? {
        NotesManager.timestampFormatter.date(from: String(id.dropLast(".md".count)))
    }

    /// Strips YAML frontmatter (delimited by `---`) from the beginning of content.
    static func contentWithoutFrontmatter(_ content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first, firstLine == "---" else {
            return content
        }
        for i in 1..<lines.count {
            if lines[i] == "---" {
                return lines.dropFirst(i + 1).joined(separator: "\n")
            }
        }
        return content
    }

    /// Extracts a title from markdown content. Used by both Note and NoteWindow.
    static func title(from content: String) -> String {
        let body = contentWithoutFrontmatter(content)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
        if let firstLine = lines.first, firstLine.hasPrefix("# ") {
            return String(firstLine.dropFirst(2))
        }
        if let firstLine = lines.first {
            return String(firstLine)
        }
        return "New Note"
    }
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
