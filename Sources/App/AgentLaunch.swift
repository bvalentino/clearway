import Foundation

/// Resolves which binary to launch for Plan / workflow agents.
///
/// Prefer a non-empty `WORKFLOW.json` `agent.command`. Otherwise use Settings → Main
/// Terminal. If that is also blank (empty Main Terminal setting / UI "None"), fall back to
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
/// (not stdin). Piped stdin is avoided so agents like Grok (which ignore stdin for the
/// initial prompt) still seed the first turn; agent stdin stays on the Ghostty PTY.
///
/// Recipe positionals after `--`: `$1` agent command (unquoted so multi-word commands
/// word-split), `$2` prompt file, `$3` login-shell PATH. The file is removed after the
/// agent exits so the temp dir does not accumulate.
///
/// Practical ceiling: the full prompt becomes one argv element for the agent process.
/// Prompts near the OS `ARG_MAX` (~1 MB on recent macOS) can fail with "Argument list too
/// long". Typical launcher / Plan / workflow prompts are well under that.
///
/// - Returns: The shell command string and the prompt file path (callers that tear down
///   surfaces early can delete the file if the agent never ran).
func buildAgentPromptCommand(
    agentCommand: String,
    prompt: String,
    path: String,
    filePrefix: String = "clearway-agent-prompt"
) -> (command: String, promptFile: String) {
    let tempDir = NSTemporaryDirectory()
    let promptFile = (tempDir as NSString).appendingPathComponent("\(filePrefix)-\(UUID().uuidString).md")
    let data = Data(prompt.utf8)
    let wrote = FileManager.default.createFile(
        atPath: promptFile,
        contents: data,
        attributes: [.posixPermissions: 0o600]
    )
    if !wrote {
        Ghostty.logger.warning(
            "buildAgentPromptCommand: failed to write prompt file \(promptFile, privacy: .public)"
        )
    }
    let recipe = "export PATH=\"$3\"; set -f; $1 \"$(cat \"$2\")\"; rc=$?; rm -f \"$2\"; exit $rc"
    let command = "/bin/sh -c " + shellEscape(recipe) + " -- "
        + shellEscape(agentCommand) + " " + shellEscape(promptFile) + " " + shellEscape(path)
    return (command, promptFile)
}

/// The agents verified to accept `--model <value>`, so the flag can be appended without breaking
/// the launch: `claude --model`, `codex -m, --model <MODEL>` (openai/codex, shared CLI options —
/// flattened into both the interactive TUI and `exec`), and `grok -m, --model <MODEL>`
/// (https://docs.x.ai/build/cli/reference). An unrecognized command gets no flag.
private let agentsAcceptingModelFlag: Set<String> = ["claude", "codex", "grok"]

/// Appends `--model <model>` to an already-resolved agent command, for the agents known to accept
/// the flag. A dropped value is never an error — the agent launches on its default model.
func applyModel(to command: String, model: String?) -> String {
    guard let model = model?.trimmingCharacters(in: .whitespaces),
          isModelValueSafe(model), acceptsModelFlag(command) else { return command }
    return command + " --model " + model
}

/// Whether a model value survives the unquoted command expansion as one argv word. Only whitespace
/// is rejected — the expansion word-splits but is never re-scanned for shell operators, so this is a
/// well-formedness check, not an injection guard. Provider-prefixed and tagged IDs (`openai/gpt-5`,
/// `gpt-oss:20b`) must pass. Shared with the workflow editor, which flags a failing value inline
/// rather than letting it vanish at launch.
func isModelValueSafe(_ model: String) -> Bool {
    !model.isEmpty && !model.contains(where: \.isWhitespace)
}

/// Deliberately literal: `npx claude` and `env FOO=1 claude` read as unknown and get the no-flag
/// path, which is a missed flag rather than a broken launch.
private func acceptsModelFlag(_ command: String) -> Bool {
    guard let first = command.split(whereSeparator: \.isWhitespace).first else { return false }
    return agentsAcceptingModelFlag.contains((String(first) as NSString).lastPathComponent)
}
