import Foundation

/// Resolves which binary to launch for Plan / workflow agents.
///
/// Prefer a non-empty `WORKFLOW.json` `agent.command`. Otherwise use Settings → Main
/// Terminal. If that is also blank (`None`), fall back to
/// `SettingsManager.defaultMainTerminalCommand`.
func resolveAgentCommand(
    workflowCommand: String?,
    defaults: UserDefaults = .standard
) -> String {
    let fromWorkflow = workflowCommand?.trimmingCharacters(in: .whitespaces) ?? ""
    if !fromWorkflow.isEmpty { return fromWorkflow }

    let fromSettings = (defaults.string(forKey: SettingsKey.mainTerminalCommand) ?? "")
        .trimmingCharacters(in: .whitespaces)
    if !fromSettings.isEmpty { return fromSettings }

    return SettingsManager.defaultMainTerminalCommand
}

/// Writes `prompt` to a mode-`0o600` temp file and builds a `/bin/sh -c` command that
/// launches `agentCommand` with the file contents as a **single positional argument**
/// (not stdin). Agents that take an interactive initial prompt as a CLI arg — `claude`,
/// `grok` — both work. Piped stdin is intentionally avoided: Grok ignores it for the
/// initial prompt.
///
/// Recipe positionals after `--`: `$1` agent command (unquoted so multi-word commands
/// word-split), `$2` prompt file, `$3` login-shell PATH. The file is removed after the
/// agent exits so the temp dir does not accumulate.
///
/// - Returns: The shell command string and the prompt file path (callers that tear down
///   surfaces early can delete the file if the agent never ran).
func buildAgentPromptCommand(
    agentCommand: String,
    prompt: String,
    filePrefix: String = "clearway-agent-prompt"
) -> (command: String, promptFile: String) {
    let tempDir = NSTemporaryDirectory()
    let promptFile = (tempDir as NSString).appendingPathComponent("\(filePrefix)-\(UUID().uuidString).md")
    FileManager.default.createFile(
        atPath: promptFile,
        contents: prompt.data(using: .utf8),
        attributes: [.posixPermissions: 0o600]
    )
    let recipe = "export PATH=\"$3\"; set -f; $1 \"$(cat \"$2\")\"; rc=$?; rm -f \"$2\"; exit $rc"
    let command = "/bin/sh -c " + shellEscape(recipe) + " -- "
        + shellEscape(agentCommand) + " " + shellEscape(promptFile) + " " + shellEscape(ShellEnvironment.path)
    return (command, promptFile)
}
