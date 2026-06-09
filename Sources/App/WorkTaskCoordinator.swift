import Foundation
import GhosttyKit

/// Coordinates the task launch workflow: creating worktrees, running hooks,
/// and launching Claude Code. Extracted from ContentView to keep the view
/// focused on layout and navigation.
@MainActor
class WorkTaskCoordinator: ObservableObject {
    var pendingLaunch: (id: UUID, branch: String)?

    // MARK: - Agent Lifecycle

    /// Surfaces running agent commands, keyed by worktree ID.
    /// TerminalManager checks this to skip auto-restart for agent surfaces.
    /// Published so the UI can display the running agent count.
    @Published private(set) var agentSurfaces: [String: Ghostty.SurfaceView] = [:]

    /// Registers a live agent surface for a worktree. Keeps the `private(set)` contract on
    /// `agentSurfaces` while letting the `+WorkflowEngine` extension record its launches' surfaces.
    func setAgentSurface(_ surface: Ghostty.SurfaceView, forWorktree worktreeId: String) {
        agentSurfaces[worktreeId] = surface
    }

    /// Identities of every agent surface ever launched for a worktree (live or superseded).
    /// Keyed by worktree ID. Cleared when a tab is explicitly closed via `handleMainTabClosed`.
    /// Internal (not private) so the `WorkTaskCoordinator+WorkflowEngine.swift` extension — which
    /// launches the JSON loop's agent surfaces — can track them; only these two files mutate it.
    var agentSurfaceIdentities: [String: Set<ObjectIdentifier>] = [:]

    /// Session observers for running agents, keyed by agent surface identifier.
    /// Per-surface keying ensures overlapping launches (a superseded agent + the live one)
    /// have distinct observers — so `handleChildExited` retires the exact surface that
    /// exited instead of whichever observer happened to land in the worktree slot last.
    private var sessionObservers: [ObjectIdentifier: AgentSessionObserver] = [:]

    /// Per-launch prompt file paths, keyed by surface identifier. Unique per launch so
    /// overlapping runs for the same task don't share or clobber each other's temp file.
    /// Internal so the workflow-engine extension can register its launches' temp files.
    var launchPromptFiles: [ObjectIdentifier: String] = [:]

    // MARK: - WORKFLOW.json Loop Engine
    //
    // State the agent-driven loop tracks **in memory**. The keying is mixed by design and each
    // collection documents its own key: `runningAction` is keyed by `Worktree.id` (path), matching
    // the surface dictionaries (`agentSurfaces`/`launchPromptFiles`) it moves in lockstep with;
    // `engineHalted` and `lastKnownAutopilot` are keyed by branch (the task's stable link). Within a
    // session a worktree's path is stable, so the two key spaces never disagree; on restart this
    // state is empty and rebuilt from `TASK.md` (Phase 3). `runningAction` is the action currently
    // launched in a worktree (`P` in the engine semantics); `engineHalted` records worktrees whose
    // loop has stopped on an illegal/unknown status so the watcher doesn't keep re-evaluating them.

    // These three drive the JSON loop engine, whose methods live in the
    // `WorkTaskCoordinator+WorkflowEngine.swift` extension; they are internal (not private) so that
    // cross-file extension can reach them. Only the coordinator + that extension mutate them.

    /// The action currently running in each worktree, keyed by worktree id. The engine's `P`.
    /// Also the idempotency guard: a `TASK.md` change whose `status` already equals the running
    /// action is ignored, so the same value never double-launches.
    /// `@Published` so the toolbar's `isAgentRunning(forWorktree:)` has a guaranteed reactive path
    /// off both its inputs (the other being `agentSurfaces`), not just a coincidental re-render.
    @Published var runningAction: [String: String] = [:]

    /// Worktrees whose loop has halted (illegal/unknown status). Once halted the engine stops
    /// launching for that worktree until something external resets it.
    var engineHalted: Set<String> = []

    /// Last-known `autopilot` value per worktree branch, so a `TASK.md` reload can detect an
    /// autopilot *flip* as a distinct trigger (mirroring how `runningAction` tracks `P`). An
    /// enable (false→true) while idle re-runs the advance, which idempotently launches the current
    /// action; a disable (true→false) just stops advancing (a running step finishes untouched).
    /// `nil` until the first reload observes the worktree.
    var lastKnownAutopilot: [String: Bool] = [:]

