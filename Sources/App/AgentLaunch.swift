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
/// - Returns: The shell command string and the prompt file path (callers that tear down
///   surfaces early can delete the file if the agent never ran), or `nil` when the prompt file
///   could not be written.
func buildAgentPromptCommand(
    agentCommand: String,
    prompt: String,
    path: String,
    filePrefix: String = "clearway-agent-prompt"
) -> (command: String, promptFile: String)? {
    let tempDir = NSTemporaryDirectory()
    let promptFile = (tempDir as NSString).appendingPathComponent("\(filePrefix)-\(UUID().uuidString).md")
    let data = Data(prompt.utf8)
    let wrote = FileManager.default.createFile(
        atPath: promptFile,
        contents: data,
        attributes: [.posixPermissions: 0o600]
    )
    guard wrote else {
        Ghostty.logger.error(
            "buildAgentPromptCommand: failed to write prompt file \(promptFile, privacy: .public)"
        )
        return nil
    }
    let recipe = "export PATH=\"$3\"; set -f; $1 \"$(cat \"$2\")\"; rc=$?; rm -f \"$2\"; exit $rc"
    let command = "/bin/sh -c " + shellEscape(recipe) + " -- "
        + shellEscape(agentCommand) + " " + shellEscape(promptFile) + " " + shellEscape(path)
    return (command, promptFile)
}
