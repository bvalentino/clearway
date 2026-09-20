import Foundation

/// The agents Clearway can launch, in picker order — the rows Settings → Main Terminal offers.
let agentAllowlist = ["claude", "grok", "codex"]

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
/// long". Typical prompt-launcher prompts are well under that.
///
/// - Returns: The shell command string and the prompt file path (callers that tear down
///   surfaces early can delete the file if the agent never ran).
func buildAgentPromptCommand(
    agentCommand: String,
    prompt: String,
    path: String,
    filePrefix: String = "clearway-agent-prompt"
) -> (command: String, promptFile: String) {
    let promptFile = writeAgentPromptFile(prompt, filePrefix: filePrefix)
    let recipe = "export PATH=\"$3\"; set -f; $1 \"$(cat \"$2\")\"; rc=$?; rm -f \"$2\"; exit $rc"
    let command = "/bin/sh -c " + shellEscape(recipe) + " -- "
        + shellEscape(agentCommand) + " " + shellEscape(promptFile) + " " + shellEscape(path)
    return (command, promptFile)
}

/// The same launch as one line for a user to read and press Enter on, for a surface that has no
/// launcher to stage a draft in. The prompt stays in the same `0o600` temp file, so a multi-line
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
func buildAgentPromptLine(
    agentCommand: String,
    prompt: String,
    filePrefix: String = "clearway-agent-prompt"
) -> (line: String, promptFile: String) {
    let promptFile = writeAgentPromptFile(prompt, filePrefix: filePrefix)
    return (agentCommand + " \"$(cat " + shellEscape(promptFile) + ")\"", promptFile)
}

private func writeAgentPromptFile(_ prompt: String, filePrefix: String) -> String {
    let tempDir = NSTemporaryDirectory()
    let promptFile = (tempDir as NSString).appendingPathComponent("\(filePrefix)-\(UUID().uuidString).md")
    let wrote = FileManager.default.createFile(
        atPath: promptFile,
        contents: Data(prompt.utf8),
        attributes: [.posixPermissions: 0o600]
    )
    if !wrote {
        Ghostty.logger.warning(
            "writeAgentPromptFile: failed to write prompt file \(promptFile, privacy: .public)"
        )
    }
    return promptFile
}
