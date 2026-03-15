import Foundation

/// A markdown note persisted in the worktree's `.wtpad/` directory.
struct Note: Identifiable, Hashable {
    /// The filename (e.g., `20260315-142129.md`), used as a stable identifier.
    let id: String
    /// The full markdown content of the note.
    let content: String
    /// When the file was last modified on disk.
    let modificationDate: Date

    /// Title derived from the first `# ` heading, falling back to the filename without extension.
    var title: String {
        if let firstLine = content.split(separator: "\n", maxSplits: 1).first,
           firstLine.hasPrefix("# ") {
            return String(firstLine.dropFirst(2))
        }
        return id.hasSuffix(".md") ? String(id.dropLast(".md".count)) : id
    }
}
