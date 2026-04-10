import Foundation
import GhosttyKit

/// Coordinates the task launch workflow: creating worktrees, running hooks,
/// and launching Claude Code. Extracted from ContentView to keep the view
/// focused on layout and navigation.
@MainActor
class WorkTaskCoordinator: ObservableObject {
    var pendingLaunch: (id: UUID, branch: String, isAutoStart: Bool)?

    // MARK: - Auto-Processing

    /// Whether the user has toggled auto-processing on.
    @Published var isAutoProcessing: Bool = false {
        didSet {
            if isAutoProcessing {
                startAutoProcessingTimer()
            } else {
                stopAutoProcessingTimer()
            }
        }
    }

    /// Whether auto-processing is available (polling interval is not disabled).
    var isAutoProcessingEnabled: Bool {
        pollingInterval != .disabled
    }

    /// Incremented each time an auto-start result is published, so SwiftUI
    /// detects changes even if consecutive results have similar structure.
    @Published var autoStartGeneration: Int = 0

    /// Incremented on each polling tick so the UI can animate a progress ring.
    @Published var tickGeneration: Int = 0

    /// Result from auto-dispatching a task — ContentView observes `autoStartGeneration`
    /// and consumes this value to handle worktree creation, hooks, and trust dialogs.
    var pendingAutoStart: StartResult?

    /// Maximum concurrent agents, read from project settings.
    var maxConcurrent: Int {
        ProjectSettings.maxConcurrentAgents(for: workTaskManager.projectPath)
    }

    /// Polling interval for auto-processing, read from project settings.
    var pollingInterval: ProjectSettings.PollingInterval {
        ProjectSettings.pollingInterval(for: workTaskManager.projectPath)
    }

    /// Number of tasks currently in progress with a live worktree on disk.
    var inProgressCount: Int {
        let liveBranches = Set(worktreeManager.worktrees.compactMap(\.branch))
        return workTaskManager.tasks.filter { task in
            task.status == .inProgress && task.worktree.map { liveBranches.contains($0) } == true
        }.count
    }

    private var autoProcessingTimer: DispatchSourceTimer?

    // MARK: - Agent Lifecycle

    /// Surfaces running agent commands, keyed by worktree ID.
    /// TerminalManager checks this to skip auto-restart for agent surfaces.
    /// Published so the UI can display the running agent count.
    @Published private(set) var agentSurfaces: [String: Ghostty.SurfaceView] = [:]

    /// Session observers for running agents, keyed by worktree ID.
    private var sessionObservers: [String: AgentSessionObserver] = [:]

    // MARK: - Dependencies

    private let workTaskManager: WorkTaskManager
    private let terminalManager: TerminalManager
    private let worktreeManager: WorktreeManager

    /// Resolves the current ghostty app reference. Set at init or via `setAppProvider`.
    private var appProvider: (() -> ghostty_app_t?)?

    /// Live-reloaded workflow config — watched for changes on disk.
    @Published private(set) var workflowConfig: WorkflowConfig?

    /// Live-reloaded planning config — watched for changes on disk.
    @Published private(set) var planningConfig: WorkflowConfig?

    private var isWatching = false
    private var watcherSource: DispatchSourceFileSystemObject?
    private var directoryWatcherSource: DispatchSourceFileSystemObject?
    private var planningWatcherSource: DispatchSourceFileSystemObject?
    private var planningDirectoryWatcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var pendingPlanningReload: DispatchWorkItem?
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
        autoProcessingTimer?.cancel()
        pendingReload?.cancel()
        pendingPlanningReload?.cancel()
        watcherSource?.cancel()
        directoryWatcherSource?.cancel()
        planningWatcherSource?.cancel()
        planningDirectoryWatcherSource?.cancel()
        if let observer = exitObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Provide a closure that resolves the current ghostty app reference for auto-processing.
    func setAppProvider(_ provider: @escaping () -> ghostty_app_t?) {
        self.appProvider = provider
    }

    // MARK: - WORKFLOW.md Watching

