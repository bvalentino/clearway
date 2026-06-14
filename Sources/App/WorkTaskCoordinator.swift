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
    /// `nil` until the first reload observes the worktree — also the "first sight" signal the engine
    /// uses to auto-pause a stale `autopilot: true` so opening a worktree never auto-runs.
    var lastKnownAutopilot: [String: Bool] = [:]

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
    // Watcher state (isWatching, planningWatcherSource, pendingPlanningReload, etc.) and
    // workTaskManager are internal, not private, because the PLANNING.md file-watching
    // methods live in `WorkTaskCoordinator+ConfigWatching.swift` — a cross-file extension
    // cannot reach private members. Only that extension should mutate them.

    let workTaskManager: WorkTaskManager
    // Internal (not private) so the `WorkTaskCoordinator+WorkflowEngine.swift` extension can launch
    // surfaces and resolve worktrees for the JSON loop engine.
    let terminalManager: TerminalManager
    let worktreeManager: WorktreeManager

    /// Live-reloaded planning config — watched for changes on disk.
    @Published private(set) var planningConfig: PlanningConfig?

    /// Cached, reactive answer to "does this project have a valid `.clearway/WORKFLOW.json`?" — the
    /// `AutopilotButton`'s visibility gate. Reading this `@Published` flag (instead of calling
    /// `hasJSONWorkflow()` per `body`) both avoids a full load+validate filesystem parse on every
    /// render and makes the button react when WORKFLOW.json is added/removed. Refreshed from the
    /// manager's always-fired `onClearwayChanged` reload hook (which fires on a WORKFLOW.json
    /// add/remove/edit even with zero task changes) plus once at init, so it is correct before the
    /// first reload. Same gate semantics: true only for a valid JSON workflow.
    @Published private(set) var isWorkflowJSONProject: Bool = false

    /// The parsed, validated `WORKFLOW.json`, cached alongside the gate so view-path reads
    /// (`workflowActionSlugs()`, the aside's status picker / play button) don't re-load + decode the
    /// file on every render — the gate's `nil`/non-`nil` and this cache are produced by the **single**
    /// load in `refreshWorkflowJSONGate()`. `nil` for a legacy project (or a malformed file, matching
    /// the gate). Refreshed in lockstep with the gate from `onClearwayChanged`, so it tracks a runtime
    /// WORKFLOW.json edit. The **event-driven engine paths** (`advanceWorkflow`, `seedWorkflowStatus`,
    /// `relaunchCurrentAction`, `runWorkflowAction`) deliberately keep loading **fresh from disk**:
    /// they run on the `TASK.md` reload, which the always-fired `onClearwayChanged` refresh precedes
    /// in the same `reload()` call, but loading fresh keeps the engine's correctness independent of
    /// cache-refresh ordering — it must never act on a definition staler than the file on disk.
    @Published private(set) var workflowDefinition: WorkflowDefinition?

    /// Recomputes the cached workflow-json gate **and** definition cache from disk in a single
    /// load+validate, so the two never disagree and the file is parsed once per refresh (not twice).
    /// Called from init and the manager's `onClearwayChanged` hook; each assignment is guarded so
    /// `objectWillChange` only fires when a value actually changes.
    func refreshWorkflowJSONGate() {
        let definition = try? WorkflowDefinition.load(projectPath: workTaskManager.projectPath)
        let value = definition != nil
        if value != isWorkflowJSONProject { isWorkflowJSONProject = value }
        if definition != workflowDefinition { workflowDefinition = definition }
    }

    func setPlanningConfig(_ config: PlanningConfig?) { planningConfig = config }

    var isWatching = false
    var planningWatcherSource: DispatchSourceFileSystemObject?
    var planningDirectoryWatcherSource: DispatchSourceFileSystemObject?
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

        // Refresh the cached gate + definition on *every* `.clearway/` change — fired unconditionally
        // by the manager before its pool-changed guard, so a WORKFLOW.json add/remove/edit that
        // touches no `TASK.md` still flips the gate (toolbar button visibility, aside JSON branch).
        // Decoupled from `onTasksReloaded` (the engine advance) on purpose: a pure no-change reload
        // refreshes the gate without driving a needless loop re-evaluation.
        self.workTaskManager.onClearwayChanged = { [weak self] in
            self?.refreshWorkflowJSONGate()
        }

        // Seed the cached workflow-json gate so the toolbar button is correct before the first
        // reload; subsequent `.clearway/` changes refresh it via `onClearwayChanged`.
        refreshWorkflowJSONGate()
    }

    nonisolated deinit {
        pendingPlanningReload?.cancel()
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
    }

    func startTask(_ task: WorkTask, app: ghostty_app_t) -> StartResult {
        guard task.status == WorkTask.ReservedStatus.new
                || task.status == WorkTask.ReservedStatus.readyToStart
                || task.status == WorkTask.ReservedStatus.canceled else { return .ignored }

        var updated = task
        if task.status == WorkTask.ReservedStatus.canceled {
            updated.attempt = (task.attempt ?? 0) + 1
        }
        updated.errorMessage = nil

        // Starting a task creates (or focuses) its worktree — agent spawning happens only through the
        // WORKFLOW.json loop engine. A JSON project's worktree-creation chokepoint seeds `status =
        // start` and launches its agent; a non-JSON project gets a worktree and nothing else.
        // Branch-keyed lookup resolves the correct worktree even when HEAD is detached (e.g. mid-rebase).
        if let branch = task.worktree,
           let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) {
            // Existing worktree → focus it; a JSON loop was already seeded at creation, don't relaunch.
            return .reuse(wt)
        }
        // No live worktree yet → create it (reusing a prior branch link if present). `status` is left
        // on its backlog marker; a JSON project's seed advances it to `start`. `pendingLaunch` is set
        // so `completePendingLaunch` relocates TASK.md into the worktree.
        let existingBranches = Set(worktreeManager.worktrees.compactMap(\.branch))
        let branch = task.worktree ?? workTaskManager.deriveBranchName(from: task.title, existingBranches: existingBranches)
        updated.worktree = branch
        workTaskManager.updateTask(updated)
        pendingLaunch = (id: updated.id, branch: branch)
        return .createWorktree(branch)
    }

    /// If a task launch was pending for this branch, relocates its TASK.md into the now-live worktree.
    /// Agent spawning is owned by the WORKFLOW.json loop engine's seed.
    func completePendingLaunch(branch: String, worktree: Worktree) {
        guard let pending = pendingLaunch, pending.branch == branch,
              let task = workTaskManager.tasks.first(where: { $0.id == pending.id }) else { return }
        pendingLaunch = nil

        // Move the task file into the now-live worktree so the seed writes to TASK.md in-place.
        if let path = worktree.path {
            workTaskManager.relocateTaskToWorktree(id: task.id, worktreePath: path)
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
    /// If the surface is still the tracked **live agent** for a worktree, the agent's child hasn't
    /// exited yet — closeMainTab's SIGHUP is async. Leave ALL bookkeeping (live entry, identity,
    /// prompt file) in place so `handleChildExited` can still attribute the upcoming exit: it owns
    /// the teardown, and the JSON loop engine's pause-on-death decision (`pauseIfAgentDiedMidStep`)
    /// hangs off that attributed exit. Clearing the live entry here used to make the exit
    /// unattributable, stranding `runningAction` forever.
    func handleMainTabClosed(_ surface: Ghostty.SurfaceView) {
        let id = ObjectIdentifier(surface)

        guard !agentSurfaces.values.contains(where: { $0 === surface }) else { return }

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

    /// The after_create hook command to run when a worktree is created, sourced from the JSON-workflow
    /// project's `WORKFLOW.json` `hooks.after_create`. `nil` when none is defined. The caller runs it
    /// before launching the agent so setup (deps, codegen, …) finishes first.
    func workflowAfterCreateHook() -> String? {
        (try? WorkflowDefinition.load(projectPath: workTaskManager.projectPath))?.hooks?.afterCreate
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
            let clearedAction = runningAction.removeValue(forKey: worktreeId)
            // The live agent is gone. If it died WITHOUT advancing `status` (crash, Ctrl-C, the
            // user closing its terminal), pause autopilot — otherwise the worktree is now *idle*
            // with autopilot on and `status` still on the action that was running, and the
            // engine's idle rule would relaunch that same action on the very next reload
            // (respawning an agent the user just killed). A normal advance (status already moved
            // on disk) is exempt — the pending reload launches the next action as usual.
            pauseIfAgentDiedMidStep(worktreeId: worktreeId, clearedAction: clearedAction)
        }

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
}

extension WorkTaskCoordinator {
    /// Creates a hidden shadow task for `branch` if none exists — no-op for task-initiated
    /// worktrees, whose exposed task already links the branch.
    func ensureShadowTask(forBranch branch: String) {
        guard workTaskManager.task(forWorktree: branch) == nil else { return }
        workTaskManager.createShadowTask(forBranch: branch)
    }
}
