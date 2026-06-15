import Foundation

/// Renders a planning prompt by interpolating the selected task's `{{ task.* }}` data into the
/// planning `instructions` stored in `WORKFLOW.json`. Planning is manual and pre-worktree with no
/// retry, so there is no `{{ attempt }}` variable.
enum PlanningConfig {

    /// Renders a planning `instructions` template against the selected task's `{{ task.* }}` data.
    /// An `{{ attempt }}` in the template reads as an unknown variable and is left verbatim. Empty
    /// instructions fall back to the task body.
    static func renderPlanningPrompt(instructions: String, task: WorkTask, taskPath: String?) -> String {
        guard !instructions.isEmpty else { return task.body }
        return renderTemplate(instructions, variables: taskVariables(task: task, taskPath: taskPath))
    }

    /// Variables available for planning-prompt interpolation. Planning has no status slugs — it runs
    /// before a worktree's loop exists — and no retry, so no `{{ attempt }}`.
    private static func taskVariables(task: WorkTask, taskPath: String?) -> [String: String] {
        var vars: [String: String] = [
            "task.title": task.title,
            "task.body": task.body,
            "task.id": task.id.uuidString,
            "task.worktree": task.worktree ?? "",
        ]
        if let taskPath {
            vars["task.path"] = taskPath
        }
        return vars
    }

    /// Single-pass template renderer that replaces `{{ key }}` patterns. Unknown variables are left
    /// as-is.
    private static func renderTemplate(_ template: String, variables: [String: String]) -> String {
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
