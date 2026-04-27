import Foundation

/// Per-status automation rules loaded from `.clearway/workflow.json`.
///
/// Each `WorkTask.Status` can map to an ordered list of `Action`s describing
/// commands to run via a named agent (e.g. `claude`). The on-disk schema is:
///
/// ```json
/// {
///   "rules": {
///     "in_progress": [
///       { "command": "…", "agent": "claude" }
///     ]
///   }
/// }
/// ```
///
/// Status keys use the `WorkTask.Status.rawValue` (e.g. `"in_progress"`,
/// `"qa"`). Unknown status keys are skipped on decode for forward
/// compatibility with future statuses.
struct WorkflowAutomation: Equatable {
    /// A single command to dispatch for a status, paired with the agent that
    /// should run it. `id` is a UI-only identity for SwiftUI list diffing and
    /// is intentionally NOT persisted to JSON — it is regenerated on every
    /// decode.
    struct Action: Identifiable, Equatable, Codable {
        var id: UUID
        var command: String
        var agent: String

        init(id: UUID = UUID(), command: String, agent: String) {
            self.id = id
            self.command = command
            self.agent = agent
        }

        private enum CodingKeys: String, CodingKey {
            case command
            case agent
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = UUID()
            self.command = try container.decode(String.self, forKey: .command)
            self.agent = try container.decode(String.self, forKey: .agent)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(command, forKey: .command)
            try container.encode(agent, forKey: .agent)
        }
    }

    /// Actions per status. Statuses without rules are absent from the map.
    var rules: [WorkTask.Status: [Action]] = [:]

    /// True when at least one status has at least one action configured.
    var hasAnyRule: Bool { rules.values.contains { !$0.isEmpty } }

    /// Returns the actions configured for `status`, or an empty array when
    /// none are defined.
    func actions(for status: WorkTask.Status) -> [Action] {
        rules[status] ?? []
    }

    // MARK: - Loading

    /// Loads `.clearway/workflow.json` from the project. Returns an empty
    /// automation (no rules) when the file is missing or fails to parse, so
    /// callers never need to differentiate "absent" from "empty".
    static func load(projectPath: String) -> WorkflowAutomation {
        let path = filePath(forProject: projectPath)
        guard let data = FileManager.default.contents(atPath: path) else {
            return WorkflowAutomation(rules: [:])
        }
        do {
            return try JSONDecoder().decode(WorkflowAutomation.self, from: data)
        } catch {
            return WorkflowAutomation(rules: [:])
        }
    }

    /// Writes the automation to `.clearway/workflow.json`, creating the
    /// `.clearway/` directory when needed. Output is pretty-printed with
    /// sorted keys for stable diffs. The file is written atomically (via a
    /// `.tmp` rename) with `0o600` permissions because action commands can
    /// reference paths inside the user's environment that don't need to be
    /// world-readable.
    func save(to projectPath: String) throws {
        let fm = FileManager.default
        let dir = (projectPath as NSString).appendingPathComponent(".clearway")
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)

        let finalPath = Self.filePath(forProject: projectPath)
        let tmpPath = finalPath + ".tmp"
        guard fm.createFile(atPath: tmpPath, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmpPath])
        }
        _ = try fm.replaceItemAt(
            URL(fileURLWithPath: finalPath),
            withItemAt: URL(fileURLWithPath: tmpPath)
        )
    }

    private static func filePath(forProject projectPath: String) -> String {
        let dir = (projectPath as NSString).appendingPathComponent(".clearway")
        return (dir as NSString).appendingPathComponent("workflow.json")
    }

    // MARK: - Variable Interpolation

    /// Renders a `{{ var }}` template using the standard task variable set
    /// (`task.title`, `task.body`, `task.id`, `task.path`, `task.worktree`,
    /// `attempt`, and `status.<rawValue>` for every `WorkTask.Status`).
    /// Values are NOT shell-escaped — actions are dispatched into agent
    /// terminals, not raw shells. Unknown variables are left as-is so future
    /// templates degrade gracefully.
    static func render(_ template: String, task: WorkTask, taskPath: String?, attempt: Int?) -> String {
        var variables: [String: String] = [
            "task.title": task.title,
            "task.body": task.body,
            "task.id": task.id.uuidString,
            "task.worktree": task.worktree ?? "",
        ]
        if let taskPath {
            variables["task.path"] = taskPath
        }
        if let attempt {
            variables["attempt"] = String(attempt)
        }
        for status in WorkTask.Status.allCases {
            variables["status.\(status.rawValue)"] = status.rawValue
        }
        return renderTemplate(template, variables: variables)
    }

    /// Single-pass `{{ key }}` template renderer. Unknown keys are emitted
    /// verbatim.
    private static func renderTemplate(_ template: String, variables: [String: String]) -> String {
        var result = ""
        var i = template.startIndex

        while i < template.endIndex {
            if template[i] == "{",
               template.index(after: i) < template.endIndex,
               template[template.index(after: i)] == "{" {

                let braceStart = i
                let afterOpening = template.index(i, offsetBy: 2)
                if let closingRange = template.range(of: "}}", range: afterOpening..<template.endIndex) {
                    let varName = String(template[afterOpening..<closingRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    if let value = variables[varName] {
                        result.append(value)
                    } else {
                        result.append(String(template[braceStart..<closingRange.upperBound]))
                    }
                    i = closingRange.upperBound
                } else {
                    result.append(template[i])
                    i = template.index(after: i)
                }
            } else {
                result.append(template[i])
                i = template.index(after: i)
            }
        }

        return result
    }
}

// MARK: - Codable

extension WorkflowAutomation: Codable {
    private enum CodingKeys: String, CodingKey {
        case rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawRules = try container.decodeIfPresent([String: [Action]].self, forKey: .rules) ?? [:]
        var decoded: [WorkTask.Status: [Action]] = [:]
        for (key, actions) in rawRules {
            // Skip unknown status keys for forward-compat with future statuses
            // rather than failing the whole file.
            guard let status = WorkTask.Status(rawValue: key) else { continue }
            decoded[status] = actions
        }
        self.rules = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var rawRules: [String: [Action]] = [:]
        for (status, actions) in rules {
            rawRules[status.rawValue] = actions
        }
        try container.encode(rawRules, forKey: .rules)
    }
}
