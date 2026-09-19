import AppKit
import GhosttyKit

/// Opening a main tab that runs an agent.
///
/// Separate from the synchronous `appendTab`: an agent tab awaits the resolved PATH first, so a
/// launch that happens before the shell resolution completes still finds the agent binary. A login
/// shell resolves its own PATH and needs no await.
extension TerminalManager {

    /// Claims the worktree's agent launch, reporting whether the claim is this caller's. `false`
    /// means a launch is already in flight and this one must abandon itself.
    func beginAgentLaunch(for worktreeId: String) -> Bool {
        agentLaunchesInFlight.insert(worktreeId).inserted
    }

    func endAgentLaunch(for worktreeId: String) {
        agentLaunchesInFlight.remove(worktreeId)
    }

    /// Open a tab running `command`, an agent, in `worktree`.
    ///
    /// Synchronous on purpose: the in-flight claim has to be taken in the caller's runloop turn, or
    /// the "⌘T for a new tab" empty state renders for the frame before the `Task` starts. The await
    /// that follows is what the claim covers.
    ///
    /// `prompt` empty → the agent runs bare. With `submit` the prompt is handed to the agent as one
    /// argv element (`buildAgentPromptCommand`); without it the tab opens bare and the prompt is
    /// pasted unsubmitted once the surface settles — argv delivery cannot stage.
    @MainActor
    func startAgentTab(
        for worktree: Worktree,
        app: ghostty_app_t,
        command: String,
        prompt: String = "",
        submit: Bool = true
    ) {
        guard beginAgentLaunch(for: worktree.id) else { return }
        let worktreeId = worktree.id
        Task { @MainActor in
            let path = await ShellEnvironment.awaitPath()

            guard !prompt.isEmpty, submit else {
                let surface = appendTab(
                    for: worktree,
                    app: app,
                    command: buildBareCommand(agentCommand: command, path: path)
                )
                endAgentLaunch(for: worktreeId)
                guard !prompt.isEmpty else { return }
                await Self.awaitShellPrompt(on: surface)
                surface.sendPaste(prompt)
                return
            }

            let launch = buildAgentPromptCommand(
                agentCommand: command,
                prompt: prompt,
                path: path,
                filePrefix: "clearway-agent-tab"
            )
            appendTab(for: worktree, app: app, command: launch.command)
            endAgentLaunch(for: worktreeId)
        }
    }

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
