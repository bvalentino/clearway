import Foundation

/// Shared YAML frontmatter helpers used by Prompt and WorkTask.
enum YAML {
    /// Double-quote a string for YAML, escaping backslashes, double quotes, and control characters.
    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Strip YAML double-quote wrapper and unescape sequences (single-pass to avoid ordering bugs).
    static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 else { return value }
        let inner = String(value.dropFirst().dropLast())
        var result = ""
        var i = inner.startIndex
        while i < inner.endIndex {
            if inner[i] == "\\" && inner.index(after: i) < inner.endIndex {
                let next = inner[inner.index(after: i)]
                switch next {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                default: result.append("\\"); result.append(next)
                }
                i = inner.index(i, offsetBy: 2)
            } else {
                result.append(inner[i])
                i = inner.index(after: i)
            }
        }
        return result
    }

    // MARK: - Body Split Helpers

    /// Returns the body portion of a frontmatter-tagged document (everything after the
    /// closing `---` delimiter and its blank separator line). Falls back to the full
    /// text when the frontmatter is malformed or missing, so the user can still see and
    /// edit whatever is there.
    static func bodyText(in text: String) -> String {
        guard let range = bodyRange(in: text) else { return text }
        return String(text[range])
    }

    /// Replaces the body portion of a frontmatter-tagged document while preserving the
    /// frontmatter block verbatim. Ensures the result keeps the canonical `\n\n`
    /// separator between the closing `---` and the body. When no well-formed frontmatter
    /// is present, returns the new body as-is.
    static func replacingBody(in text: String, with newBody: String) -> String {
        guard let range = bodyRange(in: text) else { return newBody }
        let before = text[..<range.lowerBound]
        let trailingNewlines = before.reversed().prefix(while: { $0 == "\n" }).count
        let needed = newBody.isEmpty ? 0 : max(0, 2 - trailingNewlines)
        let separator = String(repeating: "\n", count: needed)
        return text.replacingCharacters(in: range, with: separator + newBody)
    }

    /// Character range covering the body (after closing `---` and optional blank separator).
    /// Returns nil when the document has no valid frontmatter delimiters.
    private static func bodyRange(in text: String) -> Range<String.Index>? {
        guard text.hasPrefix("---\n") else { return nil }
        let afterOpening = text.index(text.startIndex, offsetBy: 4)
        var searchStart = afterOpening
        while let match = text.range(of: "\n---", range: searchStart..<text.endIndex) {
            let afterDelim = match.upperBound
            if afterDelim == text.endIndex {
                return text.endIndex..<text.endIndex
            }
            if text[afterDelim] == "\n" {
                var bodyStart = text.index(after: afterDelim)
                if bodyStart < text.endIndex, text[bodyStart] == "\n" {
                    bodyStart = text.index(after: bodyStart)
                }
                return bodyStart..<text.endIndex
            }
            searchStart = text.index(after: match.lowerBound)
        }
        return nil
    }

    /// Parses YAML frontmatter from a string. Returns the key-value fields and the body after the closing `---`.
    /// Returns nil if the string doesn't start with `---` or has no closing delimiter.
    static func parseFrontmatter(from content: String) -> (fields: [String: String], body: String)? {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }

        // Find closing ---
        var endIndex: Int?
        for i in 1..<lines.count {
            if lines[i] == "---" {
                endIndex = i
                break
            }
        }
        guard let closingIndex = endIndex else { return nil }

        // Parse frontmatter key-value pairs
        var fields: [String: String] = [:]
        for i in 1..<closingIndex {
            let line = lines[i]
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            fields[key] = unquote(raw)
        }

        // Body is everything after the closing --- (skip one blank line if present)
        var bodyStartIndex = closingIndex + 1
        if bodyStartIndex < lines.count && lines[bodyStartIndex].isEmpty {
            bodyStartIndex += 1
        }
        let body: String
        if bodyStartIndex < lines.count {
            body = lines[bodyStartIndex...].joined(separator: "\n")
        } else {
            body = ""
        }

        return (fields, body)
    }
}
