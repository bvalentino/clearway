import Foundation
import GhosttyKit

extension WorkTaskCoordinator {

    /// Toggles the task terminal: hides it when open, otherwise opens it running the Main
    /// Terminal command (or a plain shell).
    ///
    /// `focusOnReveal` moves first responder into the revealed surface — Cmd+J passes `true`, the
    /// toolbar button `false`, so a click never steals focus. Focus lands after the launch's
    /// `await` rather than on the keypress: the resolved shell PATH is unbounded on a session's
    /// first call.
    func toggleTaskTerminal(taskId: UUID, app: ghostty_app_t, focusOnReveal: Bool = false) {
        guard workTaskManager.tasks.contains(where: { $0.id == taskId }) else { return }
        let projectPath = worktreeManager.projectPath

        if terminalManager.isTaskTerminalVisible(for: taskId) {
            terminalManager.toggleTaskTerminal(for: taskId, app: app, projectPath: projectPath)
            return
        }

        if let makeCommand = taskTerminalLaunchCommand() {
            guard terminalManager.beginTaskLaunch(for: taskId) else { return }
            Task { @MainActor in
                defer { terminalManager.endTaskLaunch(for: taskId) }
                let command = makeCommand(await ShellEnvironment.awaitPath())
                terminalManager.openTaskTerminal(
                    for: taskId, app: app, projectPath: projectPath, command: command)
                if focusOnReveal { focusTaskTerminal(taskId) }
            }
        } else {
            terminalManager.toggleTaskTerminal(for: taskId, app: app, projectPath: projectPath)
            if focusOnReveal { focusTaskTerminal(taskId) }
        }

        // The editor owns the live (possibly unsaved) body buffer, so it decides whether there's
        // anything to show beside the terminal.
        NotificationCenter.default.post(name: WorkTaskNotification.taskTerminalOpened, object: taskId)
    }

    /// What a press of the task terminal toggle does.
    enum TaskTerminalToggle: Equatable {
        /// Flip the visible panel closed, keeping its surface.
        case hide
        /// Flip the panel open on the surface the task already has, creating a plain-shell one only
        /// when there is none.
        case reveal
        /// Open a fresh surface running the Main Terminal command.
        case launch
    }

    /// The toggle's whole decision. A hidden surface is **revealed, never relaunched**: the launch
    /// path goes through `openTaskTerminal`, which closes the surface it replaces
    /// (`TerminalManager+TaskTerminals.swift:84-86`), so a configured Main Terminal command turned
    /// the second Cmd+J into a silent kill of the agent running in the terminal the operator had
    /// just hidden. `hasSurface` outranking `hasLaunchCommand` is what makes that unreachable, and
    /// so what makes a confirmation dialog on this path unnecessary.
    static func taskTerminalToggle(
        isVisible: Bool, hasSurface: Bool, hasLaunchCommand: Bool
    ) -> TaskTerminalToggle {
        if isVisible { return .hide }
        if hasSurface { return .reveal }
        return hasLaunchCommand ? .launch : .reveal
    }

    /// The command the task terminal runs, as a function of the resolved shell PATH — deferred
    /// so the choice is made up front but the command is built after the `await`. `nil` means
    /// nothing is configured to run, so the terminal opens on a plain shell.
    func taskTerminalLaunchCommand() -> ((String) -> String)? {
        // The same setting a newly created worktree's first tab reads: is a main terminal command
        // configured, or do we drop straight to a login shell? Nil when the setting is blank.
        guard let command = terminalManager.mainCommandProvider() else { return nil }
        return { [terminalManager] path in
            terminalManager.buildBareCommand(agentCommand: command, path: path)
        }
    }

    /// Whether planning would take something live away from the operator. `planTask` opens a fresh
    /// surface over whatever the task terminal already holds, so a running foreground process is
    /// the one case the view must confirm before planning.
    static func planNeedsConfirmation(hasActiveProcess: Bool) -> Bool {
        hasActiveProcess
    }

    /// Plan a backlog task: run the chosen agent command against the task's own bottom terminal,
    /// from the primary worktree. Nothing is written to the task — planning shapes the brief, it
    /// does not start the work.
    ///
    /// The task terminal rather than a main-terminal tab because the Tasks destination renders no
    /// terminal pane at all: a tab appended to the primary worktree's pane runs where nobody
    /// watching the task can see it, which is how the first cut of this looked like a dead button.
    func planTask(_ task: WorkTask, using command: SavedCommand, app: ghostty_app_t) {
        guard let resolved = planCommand(for: task, using: command) else { return }

        let taskId = task.id
        let directory = Self.planWorkingDirectory(
            worktrees: worktreeManager.worktrees,
            projectPath: worktreeManager.projectPath
        )
        guard terminalManager.beginTaskLaunch(for: taskId) else { return }
        Task { @MainActor in
            defer { terminalManager.endTaskLaunch(for: taskId) }
            await terminalManager.run(
                resolved, inTaskTerminalFor: taskId, app: app, directory: directory)
        }

        NotificationCenter.default.post(name: WorkTaskNotification.taskTerminalOpened, object: taskId)
    }

    private func focusTaskTerminal(_ taskId: UUID) {
        terminalManager.existingTaskSurface(for: taskId)?.takeFocus(after: 0.25)
    }
}
