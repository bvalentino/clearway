import Foundation

/// The agents Clearway can launch, in display order — the rows Settings → Main Terminal offers
/// and the agent rows of the tab strip's `+` menu. One list, so the two cannot disagree.
let agentAllowlist = ["claude", "codex", "grok"]

/// One agent row of the tab strip's `+` menu. The New Terminal row above them is fixed and is not
/// modelled here.
struct AgentMenuRow: Equatable {
    let command: String
    /// Whether this row carries ⌥⌘T, the Settings → Main Terminal shortcut.
    let carriesMainTerminalShortcut: Bool

    var title: String { command.capitalized }
}

/// The `+` menu's agent rows. The row matching the configured Main Terminal command carries ⌥⌘T;
/// a nil or unlisted command leaves every row without one, and ⌥⌘T still runs the setting.
func agentMenuRows(agents: [String], mainCommand: String?) -> [AgentMenuRow] {
    agents.map { AgentMenuRow(command: $0, carriesMainTerminalShortcut: $0 == mainCommand) }
}

/// Writes `prompt` to a mode-`0o600` temp file and builds a `/bin/sh -c` command that
/// launches `agentCommand` with the file contents as a **single positional argument**
/// (not stdin). Piped stdin is avoided so agents like Grok (which ignore stdin for the
/// initial prompt) still seed the first turn; agent stdin stays on the Ghostty PTY.
///
/// Recipe positionals after `--`: `$1` agent command (unquoted so multi-word commands
/// word-split), `$2` prompt file, `$3` login-shell PATH. The file is removed after the
/// agent exits so the temp dir does not accumulate.
///
/// Practical ceiling: the full prompt becomes one argv element for the agent process.
/// Prompts near the OS `ARG_MAX` (~1 MB on recent macOS) can fail with "Argument list too
/// long". Typical agent prompts are well under that.
///
/// - Returns: The shell command string and the path of the prompt file it will read, or `nil`
///   when that file could not be written. The recipe removes the file itself; the path is
///   returned so the tests can clean up after a command they never run.
func buildAgentPromptCommand(
    agentCommand: String,
    prompt: String,
    path: String,
    filePrefix: String = "clearway-agent-prompt"
) -> (command: String, promptFile: String)? {
    guard let promptFile = writeAgentPromptFile(prompt, filePrefix: filePrefix) else { return nil }
    let recipe = "export PATH=\"$3\"; set -f; $1 \"$(cat \"$2\")\"; rc=$?; rm -f \"$2\"; exit $rc"
    let command = "/bin/sh -c " + shellEscape(recipe) + " -- "
        + shellEscape(agentCommand) + " " + shellEscape(promptFile) + " " + shellEscape(path)
    return (command, promptFile)
}

/// The same launch as one line for a user to read and press Enter on, for a surface that has to
/// show the invocation instead. The prompt stays in the same `0o600` temp file, so a multi-line
/// prompt stages as one short line and still reaches the agent as one argv element.
///
/// Clearway runs nothing here: `sendText` stages the line on an interactive prompt, visible and
/// editable, and it is the operator's own shell that reads it as source if they press Enter. So
/// `agentCommand` is concatenated in as typed — the command is the user's, the same contract as
/// `buildOpenInScript`, and a command carrying flags or shell operators is the point. Only the
/// file path is escaped, because Clearway chose that one.
///
/// Nothing deletes the file here: the line is the user's to edit, re-run or abandon, and a `rm`
/// welded onto it would take the prompt away the first time they interrupt the agent.
///
/// - Returns: `nil` when the prompt file could not be written, for the same reason the run form
///   refuses: the line's `$(cat)` over a missing file would seed the agent with an empty prompt.
func buildAgentPromptLine(
    agentCommand: String,
    prompt: String,
    filePrefix: String = "clearway-agent-prompt"
) -> (line: String, promptFile: String)? {
    guard let promptFile = writeAgentPromptFile(prompt, filePrefix: filePrefix) else { return nil }
    return (agentCommand + " \"$(cat " + shellEscape(promptFile) + ")\"", promptFile)
}

private func writeAgentPromptFile(_ prompt: String, filePrefix: String) -> String? {
    let tempDir = NSTemporaryDirectory()
    let promptFile = (tempDir as NSString).appendingPathComponent("\(filePrefix)-\(UUID().uuidString).md")
    let wrote = FileManager.default.createFile(
        atPath: promptFile,
        contents: Data(prompt.utf8),
        attributes: [.posixPermissions: 0o600]
    )
    guard wrote else {
        Ghostty.logger.error(
            "writeAgentPromptFile: failed to write prompt file \(promptFile, privacy: .public)"
        )
        return nil
    }
    return promptFile
}
