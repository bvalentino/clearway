import Foundation
import GhosttyKit

/// Coordinates the task launch workflow: creating worktrees, running hooks,
/// and launching Claude Code. Extracted from ContentView to keep the view
/// focused on layout and navigation.
@MainActor
class WorkTaskCoordinator: ObservableObject {
    var pendingLaunch: (id: UUID, branch: String)?

    /// Published so ContentView can present a HookSheet for the after_run hook.
    /// Uses a unique ID to ensure consecutive identical hooks are not deduplicated by SwiftUI.
    @Published var pendingAfterRunHook: PendingHook?

    struct PendingHook: Identifiable, Equatable {
        let id = UUID()
        let command: String
        let worktreePath: String

        static func == (lhs: PendingHook, rhs: PendingHook) -> Bool { lhs.id == rhs.id }
    }

    // MARK: - Agent Lifecycle

    /// Surfaces running agent commands, keyed by worktree ID.
    /// TerminalManager checks this to skip auto-restart for agent surfaces.
    private(set) var agentSurfaces: [String: Ghostty.SurfaceView] = [:]

    /// Session observers for running agents, keyed by worktree ID.
    private var sessionObservers: [String: AgentSessionObserver] = [:]

    // MARK: - Dependencies

    private let workTaskManager: WorkTaskManager
    private let terminalManager: TerminalManager
    private let worktreeManager: WorktreeManager

    /// Live-reloaded workflow config — watched for changes on disk.
    @Published private(set) var workflowConfig: WorkflowConfig?

    private var isWatching = false
    private var watcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var exitObserver: Any?

