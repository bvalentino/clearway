import CryptoKit
import Foundation

/// Parsed WORKFLOW.md configuration from the project root.
///
/// The file uses YAML frontmatter for hooks/agent settings and a markdown
/// body as the prompt template (Mustache-style `{{ var }}` interpolation).
struct WorkflowConfig: Equatable {
    var hooksAfterCreate: String?
    var hooksBeforeRun: String?
    var agentCommand: String?
    var agentTimeoutMs: Int?
    var stateCommandReadyForReview: String?
    var stateCommandDone: String?
    var stateCommandCanceled: String?
    var promptTemplate: String

    /// Whether this config has any executable content that needs trust approval.
    var hasExecutableConfig: Bool {
        hooksAfterCreate != nil || hooksBeforeRun != nil || agentCommand != nil
            || stateCommandReadyForReview != nil || stateCommandDone != nil || stateCommandCanceled != nil
    }

    /// A deterministic fingerprint of the hooks content for trust verification.
    /// Changes when any hook command, agent command, or state command changes.
    var hooksFingerprint: String {
        let content = [hooksAfterCreate, hooksBeforeRun, agentCommand,
                       stateCommandReadyForReview, stateCommandDone, stateCommandCanceled]
            .compactMap { $0 }
            .joined(separator: "\n---\n")
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Trust

    /// Whether the hooks in this config have been approved by the user for the given project.
    func isTrusted(forProject projectPath: String) -> Bool {
        guard hasExecutableConfig else { return true }
        let key = trustKey(forProject: projectPath)
        return UserDefaults.standard.string(forKey: key) == hooksFingerprint
    }

    /// Mark the current hooks as trusted for the given project.
    func markTrusted(forProject projectPath: String) {
        let key = trustKey(forProject: projectPath)
        UserDefaults.standard.set(hooksFingerprint, forKey: key)
    }

    private func trustKey(forProject projectPath: String) -> String {
        let hash = SHA256.hash(data: Data(projectPath.utf8))
        let hex = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "clearway.workflow.trusted.\(hex)"
    }

    // MARK: - Loading

    /// Loads a workflow-style markdown file from the project root. Returns nil if the file doesn't exist.
    static func load(projectPath: String, fileName: String = "WORKFLOW.md") -> WorkflowConfig? {
        let path = (projectPath as NSString).appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }
        return parse(from: content)
    }

    /// Parses WORKFLOW.md content into a WorkflowConfig.
    static func parse(from content: String) -> WorkflowConfig? {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else {
            // No frontmatter — entire content is the template
            return WorkflowConfig(promptTemplate: content)
        }

        // Find closing ---
        var closingIndex: Int?
        for i in 1..<lines.count {
            if lines[i] == "---" {
                closingIndex = i
                break
            }
        }
        guard let endIndex = closingIndex else { return nil }

        // Parse nested YAML frontmatter (2 levels deep)
        let frontmatter = parseFrontmatter(Array(lines[1..<endIndex]))

        // Body is everything after closing ---
        var bodyStart = endIndex + 1
        if bodyStart < lines.count && lines[bodyStart].isEmpty {
            bodyStart += 1
        }
        let body = bodyStart < lines.count
            ? lines[bodyStart...].joined(separator: "\n")
            : ""

        return WorkflowConfig(
            hooksAfterCreate: frontmatter["hooks.after_create"],
            hooksBeforeRun: frontmatter["hooks.before_run"],
            agentCommand: frontmatter["agent.command"],
            agentTimeoutMs: frontmatter["agent.timeout_ms"].flatMap { Int($0) },
            stateCommandReadyForReview: frontmatter["state_commands.ready_for_review"],
            stateCommandDone: frontmatter["state_commands.done"],
            stateCommandCanceled: frontmatter["state_commands.canceled"],
            promptTemplate: body
        )
    }

    // MARK: - YAML Parsing

