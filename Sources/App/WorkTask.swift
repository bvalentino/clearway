import Foundation

/// A task — a unit of work persisted as a markdown file with YAML frontmatter. Its location
/// encodes association: a backlog task lives centrally at `.clearway/tasks/<id>.md`; once a
/// worktree is created for it the file moves into that worktree as `.clearway/TASK.md`.
struct WorkTask: Identifiable, Equatable, Hashable {
    let id: UUID
    var title: String
    /// The task's current state. A plain slug string: the reserved backlog marker `new`,
    /// one of the fixed states, or an arbitrary slug left by an external writer. Clearway
    /// writes it and carries it through a round-trip, but never renders it.
    var status: String
    var worktree: String?
    var createdAt: Date
    var body: String

    var attempt: Int?

    /// When true, the task is a shadow task for a worktree — it tracks state but
    /// stays out of the Planning backlog until the user exposes it.
    var hidden: Bool = false

    /// Namespace for the `status` slug constants Clearway knows by name. This is an `enum` used
    /// purely as a namespace — it has no cases, so it can never be instantiated; the values are
    /// plain `static let` strings.
    enum ReservedStatus {
        /// Reserved backlog marker (pre-worktree).
        static let new = "new"

        /// What a task carries once it has a worktree.
        static let inProgress = "in_progress"

        /// Read-only: nothing writes it any more. `migrateStatus` maps the legacy `stopped` onto
        /// it, and `startTask` reads it to allow a restart.
        static let canceled = "canceled"
    }

    /// Migrates a legacy status value to its current slug. Older task files used `open`,
    /// `started`, and `stopped`; everything else passes through unchanged so an arbitrary
    /// slug round-trips verbatim.
    static func migrateStatus(_ rawValue: String) -> String {
        switch rawValue {
        case "open": return ReservedStatus.new
        case "started": return ReservedStatus.inProgress
        case "stopped": return ReservedStatus.canceled
        default: return rawValue
        }
    }

    init(id: UUID = UUID(), title: String, status: String = ReservedStatus.new, worktree: String? = nil, body: String = "") {
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
        // Identity is carried in frontmatter so it survives the rename away from `<UUID>.md`
        // when a task moves into its worktree as `TASK.md`.
        lines.append("id: \(id.uuidString)")
        lines.append("title: \(YAML.quote(title))")
        lines.append("status: \(status)")
        // Emit worktree only when linked — an absent line means backlog (no worktree), so a fresh
        // Planning task isn't cluttered with `worktree: null`. Parsing treats absent and `null` alike.
        if let worktree { lines.append("worktree: \(YAML.quote(worktree))") }
        if let attempt { lines.append("attempt: \(attempt)") }
        // Emit hidden only when true — keeps legacy (exposed) files noise-free on re-save.
        if hidden { lines.append("hidden: true") }
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

    // MARK: - Title Parsing

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
              let statusString = fields["status"], !statusString.isEmpty else { return nil }
        let status = migrateStatus(statusString)

        // Prefer the frontmatter `id` (authoritative once a task moves to `TASK.md`, where the
        // filename no longer carries the UUID); fall back to the caller-supplied id for legacy
        // central `<UUID>.md` files written before identity was serialized.
        let resolvedId = fields["id"].flatMap { UUID(uuidString: $0) } ?? id

        let worktree: String? = {
            guard let value = fields["worktree"], value != "null", !value.isEmpty else { return nil }
            guard isValidBranchName(value) else { return nil }
            return value
        }()

        var task = WorkTask(id: resolvedId, title: title, status: status, worktree: worktree, body: body)
        task.createdAt = createdAt
        task.attempt = fields["attempt"].flatMap { Int($0) }
        task.hidden = fields["hidden"] == "true"
        return task
    }

    /// Convenience overload for callers parsing editor buffer content without filesystem context.
    static func parse(from content: String) -> WorkTask? {
        parse(from: content, id: UUID(), createdAt: Date())
    }

    /// Returns the frontmatter `id`, if present and a valid UUID. A worktree `TASK.md` carries no
    /// UUID in its filename, so its identity *must* come from here — callers loading such files use
    /// this to skip a file with no usable identity rather than mint a fresh random id on every read.
    static func frontmatterID(from content: String) -> UUID? {
        guard let (fields, _) = YAML.parseFrontmatter(from: content) else { return nil }
        return fields["id"].flatMap { UUID(uuidString: $0) }
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