    init(workTaskManager: WorkTaskManager, terminalManager: TerminalManager, worktreeManager: WorktreeManager) {
        self.workTaskManager = workTaskManager
        self.terminalManager = terminalManager
        self.worktreeManager = worktreeManager

        exitObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyChildExited,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleChildExited(notification)
            }
        }
    }

    nonisolated deinit {
        pendingReload?.cancel()
        watcherSource?.cancel()
        if let observer = exitObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - WORKFLOW.md Watching

    /// Start watching WORKFLOW.md for the current project.
    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        reloadWorkflowConfig()
        watchWorkflowFile()
    }

    private var workflowFilePath: String {
        (workTaskManager.projectPath as NSString).appendingPathComponent("WORKFLOW.md")
    }

    private func watchWorkflowFile() {
        watcherSource?.cancel()
        watcherSource = nil

        let filePath = workflowFilePath
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let data = source.data
            let needsRewatch = data.contains(.delete) || data.contains(.rename)
            self?.scheduleReload(rewatch: needsRewatch)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcherSource = source
    }

    private nonisolated func scheduleReload(rewatch: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.reloadWorkflowConfig()
                if rewatch {
                    self.watchWorkflowFile()
                }
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func reloadWorkflowConfig() {
        guard FileManager.default.fileExists(atPath: workflowFilePath) else {
            workflowConfig = nil
            return
        }
        if let config = WorkflowConfig.load(projectPath: workTaskManager.projectPath) {
            workflowConfig = config
        }
        // File exists but parse failed — keep last-known-good config
    }

    // MARK: - Actions

    enum StartResult {
        case ignored
        case reuse(Worktree)
        case createWorktree(String)
        /// A before_run hook needs to run first.
        case beforeRunHook(hookCommand: String, worktree: Worktree, onSuccess: () -> Void)
        /// WORKFLOW.md hooks need user trust approval first. Call `approveTrust()` then retry.
        case needsTrust(WorkflowConfig)
    }

    func startTask(_ task: WorkTask, app: ghostty_app_t) -> StartResult {
        guard task.status == .open || task.status == .stopped else { return .ignored }

        // Check trust before executing any hooks
        if let config = workflowConfig, !config.isTrusted(forProject: workTaskManager.projectPath) {
            return .needsTrust(config)
        }

        var updated = task
        if task.status == .stopped {
            updated.attempt = (task.attempt ?? 0) + 1
        }
        updated.errorMessage = nil

        if let branch = task.worktree,
           let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) {
            updated.status = .started
            workTaskManager.updateTask(updated)

            if let hookCmd = workflowConfig?.hooksBeforeRun {
                return .beforeRunHook(hookCommand: hookCmd, worktree: wt) { [weak self] in
                    self?.launchClaudeCode(for: updated, in: wt, app: app)
                }
            }

            launchClaudeCode(for: updated, in: wt, app: app)
            return .reuse(wt)
        } else {
            let existingBranches = Set(worktreeManager.worktrees.compactMap(\.branch))
            let branch = task.worktree ?? workTaskManager.deriveBranchName(from: task.title, existingBranches: existingBranches)
            updated.worktree = branch
            updated.status = .started
            workTaskManager.updateTask(updated)
            pendingLaunch = (id: updated.id, branch: branch)
            return .createWorktree(branch)
        }
    }

    /// Continues a completed task — re-launches agent with a continuation prompt.
    func continueTask(_ task: WorkTask, app: ghostty_app_t) -> StartResult {
        guard task.status == .done, let branch = task.worktree,
              let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) else { return .ignored }

        if let config = workflowConfig, !config.isTrusted(forProject: workTaskManager.projectPath) {
            return .needsTrust(config)
        }

        var updated = task
        updated.attempt = (task.attempt ?? 0) + 1
        updated.status = .started
        workTaskManager.updateTask(updated)

        if let hookCmd = workflowConfig?.hooksBeforeRun {
            return .beforeRunHook(hookCommand: hookCmd, worktree: wt) { [weak self] in
                self?.launchClaudeCode(for: updated, in: wt, app: app, isContinuation: true)
            }
        }

        launchClaudeCode(for: updated, in: wt, app: app, isContinuation: true)
        return .reuse(wt)
    }

    /// Mark the current WORKFLOW.md config as trusted for this project.
    func approveTrust() {
        workflowConfig?.markTrusted(forProject: workTaskManager.projectPath)
    }

    /// If a task launch was pending for this branch, returns a closure that launches Claude Code.
    func completePendingLaunch(branch: String, worktree: Worktree, app: ghostty_app_t) -> (() -> Void)? {
        guard let pending = pendingLaunch, pending.branch == branch,
              let task = workTaskManager.tasks.first(where: { $0.id == pending.id }) else { return nil }
        pendingLaunch = nil

        return { [weak self] in
            self?.launchClaudeCode(for: task, in: worktree, app: app)
        }
    }

    func worktreeForTask(_ task: WorkTask) -> Worktree? {
        guard let branch = task.worktree else { return nil }
        return worktreeManager.worktrees.first(where: { $0.branch == branch })
    }

    /// Called when a worktree is removed — resets matching task to open.
    /// This is the only place that fully tears down both surface and observer.
    func handleWorktreeRemoved(branch: String) {
        guard let task = workTaskManager.task(forWorktree: branch) else { return }

        if let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }) {
            agentSurfaces.removeValue(forKey: worktree.id)
            sessionObservers.removeValue(forKey: worktree.id)?.stopObserving()
        }

        var updated = task
        updated.worktree = nil
        updated.status = .done
        workTaskManager.updateTask(updated)
    }

    /// Whether the given surface is an agent surface (should not be auto-restarted).
    func isAgentSurface(_ surface: Ghostty.SurfaceView) -> Bool {
        agentSurfaces.values.contains(where: { $0 === surface })
    }

    /// Returns the WORKFLOW.md after_create hook command if it exists,
    /// to take precedence over ProjectSettings hooks.
    func workflowAfterCreateHook() -> String? {
        workflowConfig?.hooksAfterCreate
    }

    // MARK: - Agent Launch

    private func launchClaudeCode(for task: WorkTask, in worktree: Worktree, app: ghostty_app_t, isContinuation: Bool = false) {
        let prompt: String
        if isContinuation {
            prompt = "Continue working on this task. Review what was done and pick up where you left off."
        } else {
            prompt = workflowConfig?.renderPrompt(task: task, attempt: task.attempt) ?? task.body
        }

        let agentCmd = workflowConfig?.agentCommand ?? "claude"

        // Write prompt to temp file to handle long prompts safely
        let tempDir = NSTemporaryDirectory()
        let promptFile = (tempDir as NSString).appendingPathComponent("wtpad-prompt-\(task.id.uuidString).md")
        FileManager.default.createFile(atPath: promptFile, contents: prompt.data(using: .utf8), attributes: [.posixPermissions: 0o600])

        // Pipe prompt file to agent command via stdin (same pattern as v1).
        // Both the agent command and file path are positional args to avoid shell injection.
        let command = "/bin/sh -c " + shellEscape("cat \"$2\" | \"$1\"") + " -- " + shellEscape(agentCmd) + " " + shellEscape(promptFile)

        let surface = terminalManager.replaceMainSurface(for: worktree, app: app, command: command)
        agentSurfaces[worktree.id] = surface
        Ghostty.logger.info("Agent launched for worktree \(worktree.id, privacy: .public), surface: \(ObjectIdentifier(surface).debugDescription, privacy: .public)")

        // Start session observation for token tracking (always) + stall detection (opt-in).
        // Stall detection is only enabled when agent.timeout_ms is explicitly set in WORKFLOW.md,
        // because Claude Code legitimately idles during permission prompts and user interaction.
        if let worktreePath = worktree.path {
            let observer = AgentSessionObserver()
            // Always watch for activity — used to detect manually-started Claude sessions
            observer.onActivity = { [weak self] in
                self?.handleSessionActivity(worktreeId: worktree.id)
            }
            if let timeoutMs = workflowConfig?.agentTimeoutMs {
                observer.onStall = { [weak self] in
                    self?.handleAgentStalled(worktreeId: worktree.id)
                }
                observer.startObserving(worktreePath: worktreePath, timeoutMs: timeoutMs)
            } else {
                observer.startObserving(worktreePath: worktreePath)
            }
            sessionObservers[worktree.id] = observer
        }
    }

    // MARK: - Agent Lifecycle

    private func handleChildExited(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let exitCode = notification.userInfo?[GhosttyNotificationKey.exitCode] as? UInt32 else { return }

        let surfaceId = ObjectIdentifier(surface).debugDescription
        let isAgentSurface = agentSurfaces.values.contains(where: { $0 === surface })
        Ghostty.logger.info("ghosttyChildExited: surface=\(surfaceId, privacy: .public) exitCode=\(exitCode) isAgent=\(isAgentSurface)")

        guard let (worktreeId, _) = agentSurfaces.first(where: { $0.value === surface }) else { return }
        Ghostty.logger.info("Agent exited for worktree \(worktreeId, privacy: .public) with code \(exitCode)")

        // Remove the surface tracking but KEEP the session observer alive.
        // If the user manually starts a new Claude session in this worktree,
        // the observer's onActivity will flip the task back to .started.
        agentSurfaces.removeValue(forKey: worktreeId)
        let observer = sessionObservers[worktreeId]

        guard let worktree = worktreeManager.worktrees.first(where: { $0.id == worktreeId }),
              let branch = worktree.branch,
              var task = workTaskManager.task(forWorktree: branch) else { return }

        // Clean up temp prompt file
        let promptFile = NSTemporaryDirectory() + "wtpad-prompt-\(task.id.uuidString).md"
        try? FileManager.default.removeItem(atPath: promptFile)

        if exitCode == 0 {
            task.status = .done
            task.errorMessage = nil
        } else {
            task.status = .stopped
            task.errorMessage = "Agent exited with code \(exitCode)"
        }

        accumulateTokens(from: observer, into: &task)
        workTaskManager.updateTask(task)

        // Publish after_run hook for ContentView to present visibly
        if let hookCmd = workflowConfig?.hooksAfterRun, let path = worktree.path {
            pendingAfterRunHook = PendingHook(command: hookCmd, worktreePath: path)
        }
    }

    private func handleAgentStalled(worktreeId: String) {
        guard let worktree = worktreeManager.worktrees.first(where: { $0.id == worktreeId }),
              let branch = worktree.branch,
              var task = workTaskManager.task(forWorktree: branch),
              task.status == .started else { return }

        // Don't clean up — keep the agent surface and observer alive.
        // The process may still be running (e.g., waiting for user permission).
        // If new JSONL activity is detected, handleAgentResumed will flip back to .started.
        // If the process exits, handleChildExited will fire normally.
        task.status = .stopped
        task.errorMessage = "Agent stalled — no activity detected"
        workTaskManager.updateTask(task)
    }

    /// Called when any Claude session JSONL activity is detected in a task's worktree.
    /// If the task is done or stopped, flips it back to started — the user or another
    /// Claude session is actively working on it.
    private func handleSessionActivity(worktreeId: String) {
        guard let worktree = worktreeManager.worktrees.first(where: { $0.id == worktreeId }),
              let branch = worktree.branch,
              var task = workTaskManager.task(forWorktree: branch),
              task.status == .done || task.status == .stopped else { return }

        Ghostty.logger.info("Session activity detected for worktree \(worktreeId, privacy: .public), resuming task")
        task.status = .started
        task.errorMessage = nil
        workTaskManager.updateTask(task)
    }

    private func accumulateTokens(from observer: AgentSessionObserver?, into task: inout WorkTask) {
        guard let observer else { return }
        if observer.inputTokens > 0 { task.inputTokens = (task.inputTokens ?? 0) + observer.inputTokens }
        if observer.outputTokens > 0 { task.outputTokens = (task.outputTokens ?? 0) + observer.outputTokens }
    }
}
