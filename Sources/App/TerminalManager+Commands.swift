import Foundation
import GhosttyKit

/// Running a `SavedCommand`, in a worktree's main terminal or in a task's bottom terminal.
///
/// On the manager rather than in the Run dropdown because a view resolves no worktree and awaits
/// nothing: this opens the tab and either waits for the shell's first prompt before sending the
/// command, or hands the prompt to an agent tab.
extension TerminalManager {

    /// Open a new main-terminal tab in `worktree` and hand it `command`.
    func run(_ command: SavedCommand, in worktree: Worktree, app: ghostty_app_t) {
        switch CommandLaunch.launch(for: command) {
        case .shell(let send):
            let surface = appendTab(for: worktree, app: app)
            Task { @MainActor in
                await Self.awaitShellPrompt(on: surface)
                for step in send.steps {
                    switch step {
                    case .text(let line): surface.sendText(line)
                    case .enter: surface.sendEnter()
                    }
                }
            }

        case .agent(let agent, let prompt, let submit):
            // Never refused: this tab is the command the user picked, not a repeat of ⌥⌘T.
            startAgentTab(
                for: worktree,
                app: app,
                command: agent,
                prompt: prompt,
                submit: submit,
                refuseWhenInFlight: false
            )
        }
    }

    /// Run `command` in the task's own bottom terminal, from `directory` — the task-panel sibling
    /// of `run(_:in:app:)`, for the Tasks destination, which renders no main-terminal pane at all.
    ///
    /// `path` is passed in rather than awaited here: the caller has to own that suspension, because
    /// it re-reads the task across it and abandons a launch whose task has left the backlog
    /// meanwhile (`WorkTaskCoordinator.taskIsStillInBacklog`).
    ///
    /// `autoRun` picks submit-or-stage the same way. Submitting opens the surface straight onto the
    /// agent; staging has nothing to hold a draft here, so it opens a login shell and leaves the
    /// invocation on its prompt line for the operator to send.
    ///
    /// Both forms refuse when the prompt file cannot be written, the same rule `startAgentTab`
    /// applies: a `$(cat)` over a missing file seeds the agent with an empty prompt, and this door
    /// closes the task's existing terminal to open the new one, so a downgraded launch would cost
    /// the operator what was already there.
    func run(
        _ command: SavedCommand,
        inTaskTerminalFor taskId: UUID,
        app: ghostty_app_t,
        directory: String,
        path: String
    ) async {
        guard case .agent(let agent, let prompt, let submit) = CommandLaunch.launch(for: command) else { return }
        guard submit else {
            guard let staged = buildAgentPromptLine(
                agentCommand: agent,
                prompt: prompt,
                filePrefix: planFilePrefix
            ) else {
                presentPromptFileFailure(command: agent)
                return
            }
            let surface = openTaskTerminal(for: taskId, app: app, projectPath: directory, command: nil)
            await Self.awaitShellPrompt(on: surface)
            surface.sendText(Self.stagedText(staged.line))
            return
        }
        guard let launch = buildAgentPromptCommand(
            agentCommand: agent,
            prompt: prompt,
            path: path,
            filePrefix: planFilePrefix
        ) else {
            presentPromptFileFailure(command: agent)
            return
        }
        openTaskTerminal(for: taskId, app: app, projectPath: directory, command: launch.command)
    }

    /// Wait until a freshly spawned shell is at a prompt before injecting into it.
    ///
    /// The gate is a reported `pwd` **and** the cursor sitting at a prompt: `needsConfirmQuit` turns
    /// `false` only once the `133;A` mark, which zsh integration puts inside the first `PS1`, has
    /// been drawn. The first OSC 7 alone is too early — zsh emits it from the first `precmd`, before
    /// ZLE takes the tty out of cooked mode, so text sent on that edge is echoed raw under the login
    /// banner and then replayed on the prompt line, showing the command twice.
    ///
    /// The prompt half reads `confirm-close-surface`: `false` reduces the gate to `pwd` alone, and
    /// `always` keeps it shut until the fallback.
    ///
    /// `shellReadinessFallback` is for shells Ghostty injects no integration into, where `pwd` never
    /// arrives — `/bin/dash -i` never reported one, and the wait timed out at 763 ms, after which
    /// both the run and the stage landed cleanly on dash's prompt. Only a shell that reports nothing
    /// ever pays it. An agent tab is the same case — it `exec`s over the shell and reports no
    /// `pwd` — so `startAgentTab`'s staged paste always pays the full fallback window.
    ///
    /// Internal (not `private`) so `startAgentTab` can reach it: `private` does not cross a file
    /// even within a type.
    static func awaitShellPrompt(on surface: Ghostty.SurfaceView) async {
        let deadline = ContinuousClock.now + shellReadinessFallback
        while surface.pwd == nil || surface.needsConfirmQuit, ContinuousClock.now < deadline {
            try? await Task.sleep(for: shellReadinessPoll)
        }
    }
}

private let shellReadinessFallback: Duration = .milliseconds(750)
private let shellReadinessPoll: Duration = .milliseconds(10)
private let planFilePrefix = "clearway-plan"