    /// One-shot guard so restart-resume runs exactly once per window, even though its trigger
    /// (`resumeWorkflowsOnStartup`, called from the same `syncWatchedWorktrees` path as the task
    /// migration) fires from several lifecycle paths. Set the first time resume runs with a loaded
    /// worktree set; thereafter the live watcher owns all advances.
    var didResumeWorkflows = false

    /// Supplies the live `ghostty_app_t` so the watcher-driven engine can launch surfaces without
    /// the per-call `app:` argument the view passes elsewhere. Set by the view in `onAppear`
    /// (mirroring `TerminalManager.mainCommandProvider`). `nil` until Ghostty is ready.
    var appProvider: @MainActor () -> ghostty_app_t? = { nil }

    /// Test seam for the JSON loop's surface spawn. `nil` in production → `performLaunch` runs the real
    /// `launchWorkflowAgent` (prompt file → stdin → Ghostty surface). Harness tests override it to
    /// observe that a launch was reached without a live Ghostty app (mirrors `appProvider`).
    var workflowAgentLauncher: (@MainActor (_ prompt: String, _ command: String, _ worktree: Worktree, _ app: ghostty_app_t) -> Void)?

    // MARK: - Dependencies
    //
    // Watcher state (isWatching, watcherSource, pendingReload, workflowConfig, etc.) and
    // workTaskManager are internal, not private, because the WORKFLOW.md/PLANNING.md
    // file-watching methods live in `WorkTaskCoordinator+ConfigWatching.swift` — a
    // cross-file extension cannot reach private members. Only that extension should
    // mutate them.

    let workTaskManager: WorkTaskManager
    // Internal (not private) so the `WorkTaskCoordinator+WorkflowEngine.swift` extension can launch
    // surfaces and resolve worktrees for the JSON loop engine.
    let terminalManager: TerminalManager
    let worktreeManager: WorktreeManager

    /// Live-reloaded workflow config — watched for changes on disk.
    /// Mutate via `setWorkflowConfig` so the `private(set)` read-only contract
    /// reaches the cross-file extension without being widened to internal.
    @Published private(set) var workflowConfig: WorkflowConfig?

    /// Live-reloaded planning config — watched for changes on disk.
    @Published private(set) var planningConfig: WorkflowConfig?

    /// Cached, reactive answer to "does this project have a valid `.clearway/WORKFLOW.json`?" — the
    /// `AutopilotButton`'s visibility gate. Reading this `@Published` flag (instead of calling
    /// `hasJSONWorkflow()` per `body`) both avoids a full load+validate filesystem parse on every
    /// render and makes the button react when WORKFLOW.json is added/removed. Refreshed from the
    /// existing `.clearway/`-change reload path (`handleTasksReloaded`) plus once at init, so it is
    /// correct before the first reload. Same gate semantics: true only for a valid JSON workflow.
    @Published private(set) var isWorkflowJSONProject: Bool = false

    /// Recomputes the cached workflow-json gate from disk. Called from init and the reload hook;
    /// the assignment is guarded so `objectWillChange` only fires when the value actually flips.
    func refreshWorkflowJSONGate() {
        let value = hasJSONWorkflow()
        if value != isWorkflowJSONProject { isWorkflowJSONProject = value }
    }

    func setWorkflowConfig(_ config: WorkflowConfig?) { workflowConfig = config }
    func setPlanningConfig(_ config: WorkflowConfig?) { planningConfig = config }

    var isWatching = false
    var watcherSource: DispatchSourceFileSystemObject?
    var directoryWatcherSource: DispatchSourceFileSystemObject?
    var planningWatcherSource: DispatchSourceFileSystemObject?
    var planningDirectoryWatcherSource: DispatchSourceFileSystemObject?
    var pendingReload: DispatchWorkItem?
    var pendingPlanningReload: DispatchWorkItem?
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

        // Drive the WORKFLOW.json loop engine off the manager's debounced TASK.md reload. The
        // closure hops back through `self` so the engine logic stays on `WorkTaskCoordinator`.
        self.workTaskManager.onTasksReloaded = { [weak self] branches in
            self?.handleTasksReloaded(branches: branches)
        }

