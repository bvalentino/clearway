import AppKit
import GhosttyKit
import os

private let planLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.getclearway.mac",
    category: "plan"
)

extension WorkTaskCoordinator {

    /// Toggles the planning terminal: hides it when open, otherwise opens it running the planning
    /// agent (or the bare Main Terminal command, or a plain shell).
    ///
    /// `focusOnReveal` moves first responder into the revealed surface — Cmd+J passes `true`, the
    /// toolbar button `false`, so a click never steals focus. Focus lands after the launch's
    /// `await` rather than on the keypress: the resolved shell PATH is unbounded on a session's
    /// first call.
    func planTask(taskId: UUID, app: ghostty_app_t, focusOnReveal: Bool = false) {
        guard let task = workTaskManager.tasks.first(where: { $0.id == taskId }) else { return }
        let projectPath = worktreeManager.projectPath

        if terminalManager.isTaskTerminalVisible(for: taskId) {
            terminalManager.toggleTaskTerminal(for: taskId, app: app, projectPath: projectPath)
            return
        }

        if let makeCommand = planningLaunchCommand(for: task) {
            guard terminalManager.beginTaskLaunch(for: taskId) else { return }
            Task { @MainActor in
                defer { terminalManager.endTaskLaunch(for: taskId) }
                let command = makeCommand(await ShellEnvironment.awaitPath())
                terminalManager.openTaskTerminalWithCommand(
                    for: taskId, app: app, projectPath: projectPath, command: command)
                if focusOnReveal { focusTaskTerminal(taskId) }
            }
        } else {
            terminalManager.toggleTaskTerminal(for: taskId, app: app, projectPath: projectPath)
            if focusOnReveal { focusTaskTerminal(taskId) }
        }

        // The editor owns the live (possibly unsaved) body buffer, so it decides whether there's
        // anything to show beside the terminal.
        NotificationCenter.default.post(name: WorkTaskNotification.planningTerminalOpened, object: taskId)
    }

    /// The command the planning terminal runs, as a function of the resolved shell PATH — deferred
    /// so the choice is made up front but the command is built after the `await`. `nil` means
    /// nothing is configured to run, so the terminal opens on a plain shell.
    private func planningLaunchCommand(for task: WorkTask) -> ((String) -> String)? {
        if let instructions = planningInstructions {
            let prompt = PlanningConfig.renderPlanningPrompt(
                instructions: instructions,
                task: task,
                taskPath: workTaskManager.filePath(for: task)
            )
            let agentCmd = planningAgentCommand
            return { path in
                let launch = buildAgentPromptCommand(
                    agentCommand: agentCmd,
                    prompt: prompt,
                    path: path,
                    filePrefix: "clearway-plan"
                )
                planLogger.info("plan agent=\(agentCmd, privacy: .public) promptFile=\(launch.promptFile, privacy: .public)")
                planLogger.debug("plan command: \(launch.command, privacy: .public)")
                return launch.command
            }
        }

        // The same seam the launcher asks "is a main terminal command configured, or do we drop
        // straight to a login shell?" — trimmed, and nil when the setting is blank.
        guard let command = terminalManager.mainCommandProvider() else { return nil }
        return { [terminalManager] path in
            terminalManager.buildBareCommand(agentCommand: command, path: path)
        }
    }

    private func focusTaskTerminal(_ taskId: UUID) {
        terminalManager.existingTaskSurface(for: taskId)?.takeFocus(after: 0.25)
    }
}
