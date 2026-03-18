import Foundation

/// A task — a unit of work persisted as a markdown file with YAML frontmatter
/// in `.wtpad/tasks/<id>.md`.
struct WorkTask: Identifiable, Equatable, Hashable {
    let id: UUID
    var title: String
    var status: Status
    var worktree: String?
    var createdAt: Date
    var updatedAt: Date
    var body: String

    enum Status: String, CaseIterable {
        case open
        case started
        case done

        var label: String {
            switch self {
            case .open: return "Open"
            case .started: return "Started"
            case .done: return "Done"
            }
        }
    }

    init(id: UUID = UUID(), title: String, status: Status = .open, worktree: String? = nil, body: String = "") {
        self.id = id
        self.title = title
        self.status = status
        self.worktree = worktree
        self.createdAt = Date()
        self.updatedAt = Date()
        self.body = body
    }

    // MARK: - Serialization

    /// Serializes the task to YAML frontmatter + markdown body.
    func serialized() -> String {
        var lines = ["---"]
        lines.append("id: \(id.uuidString)")
        lines.append("title: \(Self.yamlQuote(title))")
        lines.append("status: \(status.rawValue)")
        lines.append("worktree: \(worktree.map { Self.yamlQuote($0) } ?? "null")")
        lines.append("created_at: \(Self.dateFormatter.string(from: createdAt))")
        lines.append("updated_at: \(Self.dateFormatter.string(from: updatedAt))")
        lines.append("---")
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    /// Double-quote a string for YAML, escaping backslashes, double quotes, and control characters.
    private static func yamlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    // MARK: - Parsing

    /// Parses a task from YAML frontmatter + markdown body.
    /// Returns nil if the frontmatter is missing required fields.
    static func parse(from content: String) -> WorkTask? {
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
            fields[key] = yamlUnquote(raw)
        }

        // Required fields
        guard let idString = fields["id"],
              let id = UUID(uuidString: idString),
              let title = fields["title"], !title.isEmpty,
              let statusString = fields["status"],
              let status = Status(rawValue: statusString) else { return nil }

        let worktree: String? = {
            guard let value = fields["worktree"], value != "null", !value.isEmpty else { return nil }
            guard isValidBranchName(value) else { return nil }
            return value
        }()

        let createdAt = fields["created_at"].flatMap { dateFormatter.date(from: $0) } ?? Date()
        let updatedAt = fields["updated_at"].flatMap { dateFormatter.date(from: $0) } ?? Date()

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

        var task = WorkTask(id: id, title: title, status: status, worktree: worktree, body: body)
        task.createdAt = createdAt
        task.updatedAt = updatedAt
        return task
    }

    /// Strip YAML double-quote wrapper and unescape sequences (single-pass to avoid ordering bugs).
    private static func yamlUnquote(_ value: String) -> String {
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

    private static let branchNameCharacters = CharacterSet.lowercaseLetters
        .union(.uppercaseLetters)
        .union(.decimalDigits)
        .union(CharacterSet(charactersIn: "-_/."))

    /// Validates a worktree branch name contains only safe characters.
    private static func isValidBranchName(_ name: String) -> Bool {
        !name.isEmpty
            && name.unicodeScalars.allSatisfy { branchNameCharacters.contains($0) }
            && !name.contains("..")
            && !name.hasPrefix("/")
    }

    // MARK: - Date Formatting

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