    /// Parses simple nested YAML into flat dot-notation keys.
    /// Handles scalar values and YAML pipe (`|`) multi-line blocks.
    private static func parseFrontmatter(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var currentParent: String?
        var multiLineKey: String?
        var multiLineIndent: Int?
        var multiLineLines: [String] = []

        for line in lines {
            // If we're accumulating a multi-line block
            if let mlKey = multiLineKey, let mlIndent = multiLineIndent {
                let lineIndent = line.prefix(while: { $0 == " " }).count
                if lineIndent >= mlIndent && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    multiLineLines.append(String(line.dropFirst(mlIndent)))
                    continue
                } else {
                    // End of multi-line block
                    result[mlKey] = multiLineLines.joined(separator: "\n")
                        .trimmingCharacters(in: .newlines)
                    multiLineKey = nil
                    multiLineIndent = nil
                    multiLineLines = []
                }
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            guard let colonRange = trimmed.range(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colonRange.lowerBound])
            let rawValue = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            if indent == 0 {
                // Top-level key
                if rawValue.isEmpty {
                    // This is a parent (e.g., "hooks:")
                    currentParent = key
                } else if rawValue == "|" {
                    // Multi-line block at top level
                    multiLineKey = key
                    multiLineIndent = 2
                    multiLineLines = []
                } else {
                    currentParent = nil
                    result[key] = rawValue
                }
            } else if let parent = currentParent {
                // Nested key
                let fullKey = "\(parent).\(key)"
                if rawValue == "|" {
                    // Multi-line block
                    multiLineKey = fullKey
                    multiLineIndent = indent + 2
                    multiLineLines = []
                } else if rawValue.isEmpty {
                    // Empty nested value — skip
                    continue
                } else {
                    result[fullKey] = rawValue
                }
            }
        }

        // Flush any trailing multi-line block
        if let mlKey = multiLineKey, !multiLineLines.isEmpty {
            result[mlKey] = multiLineLines.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
        }

        return result
    }

    // MARK: - Variable Interpolation

    /// Variables available for hook and prompt interpolation.
    static func taskVariables(task: WorkTask, taskPath: String?, attempt: Int?) -> [String: String] {
        var vars: [String: String] = [
            "task.title": task.title,
            "task.body": task.body,
            "task.id": task.id.uuidString,
            "task.worktree": task.worktree ?? "",
        ]
        if let taskPath {
            vars["task.path"] = taskPath
        }
        if let attempt {
            vars["attempt"] = String(attempt)
        }
        // Status raw values so hooks can update task files
        for status in WorkTask.Status.allCases {
            vars["status.\(status.rawValue)"] = status.rawValue
        }
        return vars
    }

    /// Interpolates `{{ var }}` placeholders in a hook command with task variables.
    /// All values are shell-escaped to prevent injection via crafted task titles or bodies.
    func renderHookCommand(_ command: String, task: WorkTask, taskPath: String?) -> String {
        let variables = Self.taskVariables(task: task, taskPath: taskPath, attempt: task.attempt)
        let escaped = variables.mapValues { shellEscape($0) }
        return renderTemplate(command, variables: escaped)
    }

    func stateCommand(for status: WorkTask.Status) -> String? {
        switch status {
        case .readyForReview: return stateCommandReadyForReview
        case .done: return stateCommandDone
        case .canceled: return stateCommandCanceled
        case .new, .readyToStart, .inProgress: return nil
        }
    }

    func renderStateCommand(for status: WorkTask.Status, task: WorkTask, taskPath: String?) -> String? {
        guard let cmd = stateCommand(for: status) else { return nil }
        return renderHookCommand(cmd, task: task, taskPath: taskPath)
    }

    // MARK: - Prompt Rendering

    /// Renders the prompt template with task data interpolated.
    /// Uses simple `{{ var }}` Mustache-style replacement.
    /// Unknown variables are left as-is.
    func renderPrompt(task: WorkTask, taskPath: String?, attempt: Int?) -> String {
        guard !promptTemplate.isEmpty else { return task.body }
        let variables = Self.taskVariables(task: task, taskPath: taskPath, attempt: attempt)
        return renderTemplate(promptTemplate, variables: variables)
    }

    /// Single-pass template renderer that replaces `{{ key }}` patterns.
    private func renderTemplate(_ template: String, variables: [String: String]) -> String {
        var result = ""
        var i = template.startIndex

        while i < template.endIndex {
            // Look for {{
            if template[i] == "{",
               template.index(after: i) < template.endIndex,
               template[template.index(after: i)] == "{" {

                // Find closing }}
                let braceStart = i
                let afterOpening = template.index(i, offsetBy: 2)
                if let closingRange = template.range(of: "}}", range: afterOpening..<template.endIndex) {
                    let varName = String(template[afterOpening..<closingRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    if let value = variables[varName] {
                        result.append(value)
                    } else {
                        // Unknown variable — leave as-is
                        result.append(String(template[braceStart..<closingRange.upperBound]))
                    }
                    i = closingRange.upperBound
                } else {
                    // No closing }} — emit literal
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
