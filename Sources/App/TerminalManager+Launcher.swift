import AppKit
import GhosttyKit

/// Launcher-tab promotion for agent commands.
///
/// Separate from the synchronous `promoteLauncher`: an agent promotion awaits the resolved
/// PATH first, so a launch that happens before the shell resolution completes still finds
/// the agent binary. A login shell resolves its own PATH and needs no await.
extension TerminalManager {

    /// Promote a `.launcher` tab to an agent surface in-place. An empty `prompt` runs the
    /// agent bare; otherwise the prompt is passed as a positional arg (see
    /// `buildAgentPromptCommand`).
    ///
    /// `@MainActor` because `promoteLauncher` builds an `NSView` and publishes through
    /// `TerminalManager` — which is not itself actor-isolated, so a plain `async` method here
    /// would run its whole body on the cooperative pool. The `await` still releases the main
    /// actor while the PATH resolves, so the interface stays live.
    @MainActor
    func promoteLauncherToAgent(
        tabId: UUID,
        in worktreeId: String,
        app: ghostty_app_t,
        command: String,
        prompt: String
    ) async {
        let path = await ShellEnvironment.awaitPath()
        guard !prompt.isEmpty else {
            promoteLauncher(
                tabId: tabId,
                in: worktreeId,
                app: app,
                command: buildBareCommand(agentCommand: command, path: path)
            )
            return
        }

        let launch = buildAgentPromptCommand(
            agentCommand: command,
            prompt: prompt,
            path: path,
            filePrefix: "clearway-launcher"
        )
        guard promoteLauncher(tabId: tabId, in: worktreeId, app: app, command: launch.command) != nil else {
            // The tab stopped being a launcher while the PATH resolved — the user closed it, or a
            // second submit promoted it first. Nothing will run the prompt file, and the command
            // recipe is what would otherwise delete it, so this launch takes it away itself.
            try? FileManager.default.removeItem(atPath: launch.promptFile)
            return
        }
    }

    /// Build a `/bin/sh -c` wrapper that runs the agent command with no initial prompt.
    /// Mirrors `buildAgentPromptCommand`'s PATH export and `set -f` (no glob)
    /// guarantees, but drops the temp-file/prompt arg and `exec`s so the wrapping
    /// shell is replaced by the agent process — tab-close signals reach the agent
    /// directly instead of the shell.
    ///
    /// Internal (not `private`) so `TerminalManagerTests` can pin the shell-injection
    /// invariants without spinning up a Ghostty surface.
    func buildBareCommand(agentCommand: String, path: String) -> String {
        let recipe = "export PATH=\"$2\"; set -f; exec $1"
        return "/bin/sh -c " + shellEscape(recipe) + " -- "
            + shellEscape(agentCommand) + " " + shellEscape(path)
    }
}
