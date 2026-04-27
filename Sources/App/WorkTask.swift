import Foundation

/// A task — a unit of work persisted as a markdown file with YAML frontmatter
/// in `.clearway/tasks/<id>.md`.
struct WorkTask: Identifiable, Equatable, Hashable {
    let id: UUID
    var title: String
    var status: Status
    var worktree: String?
    var createdAt: Date
    var body: String

    var attempt: Int?
    var errorMessage: String?
    var inputTokens: Int?
    var outputTokens: Int?

    /// When true, the task is a shadow task for a worktree — it tracks state but
    /// stays out of the Planning backlog until the user exposes it.
    var hidden: Bool = false

    /// When true, this task has opted in to workflow.json automation rules so
    /// status transitions can dispatch agent commands without further user
    /// confirmation. Default is `false` (manual).
    var auto: Bool = false

    enum Status: String, CaseIterable {
        case new
        case readyToStart = "ready_to_start"
        case inProgress = "in_progress"
        case qa
        case readyForReview = "ready_for_review"
        case done
        case canceled

        var label: String {
            switch self {
            case .new: return "New"
            case .readyToStart: return "Ready to Start"
            case .inProgress: return "In Progress"
            case .qa: return "QA"
            case .readyForReview: return "Ready for Review"
            case .done: return "Done"
            case .canceled: return "Canceled"
            }
        }

        /// Whether this status belongs in the backlog (not yet dispatched to a worktree).
        var isBacklog: Bool { self == .new || self == .readyToStart }

        /// Whether this status represents active work in a worktree.
        var isActive: Bool { self == .inProgress || self == .qa || self == .readyForReview }

        /// Migrate legacy status values from older task files.
        init?(migrating rawValue: String) {
            switch rawValue {
            case "open": self = .new
            case "started", "in_progress": self = .inProgress
            case "stopped": self = .canceled
            default: self.init(rawValue: rawValue)
            }
        }
    }

    /// Combined token count, or nil if no usage data.
    var totalTokens: Int? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
    }

    init(id: UUID = UUID(), title: String, status: Status = .new, worktree: String? = nil, body: String = "") {
        self.id = id
        self.title = title
        self.status = status
        self.worktree = worktree
        self.createdAt = Date()
        self.body = body
    }

    // MARK: - Serialization

    /// Returns the raw YAML lines for this task's frontmatter, without `---` delimiters or a trailing newline.
    func frontmatterLines() -> String {
        var lines: [String] = []
        lines.append("title: \(YAML.quote(title))")
        lines.append("status: \(status.rawValue)")
        lines.append("worktree: \(worktree.map { YAML.quote($0) } ?? "null")")
        if let attempt { lines.append("attempt: \(attempt)") }
        if let errorMessage { lines.append("error_message: \(YAML.quote(errorMessage))") }
        if let inputTokens { lines.append("input_tokens: \(inputTokens)") }
        if let outputTokens { lines.append("output_tokens: \(outputTokens)") }
        // Emit hidden only when true — keeps legacy (exposed) files noise-free on re-save.
        if hidden { lines.append("hidden: true") }
        // Emit auto only when true — same precedent as hidden so manual tasks stay clean.
        if auto { lines.append("auto: true") }
        return lines.joined(separator: "\n")
    }

    /// Serializes the task to YAML frontmatter + markdown body.
    func serialized() -> String {
        var result = "---\n\(frontmatterLines())\n---"
        if !body.isEmpty {
            result += "\n\n\(body)"
        }
        return result
    }

    // MARK: - Title Sync Helpers

    /// Finds the `title:` line inside the YAML frontmatter and returns the unquoted value.
    /// When the text has no `---` delimiters, falls back to scanning the whole input
    /// (supports bare frontmatter). Returns nil if no `title:` line is found.
    static func parseTitle(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        for index in frontmatterScanRange(in: lines) {
            let trimmed = lines[index].trimmingCharacters(in: .init(charactersIn: " \t"))
            guard trimmed.hasPrefix("title:") else { continue }
            let afterColon = trimmed.dropFirst("title:".count)
            let value = afterColon.trimmingCharacters(in: .whitespaces)
            return YAML.unquote(value)
        }
        return nil
    }

    /// Finds the first `title:` line inside the YAML frontmatter and replaces its value with
    /// `YAML.quote(newTitle)`. When the text has no `---` delimiters, falls back to the whole
    /// input (supports bare frontmatter). Returns the input unchanged if no `title:` line is found.
    static func replacingTitle(in text: String, with newTitle: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for index in frontmatterScanRange(in: lines) {
            let trimmed = lines[index].trimmingCharacters(in: .init(charactersIn: " \t"))
            guard trimmed.hasPrefix("title:") else { continue }
            lines[index] = "title: \(YAML.quote(newTitle))"
            return lines.joined(separator: "\n")
        }
        return text
    }

    /// Line-index range to scan for frontmatter fields. When the document starts with `---`
    /// and contains a closing `---`, returns the range strictly between them so body content
    /// (e.g., markdown code fences that happen to contain `title:`) is ignored. Otherwise
    /// returns the full range so bare frontmatter (no delimiters) still works.
    private static func frontmatterScanRange(in lines: [String]) -> Range<Int> {
        let fullRange = 0..<lines.count
        guard let first = lines.first,
              first.trimmingCharacters(in: .init(charactersIn: " \t")) == "---"
        else { return fullRange }
        for index in 1..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .init(charactersIn: " \t"))
            if trimmed == "---" { return 1..<index }
        }
        return fullRange
    }

    // MARK: - Parsing

    /// Parses a task from YAML frontmatter + markdown body, using caller-supplied identity
    /// and creation time (derived from the filename and file creation date, respectively).
    /// Returns nil if the frontmatter is missing required fields (`title`, `status`).
    static func parse(from content: String, id: UUID, createdAt: Date) -> WorkTask? {
        guard let (fields, body) = YAML.parseFrontmatter(from: content) else { return nil }

        guard let title = fields["title"],
              let statusString = fields["status"],
              let status = Status(migrating: statusString) else { return nil }

        let worktree: String? = {
            guard let value = fields["worktree"], value != "null", !value.isEmpty else { return nil }
            guard isValidBranchName(value) else { return nil }
            return value
        }()

        var task = WorkTask(id: id, title: title, status: status, worktree: worktree, body: body)
        task.createdAt = createdAt
        task.attempt = fields["attempt"].flatMap { Int($0) }
        task.errorMessage = fields["error_message"]
        task.inputTokens = fields["input_tokens"].flatMap { Int($0) }
        task.outputTokens = fields["output_tokens"].flatMap { Int($0) }
        task.hidden = fields["hidden"] == "true"
        task.auto = fields["auto"] == "true"
        return task
    }

    /// Convenience overload for callers parsing editor buffer content without filesystem context.
    static func parse(from content: String) -> WorkTask? {
        parse(from: content, id: UUID(), createdAt: Date())
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
}
