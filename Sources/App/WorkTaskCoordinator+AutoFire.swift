import Foundation
import GhosttyKit

// MARK: - Auto-Fire Dispatch

extension WorkTaskCoordinator {
    /// Dispatches every action in `actions` for `task` into `worktree` by
    /// spawning a fresh main tab per action. Each tab boots the agent
    /// (e.g. `claude`) under a `/bin/sh -c` wrapper that exports the resolved
    /// login-shell PATH so the agent binary can be resolved. The rendered
    /// command is pasted into the active surface 300ms after the tab opens
    /// (the agent needs a moment to start accepting input).
    ///
    /// All actions spawn in parallel — the 300ms paste is scheduled per-action
    /// via `asyncAfter`, never awaited between iterations.
    func dispatchActions(
        _ actions: [WorkflowAutomation.Action],
        for task: WorkTask,
        in worktree: Worktree,
        app: ghostty_app_t
    ) {
        let taskPath = workTaskManager.filePath(for: task)
        for action in actions {
            let agent = action.agent.trimmingCharacters(in: .whitespaces)
            // Skip blank-agent rows so an unfinished editor card doesn't spawn
            // a tab that immediately exits with `$1` empty.
            guard !agent.isEmpty else { continue }

            let rendered = WorkflowAutomation.render(
                action.command,
                task: task,
                taskPath: taskPath,
                attempt: task.attempt
            )

            // Mirror runAgent's shell wrapper, but with no prompt-file pipe —
            // the rendered command is pasted into the running agent after
            // startup, not piped to stdin. $1 is the agent (intentionally
            // unquoted so multi-word commands word-split), $2 is PATH.
            let script = shellEscape("export PATH=\"$2\"; set -f; $1")
            let args = [agent, ShellEnvironment.path].map(shellEscape).joined(separator: " ")
            let command = "/bin/sh -c \(script) -- \(args)"

            let surface = terminalManager.appendMainTab(
                for: worktree,
                app: app,
                command: command,
                projectPath: workTaskManager.projectPath
            )

            // Paste directly on the captured surface rather than routing through
            // `sendToActiveMainTab`. Each iteration's `appendMainTab` activates
            // its own tab, so by the time these timers fire only the final tab
            // is "active" — gating on `activeMainSurface` would silently drop
            // every paste except the last. `sendPaste` targets the surface
            // itself, so the user clicking another tab during the 300ms wait
            // does not redirect the paste; we also intentionally skip
            // `transferFirstResponder` so background tabs don't steal focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak surface] in
                surface?.sendPaste(rendered)
            }
        }
    }
}
