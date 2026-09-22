import Foundation
import GhosttyKit

extension WorkTaskCoordinator {

    /// Toggles the task terminal, carrying out whichever outcome `taskTerminalToggle` decides on.
    ///
    /// `focusOnReveal` moves first responder into the revealed surface — Cmd+J passes `true`, the
    /// path bar button `false`, so a click never steals focus. On a launch focus lands after the
    /// `await` rather than on the keypress, because the resolved shell PATH is unbounded on a
    /// session's first call; a reveal awaits nothing and focuses on the keypress itself.
    func toggleTaskTerminal(taskId: UUID, app: ghostty_app_t, focusOnReveal: Bool = false) {
        guard workTaskManager.tasks.contains(where: { $0.id == taskId }) else { return }
        let projectPath = worktreeManager.projectPath
        let makeCommand = taskTerminalLaunchCommand()

        switch Self.taskTerminalToggle(
            isVisible: terminalManager.isTaskTerminalVisible(for: taskId),
            // A surface whose `ghostty_surface_new` failed is still stored and nothing prunes it,
            // so only a live pointer counts: revealing that one protects no process and strands the
            // task on a blank strip no press can recover.
            hasSurface: terminalManager.existingTaskSurface(for: taskId)?.surfacePtr != nil,
            hasLaunchCommand: makeCommand != nil
        ) {
        case .hide:
            terminalManager.toggleTaskTerminal(for: taskId, app: app, projectPath: projectPath)
            // Returns before the post below: the notification flips a non-empty editor to preview,
            // so posting it on a hide would take the operator out of the editor mid-edit.
            return
        case .reveal:
            terminalManager.toggleTaskTerminal(for: taskId, app: app, projectPath: projectPath)
            if focusOnReveal { focusTaskTerminal(taskId) }
        case .launch:
            // The unwrap stays ahead of the claim: taking it first and then failing the unwrap
            // would hold the claim for the session, killing this task's Cmd+J and Plan both.
            guard let makeCommand, terminalManager.beginTaskLaunch(for: taskId) else { return }
            Task { @MainActor in
                defer { terminalManager.endTaskLaunch(for: taskId) }
                let command = makeCommand(await ShellEnvironment.awaitPath())
                guard !taskWasPromoted(taskId) else { return }
                terminalManager.openTaskTerminal(
                    for: taskId, app: app, projectPath: projectPath, command: command)
                if focusOnReveal { focusTaskTerminal(taskId) }
            }
        }

        // The editor owns the live (possibly unsaved) body buffer, so it decides whether there's
        // anything to show beside the terminal.
        NotificationCenter.default.post(name: WorkTaskNotification.taskTerminalOpened, object: taskId)
    }

    /// What a press of the task terminal toggle does.
    enum TaskTerminalToggle: Equatable {
        /// Flip the visible panel closed, keeping its surface.
        case hide
        /// Flip the panel open — on the surface the task already has, or a plain shell when it has
        /// none.
        case reveal
        /// Open a fresh surface running the Main Terminal command.
        case launch
    }

    /// The toggle's whole decision. A hidden surface is **revealed, never relaunched**: the launch
    /// path goes through `openTaskTerminal`, which closes the surface it replaces, so a configured
    /// Main Terminal command turned the second Cmd+J into a silent kill of the agent running in the
    /// terminal the operator had just hidden. `hasSurface` outranking `hasLaunchCommand` is what
    /// makes that unreachable, and so what makes a confirmation dialog on this path unnecessary.
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

    /// Whether the task has been promoted to a worktree since a launch claimed its terminal. Both
    /// doors onto a task terminal suspend on `ShellEnvironment.awaitPath()` before they open
    /// anything, and Start Now → Create can land in that window: `confirmCreate` writes the link and
    /// closes the terminal, so a launch that resumed regardless would reopen one for a task that has
    /// left `backlogTasks` — an agent lighting no dot anywhere, which is the state that close
    /// exists to prevent. A promoted task stays in `tasks`; it is `backlogTasks` that filters it out.
    func taskWasPromoted(_ taskId: UUID) -> Bool {
        workTaskManager.tasks.first(where: { $0.id == taskId })?.worktree != nil
    }

    /// Whether planning would take something live away from the operator. `planTask` opens a fresh
    /// surface over whatever the task terminal already holds, so a running foreground process is
    /// the one case the view must confirm before planning.
    static func planNeedsConfirmation(hasActiveProcess: Bool) -> Bool {
        hasActiveProcess
    }

    /// Which task a Start Now item plans. A row context menu's items plan their own row; the
    /// toolbar's items have no row and plan whatever is selected **at the moment of the click**.
    ///
    /// The rule holds no state, so it can never answer with an earlier selection. AppKit keeps a
    /// toolbar's `NSMenu` and the closures built with it alive across selection changes, so callers
    /// must pass `selection:` from a property read **inside** the action closure (`selectedTask`),
    /// never from a value bound when the menu was built. What capturing one cost is recorded at the
    /// call site, `WorkTaskListView.startNowItems(for:)`.
    static func startNowTarget(row: WorkTask?, selection: WorkTask?) -> WorkTask? {
        row ?? selection
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
            let path = await ShellEnvironment.awaitPath()
            guard !taskWasPromoted(taskId) else { return }
            await terminalManager.run(
                resolved, inTaskTerminalFor: taskId, app: app, directory: directory, path: path)
        }

        NotificationCenter.default.post(name: WorkTaskNotification.taskTerminalOpened, object: taskId)
    }

    private func focusTaskTerminal(_ taskId: UUID) {
        terminalManager.existingTaskSurface(for: taskId)?.takeFocus(after: 0.25)
    }
}
