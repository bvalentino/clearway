import Foundation

/// Parsed PLANNING.md configuration from the project root.
///
/// The file uses YAML frontmatter for the optional agent command and a
/// markdown body as the prompt template (Mustache-style `{{ var }}`
/// interpolation). Only the surface that PLANNING.md actually needs is
/// modeled here.
struct PlanningConfig: Equatable {
    var agentCommand: String?
    var promptTemplate: String

    // MARK: - Loading

    /// Loads a planning-style markdown file from the project root. Returns nil if the file doesn't exist.
    static func load(projectPath: String, fileName: String = "PLANNING.md") -> PlanningConfig? {
        let path = (projectPath as NSString).appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }
        return parse(from: content)
    }

    /// Parses PLANNING.md content into a PlanningConfig.
    static func parse(from content: String) -> PlanningConfig? {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else {
            // No frontmatter — entire content is the template
            return PlanningConfig(promptTemplate: content)
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

        return PlanningConfig(
            agentCommand: frontmatter["agent.command"],
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
                    // This is a parent (e.g., "agent:")
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

    /// Variables available for prompt interpolation.
    private static func taskVariables(task: WorkTask, taskPath: String?, attempt: Int?) -> [String: String] {
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
        // Status raw values so prompts can reference target statuses.
        for status in WorkTask.Status.allCases {
            vars["status.\(status.rawValue)"] = status.rawValue
        }
        return vars
    }

    // MARK: - Prompt Rendering

    /// Renders the prompt template with task data interpolated.
    /// Uses simple `{{ var }}` Mustache-style replacement.
    /// Unknown variables are left as-is. An empty template falls back to
    /// `task.body`.
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
