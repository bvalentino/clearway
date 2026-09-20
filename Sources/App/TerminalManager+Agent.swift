import AppKit
import Foundation
import GhosttyKit

/// Opening a main tab that runs an agent.
///
/// Separate from the synchronous `appendTab`: an agent tab awaits the resolved PATH first, so a
/// launch that happens before the shell resolution completes still finds the agent binary. A login
/// shell resolves its own PATH and needs no await.
extension TerminalManager {

    /// How an agent tab's prompt reaches the agent.
    ///
    /// Internal (not private) so the rule below is testable: nothing else in `startAgentTab` is,
    /// because appending a tab needs a `ghostty_app_t`.
    enum PromptDelivery: Equatable {
        /// No prompt — the agent runs bare. What ⌥⌘T and the `+` menu's agent rows ask for.
        case bare
        /// The prompt is handed to the agent as one argv element (`buildAgentPromptCommand`).
        case argv
        /// The tab opens bare and the prompt is typed in unsubmitted — argv delivery cannot stage.
        case staged
    }

    /// `submit` chooses between argv and staged delivery; with no prompt there is nothing to
    /// deliver and `submit` does not matter.
    static func promptDelivery(prompt: String, submit: Bool) -> PromptDelivery {
        guard !prompt.isEmpty else { return .bare }
        return submit ? .argv : .staged
    }

    /// What staged delivery hands the surface. The one definition, used by both staged call sites:
    /// `startAgentTab`'s `.staged` tail and `sendToActiveMainTab(asCommand: false)`.
    ///
    /// The trim is load-bearing, not cosmetic. Outside bracketed paste libghostty rewrites every
    /// `\n` to `\r` (`ghostty/src/input/paste.zig`), which is an Enter — so an untrimmed trailing
    /// newline submits the text this rule exists to leave unsubmitted.
    static func stagedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a launch proceeds after trying to claim its worktree's marker. A door that does not
    /// refuse opens its tab whether or not another launch already holds the marker — the marker is
    /// a rendering gate first, and only ⌥⌘T treats a held one as "this press is a repeat".
    static func proceedsWithLaunch(ownsMarker: Bool, refuseWhenInFlight: Bool) -> Bool {
        ownsMarker || !refuseWhenInFlight
    }

    /// Marks the worktree's agent launch in flight, reporting whether the marker is this caller's.
    /// `false` means another launch already owns it, and this one must leave it alone.
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
    /// `refuseWhenInFlight` has no default because it is a property of the door, not of the launch:
    /// only ⌥⌘T passes `true`, where a second press while the first is still awaiting PATH is a
    /// repeat of that press. Every other door — the `+` menu's other agent rows, a saved agent
    /// command, a created worktree's first tab — names a tab the user asked for by itself and must
    /// open it whether or not another launch happens to be in flight in the same worktree. Only the
    /// launch that owns the marker ends it, so a launch that passed the marker by cannot clear the
    /// gate out from under its owner.
    func startAgentTab(
        for worktree: Worktree,
        app: ghostty_app_t,
        command: String,
        prompt: String = "",
        submit: Bool = true,
        refuseWhenInFlight: Bool
    ) {
        let ownsLaunch = beginAgentLaunch(for: worktree.id)
        guard Self.proceedsWithLaunch(ownsMarker: ownsLaunch, refuseWhenInFlight: refuseWhenInFlight)
        else { return }
        let worktreeId = worktree.id
        let delivery = Self.promptDelivery(prompt: prompt, submit: submit)

        Task { @MainActor in
            let path = await ShellEnvironment.awaitPath()

            // The pane can be gone by now — closed, pruned, or the worktree deleted. `appendTab`
            // would rebuild it, resurrecting a worktree the user just tore down, so bail instead.
            // Ahead of building the command so the argv path allocates no orphan prompt file.
            guard hasPane(for: worktreeId) else {
                if ownsLaunch { endAgentLaunch(for: worktreeId) }
                return
            }

            let launchCommand: String
            switch delivery {
            case .bare, .staged:
                launchCommand = buildBareCommand(agentCommand: command, path: path)
            case .argv:
                // No prompt file, no launch: the recipe's `$(cat)` would hand the agent an empty
                // prompt, and falling back to a bare tab would silently downgrade "run this prompt"
                // to "type it in for me". The claim has to end here too — nothing cancels this Task.
                guard let launch = buildAgentPromptCommand(
                    agentCommand: command,
                    prompt: prompt,
                    path: path,
                    filePrefix: "clearway-agent-tab"
                ) else {
                    if ownsLaunch { endAgentLaunch(for: worktreeId) }
                    let alert = NSAlert()
                    alert.messageText = "Couldn't start \(command)"
                    alert.informativeText =
                        "Clearway couldn't write the prompt file in \(NSTemporaryDirectory())."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
                launchCommand = launch.command
            }

            let surface = appendTab(for: worktree, app: app, command: launchCommand)
            if ownsLaunch { endAgentLaunch(for: worktreeId) }

            guard delivery == .staged else { return }
            await Self.awaitShellPrompt(on: surface)
            surface.sendText(Self.stagedText(prompt))
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
