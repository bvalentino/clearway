import Combine
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
    /// and consumes this value to handle worktree creation and hooks.
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

    /// Identities of every agent surface ever launched for a worktree (live or superseded).
    /// Keyed by worktree ID. Cleared when a tab is explicitly closed via `handleMainTabClosed`.
    private var agentSurfaceIdentities: [String: Set<ObjectIdentifier>] = [:]

    /// Session observers for running agents, keyed by agent surface identifier.
    /// Per-surface keying ensures overlapping launches (a superseded agent + the live one)
    /// have distinct observers — so `handleChildExited` can attribute tokens to the exact
    /// surface that exited instead of reading whichever observer happened to land in the
    /// worktree slot last.
    private var sessionObservers: [ObjectIdentifier: AgentSessionObserver] = [:]

    /// Per-launch prompt file paths, keyed by surface identifier. Unique per launch so
    /// overlapping runs for the same task don't share or clobber each other's temp file.
    private var launchPromptFiles: [ObjectIdentifier: String] = [:]

    // MARK: - Dependencies
    //
    // Watcher state (isWatching, watcherSource, pendingReload, planningConfig, etc.) and
    // workTaskManager are internal, not private, because the PLANNING.md and
    // workflow.json file-watching methods live in `WorkTaskCoordinator+ConfigWatching.swift`
    // and `WorkTaskCoordinator+WorkflowWatching.swift` — cross-file extensions cannot
    // reach private members. Only those extensions should mutate them.
    //
    // `terminalManager` is internal (not private) because the auto-fire dispatch
    // logic lives in `WorkTaskCoordinator+AutoFire.swift` — that extension needs
    // to spawn tabs and route paste calls.

    let workTaskManager: WorkTaskManager
    let terminalManager: TerminalManager
    private let worktreeManager: WorktreeManager

    /// Branches whose worktree column is currently mounted in any window. The
    /// auto-fire hook only dispatches actions for tasks whose branch is visible
    /// — a transition that happens off-screen (e.g. user disk-edits a task file
    /// while looking at a different worktree) must not steal focus by spawning
    /// agent tabs. Wired from `ContentView.onAppear`/`onDisappear`. This is an
    /// instance property (not static) because `WorkTaskCoordinator` is one per
    /// project window, and a task only auto-fires for its own project — there's
    /// no need to cross window boundaries.
    var visibleBranches: Set<String> = []

    /// Mark `branch` as visible (or not) in the project's UI.
    func setBranchVisible(_ branch: String, _ visible: Bool) {
        if visible {
            visibleBranches.insert(branch)
        } else {
            visibleBranches.remove(branch)
        }
    }

    /// Resolves the current ghostty app reference. Set at init or via `setAppProvider`.
    private var appProvider: (() -> ghostty_app_t?)?

    /// Live-reloaded planning config — watched for changes on disk.
    @Published private(set) var planningConfig: PlanningConfig?

    /// Live-reloaded workflow automation rules from `.clearway/workflow.json`.
    /// Always non-nil — `WorkflowAutomation.load` yields an empty automation
    /// when the file is absent or invalid, so consumers never need to
    /// differentiate "absent" from "empty". Mutate via
    /// `setWorkflowAutomation` so the `private(set)` contract reaches the
    /// cross-file extension without being widened to internal.
    @Published private(set) var workflowAutomation: WorkflowAutomation = WorkflowAutomation()

    func setPlanningConfig(_ config: PlanningConfig?) { planningConfig = config }
    func setWorkflowAutomation(_ automation: WorkflowAutomation) { workflowAutomation = automation }

    var isWatching = false
    var planningWatcherSource: DispatchSourceFileSystemObject?
    var planningDirectoryWatcherSource: DispatchSourceFileSystemObject?
    var workflowJSONWatcherSource: DispatchSourceFileSystemObject?
    var workflowJSONDirectoryWatcherSource: DispatchSourceFileSystemObject?
    var workflowJSONProjectDirectoryWatcherSource: DispatchSourceFileSystemObject?
    var pendingPlanningReload: DispatchWorkItem?
    var pendingWorkflowJSONReload: DispatchWorkItem?
    private var exitObserver: Any?

    // MARK: - Status Transitions

    /// Hook invoked whenever an existing task's status changes. Parameters
    /// are the up-to-date task (so `task.auto` reflects the new value), the
    /// previous status, and the new status. Phase 2 will set this from
    /// `ContentView` to drive workflow.json auto-fire dispatch.
    var onStatusTransition: ((WorkTask, WorkTask.Status, WorkTask.Status) -> Void)?

    /// Snapshot of every known task's last-observed status, keyed by id.
    /// Used by the `$tasks` subscription to diff transitions. Seeded on the
    /// first emission (so existing tasks don't fire spurious callbacks at
    /// launch) and kept in sync as tasks are added, changed, or removed.
    private var lastTaskStatusSnapshot: [UUID: WorkTask.Status] = [:]
    private var didSeedStatusSnapshot = false
    private var statusObserverCancellable: AnyCancellable?

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

        // Observe task status transitions so Phase 2 can hook auto-fire dispatch
        // here. The first emission seeds the baseline snapshot — existing tasks
        // present at launch must not retroactively trigger callbacks.
        statusObserverCancellable = workTaskManager.$tasks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                self?.handleTasksChanged(tasks)
            }

        // Wire workflow.json auto-fire dispatch to status transitions. The
        // hook is set after the subscription is installed so it can never
        // observe the seeding emission.
        self.onStatusTransition = { [weak self] task, _, newStatus in
            self?.handleAutoFire(task: task, newStatus: newStatus)
        }
    }

    nonisolated deinit {
        autoProcessingTimer?.cancel()
        pendingPlanningReload?.cancel()
        pendingWorkflowJSONReload?.cancel()
        planningWatcherSource?.cancel()
        planningDirectoryWatcherSource?.cancel()
        workflowJSONWatcherSource?.cancel()
        workflowJSONDirectoryWatcherSource?.cancel()
        workflowJSONProjectDirectoryWatcherSource?.cancel()
        statusObserverCancellable?.cancel()
        if let observer = exitObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Diff every `$tasks` emission against the last-observed snapshot and
    /// invoke `onStatusTransition` for any task whose status changed. New
    /// tasks (no prior snapshot entry) and removed tasks do NOT fire the
    /// callback — only true status transitions on previously-known tasks do.
    private func handleTasksChanged(_ tasks: [WorkTask]) {
        guard didSeedStatusSnapshot else {
            // Seed the baseline from the first emission so existing tasks
            // don't fire spurious callbacks at app launch / project open.
            for task in tasks {
                lastTaskStatusSnapshot[task.id] = task.status
            }
            didSeedStatusSnapshot = true
            return
        }

        var nextSnapshot: [UUID: WorkTask.Status] = [:]
        nextSnapshot.reserveCapacity(tasks.count)
        for task in tasks {
            nextSnapshot[task.id] = task.status
            if let previous = lastTaskStatusSnapshot[task.id], previous != task.status {
                onStatusTransition?(task, previous, task.status)
            }
            // New tasks (no prior entry) intentionally do not fire — there's
            // no "old" status to transition from. They're just snapshotted so
            // their next change dispatches correctly.
        }
        lastTaskStatusSnapshot = nextSnapshot
    }

    /// Provide a closure that resolves the current ghostty app reference for auto-processing.
    func setAppProvider(_ provider: @escaping () -> ghostty_app_t?) {
        self.appProvider = provider
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

        // Polling auto-start exists to feed the workflow.json automation
        // pipeline. With no rules defined, dropping a backlog task into the
        // in-progress column produces no visible action — skip the tick
        // entirely so we don't surprise the user with an unwanted launch.
        guard workflowAutomation.hasAnyRule else { return }

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
        case .createWorktree, .beforeRunHook:
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
    }

    enum LaunchResult {
        case launched
        case ignored
    }

    func startTask(_ task: WorkTask, app: ghostty_app_t, isAutoStart: Bool = false) -> StartResult {
        guard task.status == .new || task.status == .readyToStart || task.status == .canceled else { return .ignored }

        var updated = task
        if task.status == .canceled {
            updated.attempt = (task.attempt ?? 0) + 1
        }
        updated.errorMessage = nil

        // Branch-keyed lookup is intentional: it resolves the correct worktree even when HEAD
        // is temporarily detached (e.g. mid-rebase), because `branch` is stored separately.
        if let branch = task.worktree,
           let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) {
            updated.status = .inProgress
            // Opt the task into auto-fire when this project has any workflow rules.
            // No rules → leave `auto` as-is so manual tasks stay clean.
            updated.auto = workflowAutomation.hasAnyRule
            workTaskManager.updateTask(updated)

            launchClaudeCode(for: updated, in: wt, app: app)
            return .reuse(wt)
        } else {
            let existingBranches = Set(worktreeManager.worktrees.compactMap(\.branch))
            let branch = task.worktree ?? workTaskManager.deriveBranchName(from: task.title, existingBranches: existingBranches)
            updated.worktree = branch
            updated.status = .inProgress
            // Opt the task into auto-fire when this project has any workflow rules.
            // No rules → leave `auto` as-is so manual tasks stay clean.
            updated.auto = workflowAutomation.hasAnyRule
            workTaskManager.updateTask(updated)
            pendingLaunch = (id: updated.id, branch: branch, isAutoStart: isAutoStart)
            return .createWorktree(branch)
        }
    }

    /// Continues a completed task — re-launches agent with a continuation prompt.
    func continueTask(_ task: WorkTask, app: ghostty_app_t) -> StartResult {
        guard task.status == .done || task.status == .readyForReview || task.status == .qa,
              let branch = task.worktree,
              let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) else { return .ignored }

        var updated = task
        updated.attempt = (task.attempt ?? 0) + 1
        updated.status = .inProgress
        // Continuing a task is functionally another "start" — opt it in when
        // this project has any workflow rules. No rules → leave `auto` as-is.
        updated.auto = workflowAutomation.hasAnyRule
        workTaskManager.updateTask(updated)

        launchClaudeCode(for: updated, in: wt, app: app, isContinuation: true)
        return .reuse(wt)
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

    /// Called when a worktree is removed — marks the task as done and clears the worktree link,
    /// or deletes the task if it was only a hidden shadow. Fully tears down surface and observer.
    func handleWorktreeRemoved(branch: String) {
        guard let task = workTaskManager.task(forWorktree: branch) else { return }

        if let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }) {
            agentSurfaces.removeValue(forKey: worktree.id)
            for surfaceId in agentSurfaceIdentities[worktree.id] ?? [] {
                sessionObservers.removeValue(forKey: surfaceId)?.stopObserving()
                if let promptFile = launchPromptFiles.removeValue(forKey: surfaceId) {
                    try? FileManager.default.removeItem(atPath: promptFile)
                }
            }
            agentSurfaceIdentities.removeValue(forKey: worktree.id)
        }

        if task.hidden { workTaskManager.deleteTask(task); return }

        var updated = task
        updated.worktree = nil
        updated.status = .done
        workTaskManager.updateTask(updated)
    }

    /// Whether the given surface is an agent surface (should not be auto-restarted).
    /// Returns `true` for any ever-launched agent surface until the tab is explicitly closed.
    func isAgentSurface(_ surface: Ghostty.SurfaceView) -> Bool {
        let id = ObjectIdentifier(surface)
        return agentSurfaceIdentities.values.contains(where: { $0.contains(id) })
    }

    /// Called by TerminalManager when a main tab is closed.
    ///
    /// If the session observer is still registered, the agent's child hasn't exited yet
    /// — closeMainTab's SIGHUP is async. Leave identity/observer/prompt-file in place so
    /// handleChildExited can still attribute the upcoming exit.
    func handleMainTabClosed(_ surface: Ghostty.SurfaceView) {
        let id = ObjectIdentifier(surface)

        for (key, live) in agentSurfaces where live === surface {
            agentSurfaces.removeValue(forKey: key)
        }

        guard sessionObservers[id] == nil else { return }

        for key in agentSurfaceIdentities.keys {
            agentSurfaceIdentities[key]?.remove(id)
            if agentSurfaceIdentities[key]?.isEmpty == true {
                agentSurfaceIdentities.removeValue(forKey: key)
            }
        }
        if let promptFile = launchPromptFiles.removeValue(forKey: id) {
            try? FileManager.default.removeItem(atPath: promptFile)
        }
    }

    // MARK: - Agent Launch

    private func launchClaudeCode(for task: WorkTask, in worktree: Worktree, app: ghostty_app_t, isContinuation: Bool = false) {
        let prompt: String
        if isContinuation {
            prompt = "Continue working on this task. Review what was done and pick up where you left off."
        } else {
            prompt = task.body
        }

        let surface = runAgent(prompt: prompt, for: task, in: worktree, app: app, markAsLive: true)
        Ghostty.logger.info("Agent launched for worktree \(worktree.id, privacy: .public), surface: \(ObjectIdentifier(surface).debugDescription, privacy: .public)")
    }

    @discardableResult
    private func runAgent(prompt: String, for task: WorkTask, in worktree: Worktree, app: ghostty_app_t, markAsLive: Bool) -> Ghostty.SurfaceView {
        let agentCmd = "claude"

        // Unique per-launch prompt file — overlapping runs for the same task must not
        // share a path or a later launch's write will clobber the earlier one's prompt.
        let tempDir = NSTemporaryDirectory()
        let launchId = UUID().uuidString
        let promptFile = (tempDir as NSString).appendingPathComponent("clearway-prompt-\(task.id.uuidString)-\(launchId).md")
        FileManager.default.createFile(atPath: promptFile, contents: prompt.data(using: .utf8), attributes: [.posixPermissions: 0o600])

        // Pipe prompt file to agent command via stdin (same pattern as v1).
        // Both the agent command and file path are positional args to avoid shell injection.
        // $1 is intentionally unquoted so multi-word commands (e.g. "claude --flag") are word-split.
        // $3 injects the resolved login-shell PATH so tools like `claude` are found.
        let script = shellEscape("export PATH=\"$3\"; set -f; cat \"$2\" | $1")
        let args = [agentCmd, promptFile, ShellEnvironment.path].map(shellEscape).joined(separator: " ")
        let command = "/bin/sh -c \(script) -- \(args)"

        let surface: Ghostty.SurfaceView
        if markAsLive {
            // Live agent launches target a fresh task worktree; close the auto-created
            // initial tab (running `mainTerminalCommand`) and put the agent in its place.
            surface = terminalManager.launchAgentTab(for: worktree, app: app, command: command)
            agentSurfaces[worktree.id] = surface
        } else {
            // Shift-click state-command runs append alongside existing tabs and must
            // fall back to the project root when the main worktree has no path.
            surface = terminalManager.appendMainTab(for: worktree, app: app, command: command, projectPath: workTaskManager.projectPath)
        }
        agentSurfaceIdentities[worktree.id, default: []].insert(ObjectIdentifier(surface))
        launchPromptFiles[ObjectIdentifier(surface)] = promptFile

        // Start session observation for token tracking. Stall detection is currently
        // disabled — it was only ever enabled when the legacy WORKFLOW.md set
        // `agent.timeout_ms`, and that file is being retired.
        if let worktreePath = worktree.path {
            let observer = AgentSessionObserver()
            // onActivity is live-agent-only: it drives task status transitions,
            // which shift-click (markAsLive: false) launches must not trigger. The observer
            // itself is still created so token counts continue to accumulate in handleChildExited.
            if markAsLive {
                observer.onActivity = { [weak self] in
                    self?.handleSessionActivity(worktreeId: worktree.id)
                }
            }
            observer.startObserving(worktreePath: worktreePath)
            sessionObservers[ObjectIdentifier(surface)] = observer
        }

        return surface
    }

    // MARK: - Agent Lifecycle

    private func handleChildExited(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView,
              let exitCode = notification.userInfo?[GhosttyNotificationKey.exitCode] as? UInt32 else { return }

        let surfaceId = ObjectIdentifier(surface).debugDescription
        guard let worktreeId = agentSurfaceIdentities.first(where: { $0.value.contains(ObjectIdentifier(surface)) })?.key else {
            Ghostty.logger.info("ghosttyChildExited: surface=\(surfaceId, privacy: .public) exitCode=\(exitCode) isAgent=false")
            return
        }
        let isLiveAgent = agentSurfaces[worktreeId] === surface
        Ghostty.logger.info("ghosttyChildExited: surface=\(surfaceId, privacy: .public) exitCode=\(exitCode) isLiveAgent=\(isLiveAgent)")
        Ghostty.logger.info("Agent exited for worktree \(worktreeId, privacy: .public) with code \(exitCode)")

        // Only clear the live-agent entry if the exiting surface IS the currently-tracked live agent.
        // A superseded agent must not wipe the live agent entry.
        if agentSurfaces[worktreeId] === surface {
            agentSurfaces.removeValue(forKey: worktreeId)
        }

        // Retire the observer for this specific surface. Each launch has its own observer,
        // so reading + stopping it here attributes tokens to the correct run and avoids
        // double-counting when a superseded agent exits.
        let observer = sessionObservers.removeValue(forKey: ObjectIdentifier(surface))
        observer?.stopObserving()

        // Clean up this launch's temp prompt file and retire its identity.
        if let promptFile = launchPromptFiles.removeValue(forKey: ObjectIdentifier(surface)) {
            try? FileManager.default.removeItem(atPath: promptFile)
        }
        for key in agentSurfaceIdentities.keys {
            agentSurfaceIdentities[key]?.remove(ObjectIdentifier(surface))
            if agentSurfaceIdentities[key]?.isEmpty == true {
                agentSurfaceIdentities.removeValue(forKey: key)
            }
        }

        guard let worktree = worktreeManager.worktrees.first(where: { $0.id == worktreeId }),
              let branch = worktree.branch,
              var task = workTaskManager.task(forWorktree: branch) else { return }

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

    // MARK: - Auto-Fire (Phase 2)

    /// Routes a task status transition into `dispatchActions` when every
    /// gating precondition holds. Bails on the cheapest checks first so the
    /// hot path (no rules / task didn't opt in) is essentially free.
    private func handleAutoFire(task: WorkTask, newStatus: WorkTask.Status) {
        guard task.auto else { return }
        guard let branch = task.worktree else { return }
        guard visibleBranches.contains(branch) else { return }
        let actions = workflowAutomation.actions(for: newStatus)
        guard !actions.isEmpty else { return }
        guard let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }) else { return }
        guard let app = appProvider?() else { return }
        dispatchActions(actions, for: task, in: worktree, app: app)
    }
}

extension WorkTaskCoordinator {
    /// Creates a hidden shadow task for `branch` if none exists — no-op for task-initiated
    /// worktrees, whose exposed task already links the branch.
    func ensureShadowTask(forBranch branch: String) {
        guard workTaskManager.task(forWorktree: branch) == nil else { return }
        workTaskManager.createShadowTask(forBranch: branch)
    }
}
