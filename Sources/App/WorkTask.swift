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

    var attempt: Int?
    var errorMessage: String?
    var inputTokens: Int?
    var outputTokens: Int?

    enum Status: String, CaseIterable {
        case open
        case started
        case done
        case stopped

        var label: String {
            switch self {
            case .open: return "Open"
            case .started: return "Started"
            case .done: return "Done"
            case .stopped: return "Stopped"
            }
        }
    }

    /// Combined token count, or nil if no usage data.
    var totalTokens: Int? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
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
        lines.append("title: \(YAML.quote(title))")
        lines.append("status: \(status.rawValue)")
        lines.append("worktree: \(worktree.map { YAML.quote($0) } ?? "null")")
        lines.append("created_at: \(Self.dateFormatter.string(from: createdAt))")
        lines.append("updated_at: \(Self.dateFormatter.string(from: updatedAt))")
        if let attempt { lines.append("attempt: \(attempt)") }
        if let errorMessage { lines.append("error_message: \(YAML.quote(errorMessage))") }
        if let inputTokens { lines.append("input_tokens: \(inputTokens)") }
        if let outputTokens { lines.append("output_tokens: \(outputTokens)") }
        lines.append("---")
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Parses a task from YAML frontmatter + markdown body.
    /// Returns nil if the frontmatter is missing required fields.
    static func parse(from content: String) -> WorkTask? {
        guard let (fields, body) = YAML.parseFrontmatter(from: content) else { return nil }

        // Required fields
        guard let idString = fields["id"],
              let id = UUID(uuidString: idString),
              let title = fields["title"],
              let statusString = fields["status"],
              let status = Status(rawValue: statusString) else { return nil }

        let worktree: String? = {
            guard let value = fields["worktree"], value != "null", !value.isEmpty else { return nil }
            guard isValidBranchName(value) else { return nil }
            return value
        }()

        let createdAt = fields["created_at"].flatMap { dateFormatter.date(from: $0) } ?? Date()
        let updatedAt = fields["updated_at"].flatMap { dateFormatter.date(from: $0) } ?? Date()

        var task = WorkTask(id: id, title: title, status: status, worktree: worktree, body: body)
        task.createdAt = createdAt
        task.updatedAt = updatedAt
        task.attempt = fields["attempt"].flatMap { Int($0) }
        task.errorMessage = fields["error_message"]
        task.inputTokens = fields["input_tokens"].flatMap { Int($0) }
        task.outputTokens = fields["output_tokens"].flatMap { Int($0) }
        return task
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

    // MARK: - Formatting

    /// Format a token count as abbreviated string (e.g., "12.3k", "1.2M").
    static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    // MARK: - Date Formatting

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
