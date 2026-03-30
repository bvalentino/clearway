import Foundation

/// A reusable instruction prompt persisted as a markdown file with YAML frontmatter.
///
/// File format:
/// ```
/// ---
/// title: "Prompt title"
/// ---
///
/// Prompt content here...
/// ```
struct Prompt: Identifiable, Hashable {
    let id: String
    var title: String
    var content: String
    var modificationDate: Date

    var preview: String {
        content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
    }

    // MARK: - Serialization

    func serialized() -> String {
        var lines = ["---"]
        lines.append("title: \(YAML.quote(title))")
        lines.append("---")
        if !content.isEmpty {
            lines.append("")
            lines.append(content)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    static func parse(from fileContent: String, filename: String, modificationDate: Date) -> Prompt? {
        guard let (fields, body) = YAML.parseFrontmatter(from: fileContent),
              let title = fields["title"] else { return nil }
        return Prompt(id: filename, title: title, content: body, modificationDate: modificationDate)
    }
}