        // Seed the cached workflow-json gate so the toolbar button is correct before the first
        // reload; subsequent `.clearway/` changes refresh it via `handleTasksReloaded`.
        refreshWorkflowJSONGate()
    }

    nonisolated deinit {
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

    enum LaunchResult {
        case launched
        case ignored
        /// WORKFLOW.md hooks need user trust approval first. Call `approveTrust()` then retry.
        case needsTrust(WorkflowConfig)
    }

    func startTask(_ task: WorkTask, app: ghostty_app_t) -> StartResult {
        guard task.status == WorkTask.ReservedStatus.new
                || task.status == WorkTask.ReservedStatus.readyToStart
                || task.status == WorkTask.ReservedStatus.canceled else { return .ignored }

        // Check trust before executing any hooks
        if let config = workflowConfig, !config.isTrusted(forProject: workTaskManager.projectPath) {
            return .needsTrust(config)
        }

        var updated = task
        if task.status == WorkTask.ReservedStatus.canceled {
            updated.attempt = (task.attempt ?? 0) + 1
        }
        updated.errorMessage = nil

        // Branch-keyed lookup is intentional: it resolves the correct worktree even when HEAD
        // is temporarily detached (e.g. mid-rebase), because `branch` is stored separately.
        if let branch = task.worktree,
           let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) {
            updated.status = WorkTask.ReservedStatus.inProgress
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
            updated.status = WorkTask.ReservedStatus.inProgress
            workTaskManager.updateTask(updated)
            pendingLaunch = (id: updated.id, branch: branch)
            return .createWorktree(branch)
        }
    }

    /// Continues a completed task — re-launches agent with a continuation prompt.
    func continueTask(_ task: WorkTask, app: ghostty_app_t) -> StartResult {
        guard task.status == WorkTask.ReservedStatus.done
                || task.status == WorkTask.ReservedStatus.readyForReview
                || task.status == WorkTask.ReservedStatus.qa,
              let branch = task.worktree,
              let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) else { return .ignored }

        if let config = workflowConfig, !config.isTrusted(forProject: workTaskManager.projectPath) {
            return .needsTrust(config)
        }

        var updated = task
        updated.attempt = (task.attempt ?? 0) + 1
        updated.status = WorkTask.ReservedStatus.inProgress
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

    /// If a task launch was pending for this branch, returns a closure that launches Claude Code.
    func completePendingLaunch(branch: String, worktree: Worktree, app: ghostty_app_t) -> (() -> Void)? {
        guard let pending = pendingLaunch, pending.branch == branch,
              let task = workTaskManager.tasks.first(where: { $0.id == pending.id }) else { return nil }
        pendingLaunch = nil

        // Move the task file into the now-live worktree BEFORE launch, so the rendered prompt's
        // taskPath (resolved via filePath(for:), which keys off the branch) already points at
        // TASK.md. The move doesn't mutate the task's fields, so the captured value stays accurate.
        if let path = worktree.path {
            workTaskManager.relocateTaskToWorktree(id: task.id, worktreePath: path)
        }

        return { [weak self] in
            self?.launchClaudeCode(for: task, in: worktree, app: app)
        }
    }

    func worktreeForTask(_ task: WorkTask) -> Worktree? {
        guard let branch = task.worktree else { return nil }
        return worktreeManager.worktrees.first(where: { $0.branch == branch })
    }

    /// Called when a worktree is removed. The task's `TASK.md` lives in the worktree directory and
    /// dies with it (git removes it), so this only tears down the worktree's surfaces and observers
    /// — it writes nothing back to the central store. A re-merge (driven by the worktree-set change)
    /// drops the now-gone task from the in-memory pool.
    func handleWorktreeRemoved(branch: String) {
        guard let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }) else { return }

        agentSurfaces.removeValue(forKey: worktree.id)
        for surfaceId in agentSurfaceIdentities[worktree.id] ?? [] {
            sessionObservers.removeValue(forKey: surfaceId)?.stopObserving()
            if let promptFile = launchPromptFiles.removeValue(forKey: surfaceId) {
                try? FileManager.default.removeItem(atPath: promptFile)
            }
        }
        agentSurfaceIdentities.removeValue(forKey: worktree.id)

        // Drop the loop engine's in-memory state for this worktree (P + halt + last-known autopilot)
        // so a later worktree reusing the path/branch starts clean.
        runningAction.removeValue(forKey: worktree.id)
        engineHalted.remove(branch)
        lastKnownAutopilot.removeValue(forKey: branch)
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

        let surface = runAgent(prompt: prompt, for: task, in: worktree, app: app, markAsLive: true)
        Ghostty.logger.info("Agent launched for worktree \(worktree.id, privacy: .public), surface: \(ObjectIdentifier(surface).debugDescription, privacy: .public)")
    }

    @discardableResult
    private func runAgent(prompt: String, for task: WorkTask, in worktree: Worktree, app: ghostty_app_t, markAsLive: Bool) -> Ghostty.SurfaceView {
        let agentCmd = workflowConfig?.agentCommand ?? "claude"

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

        // Start session observation for activity + stall detection.
        // Stall detection is only enabled when agent.timeout_ms is explicitly set in WORKFLOW.md,
        // because Claude Code legitimately idles during permission prompts and user interaction.
        if let worktreePath = worktree.path {
            let observer = AgentSessionObserver()
            // onActivity/onStall are live-agent-only: they drive task status transitions,
            // which shift-click (markAsLive: false) launches must not trigger. The observer
            // is still created for every launch so handleChildExited can tear it down uniformly.
            if markAsLive {
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
            } else {
                observer.startObserving(worktreePath: worktreePath)
            }
            sessionObservers[ObjectIdentifier(surface)] = observer
        }

        return surface
    }

    // MARK: - Agent Lifecycle

    /// Whether an exiting agent surface should clear the worktree's live-agent state
    /// (`agentSurfaces` + the loop engine's `runningAction`).
    ///
    /// Returns `true` only when the exiting surface IS the worktree's currently-tracked live agent
    /// — i.e. it hasn't been superseded by a newer launch. A superseded (old) surface exiting after
    /// a normal advance must NOT clear state, or it would wipe the next action's freshly-set
    /// `runningAction`/live surface. Identity is compared by reference, matching how `agentSurfaces`
    /// tracks the live surface elsewhere. Generic over `AnyObject` (rather than `SurfaceView`) so it's
    /// unit-testable without a live Ghostty app — production passes the `SurfaceView`s directly.
    static func shouldClearLiveAgentState(
        exitingSurface: AnyObject,
        liveAgentSurface: AnyObject?
    ) -> Bool {
        liveAgentSurface === exitingSurface
    }

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
        //
        // Same guard governs clearing the loop engine's `runningAction` (the engine's `P`): if the
        // live agent exits abnormally BEFORE writing its next status (crash/kill), `runningAction`
        // would otherwise stay set, and `relaunchCurrentAction`'s `runningAction != status` guard
        // stays false forever — stranding the worktree (no autopilot-flip or restart resume). During
        // a NORMAL advance the next action's surface is launched first (it overwrites both
        // `agentSurfaces[worktreeId]` and `runningAction` with the next step), so the OLD surface
        // is already superseded here and this guard is false — leaving the freshly-set values intact.
        if Self.shouldClearLiveAgentState(exitingSurface: surface, liveAgentSurface: agentSurfaces[worktreeId]) {
            agentSurfaces.removeValue(forKey: worktreeId)
            runningAction.removeValue(forKey: worktreeId)
        }

        // Retire the observer for this specific surface. Each launch has its own observer,
        // so stopping it here retires the correct run without disturbing a superseded agent.
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
        // Just record an error on non-zero exit.
        if exitCode == 0 {
            task.errorMessage = nil
        } else {
            task.errorMessage = "Agent exited with code \(exitCode)"
        }

        workTaskManager.updateTask(task)
    }

    private func handleAgentStalled(worktreeId: String) {
        guard let worktree = worktreeManager.worktrees.first(where: { $0.id == worktreeId }),
              let branch = worktree.branch,
              var task = workTaskManager.task(forWorktree: branch),
              task.status == WorkTask.ReservedStatus.inProgress else { return }

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
              task.status == WorkTask.ReservedStatus.done else { return }

        Ghostty.logger.info("Session activity detected for worktree \(worktreeId, privacy: .public), resuming task")
        task.status = WorkTask.ReservedStatus.inProgress
        task.errorMessage = nil
        workTaskManager.updateTask(task)
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
