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
            let args = [action.agent, ShellEnvironment.path].map(shellEscape).joined(separator: " ")
            let command = "/bin/sh -c \(script) -- \(args)"

            let surface = terminalManager.appendMainTab(
                for: worktree,
                app: app,
                command: command,
                projectPath: workTaskManager.projectPath
            )

            // why: appendMainTab activates the new tab and returns its surface.
            // If the user clicks another tab (or switches worktrees) during the
            // 300ms agent-startup wait, sendToActiveMainTab would paste into
            // the wrong tab — possibly into a different agent or shell. Capture
            // the surface's identity now and only paste if `activeMainSurface`
            // still points to it at fire time. Missing a paste is preferable
            // to clobbering an unrelated terminal.
            let capturedId = ObjectIdentifier(surface)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                guard let active = self.terminalManager.activeMainSurface,
                      ObjectIdentifier(active) == capturedId else { return }
                self.terminalManager.sendToActiveMainTab(rendered, asCommand: false)
            }
        }
    }
}