    /// Start watching WORKFLOW.md and PLANNING.md for the current project.
    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        reloadWorkflowConfig()
        watchWorkflowFile()
        reloadPlanningConfig()
        watchPlanningFile()
    }

    private var workflowFilePath: String {
        (workTaskManager.projectPath as NSString).appendingPathComponent("WORKFLOW.md")
    }

    private func watchWorkflowFile() {
        watcherSource?.cancel()
        watcherSource = nil

        let filePath = workflowFilePath
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist — watch the parent directory for its creation.
            watchDirectoryForFileCreation()
            return
        }

        // File exists — cancel any directory watcher and watch the file directly.
        directoryWatcherSource?.cancel()
        directoryWatcherSource = nil

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

    /// Watches the project directory for entry changes (file creation/deletion).
    /// When WORKFLOW.md appears, switches to per-file watching.
    private func watchDirectoryForFileCreation() {
        directoryWatcherSource?.cancel()
        directoryWatcherSource = nil

        let dirPath = workTaskManager.projectPath
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            // Only schedule a reload if WORKFLOW.md actually appeared.
            // The fileExists check also filters the spurious initial .write
            // event that fires on resume — the file won't exist yet.
            guard let self, FileManager.default.fileExists(atPath: self.workflowFilePath) else { return }
            self.scheduleReload(rewatch: true)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directoryWatcherSource = source
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

    // MARK: - PLANNING.md Watching

    private var planningFilePath: String {
        (workTaskManager.projectPath as NSString).appendingPathComponent("PLANNING.md")
    }

    private func watchPlanningFile() {
        planningWatcherSource?.cancel()
        planningWatcherSource = nil

        let filePath = planningFilePath
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            watchDirectoryForPlanningFileCreation()
            return
        }

        planningDirectoryWatcherSource?.cancel()
        planningDirectoryWatcherSource = nil

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let data = source.data
            let needsRewatch = data.contains(.delete) || data.contains(.rename)
            self?.schedulePlanningReload(rewatch: needsRewatch)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        planningWatcherSource = source
    }

    private func watchDirectoryForPlanningFileCreation() {
        planningDirectoryWatcherSource?.cancel()
        planningDirectoryWatcherSource = nil

        let dirPath = workTaskManager.projectPath
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self, FileManager.default.fileExists(atPath: self.planningFilePath) else { return }
            self.schedulePlanningReload(rewatch: true)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        planningDirectoryWatcherSource = source
    }

    private nonisolated func schedulePlanningReload(rewatch: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingPlanningReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.reloadPlanningConfig()
                if rewatch {
                    self.watchPlanningFile()
                }
            }
            self.pendingPlanningReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func reloadPlanningConfig() {
        guard FileManager.default.fileExists(atPath: planningFilePath) else {
            planningConfig = nil
            return
        }
        if let config = WorkflowConfig.load(projectPath: workTaskManager.projectPath, fileName: "PLANNING.md") {
            planningConfig = config
        }
    }

    // MARK: - Auto-Processing Timer

    /// Restart the timer with the current polling interval (e.g. after settings change).
    func restartAutoProcessingTimer() {
        guard isAutoProcessing else { return }
        startAutoProcessingTimer()
    }

    private func startAutoProcessingTimer() {
        stopAutoProcessingTimer()
        let interval = pollingInterval
        guard interval != .disabled else {
            isAutoProcessing = false
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(interval.rawValue), repeating: .seconds(interval.rawValue))
        timer.setEventHandler { [weak self] in
            self?.tickGeneration += 1
            self?.autoProcessTick()
        }
        timer.resume()
        autoProcessingTimer = timer
        // Process immediately on start, but don't bump tickGeneration
        // (the view animation is already started by onChange(of: isAutoProcessing))
        autoProcessTick()
    }

    private func stopAutoProcessingTimer() {
        autoProcessingTimer?.cancel()
        autoProcessingTimer = nil
    }

    private func autoProcessTick() {
        guard isAutoProcessing, let app = appProvider?() else { return }

        // Don't dispatch if a worktree creation or UI action is already in flight
        guard pendingLaunch == nil, pendingAutoStart == nil else { return }

        // Check available slots — in-progress tasks occupy worktree slots
        guard inProgressCount < maxConcurrent else { return }

        // Find the oldest readyToStart task
        guard let task = workTaskManager.tasks
            .filter({ $0.status == .readyToStart })
            .sorted(by: { $0.createdAt < $1.createdAt })
            .first else { return }

        let result = startTask(task, app: app, isAutoStart: true)
        switch result {
        case .ignored, .reuse:
            break
        case .createWorktree, .beforeRunHook, .needsTrust:
            pendingAutoStart = result
            autoStartGeneration += 1
        }
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

    func startTask(_ task: WorkTask, app: ghostty_app_t, isAutoStart: Bool = false) -> StartResult {
        guard task.status == .new || task.status == .readyToStart || task.status == .canceled else { return .ignored }

        // Check trust before executing any hooks
        if let config = workflowConfig, !config.isTrusted(forProject: workTaskManager.projectPath) {
            return .needsTrust(config)
        }

        var updated = task
        if task.status == .canceled {
            updated.attempt = (task.attempt ?? 0) + 1
        }
        updated.errorMessage = nil

        if let branch = task.worktree,
           let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) {
            updated.status = .inProgress
            workTaskManager.updateTask(updated)

            if let hookCmd = workflowConfig?.hooksBeforeRun {
                let taskPath = workTaskManager.filePath(for: updated)
                let rendered = workflowConfig?.renderHookCommand(hookCmd, task: updated, taskPath: taskPath) ?? hookCmd
                return .beforeRunHook(hookCommand: rendered, worktree: wt) { [weak self] in
                    self?.launchClaudeCode(for: updated, in: wt, app: app)
                }
            }

            launchClaudeCode(for: updated, in: wt, app: app)
            return .reuse(wt)
        } else {
            let existingBranches = Set(worktreeManager.worktrees.compactMap(\.branch))
            let branch = task.worktree ?? workTaskManager.deriveBranchName(from: task.title, existingBranches: existingBranches)
            updated.worktree = branch
            updated.status = .inProgress
            workTaskManager.updateTask(updated)
            pendingLaunch = (id: updated.id, branch: branch, isAutoStart: isAutoStart)
            return .createWorktree(branch)
        }
    }

    /// Continues a completed task — re-launches agent with a continuation prompt.
    func continueTask(_ task: WorkTask, app: ghostty_app_t) -> StartResult {
        guard task.status == .done || task.status == .readyForReview,
              let branch = task.worktree,
              let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) else { return .ignored }

        if let config = workflowConfig, !config.isTrusted(forProject: workTaskManager.projectPath) {
            return .needsTrust(config)
        }

        var updated = task
        updated.attempt = (task.attempt ?? 0) + 1
        updated.status = .inProgress
        workTaskManager.updateTask(updated)

        if let hookCmd = workflowConfig?.hooksBeforeRun {
            let taskPath = workTaskManager.filePath(for: updated)
            let rendered = workflowConfig?.renderHookCommand(hookCmd, task: updated, taskPath: taskPath) ?? hookCmd
            return .beforeRunHook(hookCommand: rendered, worktree: wt) { [weak self] in
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

    /// If a task launch was pending for this branch, returns a closure that launches Claude Code
    /// and whether this was an auto-start (to skip navigation).
    func completePendingLaunch(branch: String, worktree: Worktree, app: ghostty_app_t) -> (launch: () -> Void, isAutoStart: Bool)? {
        guard let pending = pendingLaunch, pending.branch == branch,
              let task = workTaskManager.tasks.first(where: { $0.id == pending.id }) else { return nil }
        let isAutoStart = pending.isAutoStart
        pendingLaunch = nil

        return (launch: { [weak self] in
            self?.launchClaudeCode(for: task, in: worktree, app: app)
        }, isAutoStart: isAutoStart)
    }

    func worktreeForTask(_ task: WorkTask) -> Worktree? {
        guard let branch = task.worktree else { return nil }
        return worktreeManager.worktrees.first(where: { $0.branch == branch })
    }

    /// Called when a worktree is removed — marks the task as done and clears the worktree link.
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

    /// Returns the WORKFLOW.md after_create hook command if configured.
    func workflowAfterCreateHook() -> String? {
        workflowConfig?.hooksAfterCreate
    }

    // MARK: - Agent Launch

    private func launchClaudeCode(for task: WorkTask, in worktree: Worktree, app: ghostty_app_t, isContinuation: Bool = false) {
        let prompt: String
        if isContinuation {
            prompt = "Continue working on this task. Review what was done and pick up where you left off."
        } else {
            let taskPath = workTaskManager.filePath(for: task)
            prompt = workflowConfig?.renderPrompt(task: task, taskPath: taskPath, attempt: task.attempt) ?? task.body
        }

        let agentCmd = workflowConfig?.agentCommand ?? "claude"

        // Write prompt to temp file to handle long prompts safely
        let tempDir = NSTemporaryDirectory()
        let promptFile = (tempDir as NSString).appendingPathComponent("clearway-prompt-\(task.id.uuidString).md")
        FileManager.default.createFile(atPath: promptFile, contents: prompt.data(using: .utf8), attributes: [.posixPermissions: 0o600])

        // Pipe prompt file to agent command via stdin (same pattern as v1).
        // Both the agent command and file path are positional args to avoid shell injection.
        // $1 is intentionally unquoted so multi-word commands (e.g. "claude --flag") are word-split.
        // $3 injects the resolved login-shell PATH so tools like `claude` are found.
        let command = "/bin/sh -c " + shellEscape("export PATH=\"$3\"; set -f; cat \"$2\" | $1") + " -- " + shellEscape(agentCmd) + " " + shellEscape(promptFile) + " " + shellEscape(ShellEnvironment.path)

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
        // the observer's onActivity will flip the task back to .inProgress.
        agentSurfaces.removeValue(forKey: worktreeId)
        let observer = sessionObservers[worktreeId]

        guard let worktree = worktreeManager.worktrees.first(where: { $0.id == worktreeId }),
              let branch = worktree.branch,
              var task = workTaskManager.task(forWorktree: branch) else { return }

        // Clean up temp prompt file
        let promptFile = NSTemporaryDirectory() + "clearway-prompt-\(task.id.uuidString).md"
        try? FileManager.default.removeItem(atPath: promptFile)

        // Don't auto-change status — user may have exited to start a new session.
        // Just accumulate tokens and record error on failure.
        if exitCode == 0 {
            task.errorMessage = nil
        } else {
            task.errorMessage = "Agent exited with code \(exitCode)"
        }

        accumulateTokens(from: observer, into: &task)
        workTaskManager.updateTask(task)
    }

    private func handleAgentStalled(worktreeId: String) {
        guard let worktree = worktreeManager.worktrees.first(where: { $0.id == worktreeId }),
              let branch = worktree.branch,
              var task = workTaskManager.task(forWorktree: branch),
              task.status == .inProgress else { return }

        // Don't clean up — keep the agent surface and observer alive.
        // The process may still be running (e.g., waiting for user permission).
        // If the process exits, handleChildExited will fire normally.
        task.errorMessage = "Agent stalled — no activity detected"
        workTaskManager.updateTask(task)
    }

    /// Called when any Claude session JSONL activity is detected in a task's worktree.
    /// If the task is done, flips it back to inProgress — the user or another
    /// Claude session is actively working on it.
    private func handleSessionActivity(worktreeId: String) {
        guard let worktree = worktreeManager.worktrees.first(where: { $0.id == worktreeId }),
              let branch = worktree.branch,
              var task = workTaskManager.task(forWorktree: branch),
              task.status == .done else { return }

        Ghostty.logger.info("Session activity detected for worktree \(worktreeId, privacy: .public), resuming task")
        task.status = .inProgress
        task.errorMessage = nil
        workTaskManager.updateTask(task)
    }

    private func accumulateTokens(from observer: AgentSessionObserver?, into task: inout WorkTask) {
        guard let observer else { return }
        if observer.inputTokens > 0 { task.inputTokens = (task.inputTokens ?? 0) + observer.inputTokens }
        if observer.outputTokens > 0 { task.outputTokens = (task.outputTokens ?? 0) + observer.outputTokens }
    }
}
