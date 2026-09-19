import Foundation

/// The placeholders a saved command's `text` may carry, and the rule that resolves them.
enum CommandPlaceholders {

    static let taskPath = "{{ task_path }}"

    /// Returns the command with every `{{ task_path }}` replaced by `taskPath`, raw: the prompt
    /// reaches the agent as one argv element through `AgentLaunch`'s temp file, never through a
    /// shell, so quoting or escaping the path would arrive as literal characters.
    ///
    /// A `nil` path leaves the token verbatim rather than blanking it — a command that names no
    /// task has nothing to say about one, and an empty argument reads as a malformed path.
    static func substituted(_ command: SavedCommand, taskPath: String?) -> SavedCommand {
        guard let path = taskPath else { return command }
        var substituted = command
        substituted.text = command.text.replacingOccurrences(of: Self.taskPath, with: path)
        return substituted
    }
}
