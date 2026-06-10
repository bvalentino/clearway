import Foundation
import GhosttyKit

/// The `WORKFLOW.json` agent-driven loop engine, factored out of `WorkTaskCoordinator` to keep that
/// file focused on the legacy agent lifecycle. Mirrors the `+ConfigWatching` extension split: the
/// engine's in-memory state (`runningAction`, `engineHalted`, `lastKnownAutopilot`) and the surface-
/// tracking dictionaries it shares are declared `internal` on the coordinator so this cross-file
/// extension can reach them; only the coordinator and this file mutate them.
///
/// Everything here runs on `@MainActor` (the type is `@MainActor`-isolated): the watcher hops to the
/// main queue before invoking `onTasksReloaded`, so the engine never touches its state off-main, and
/// the launch tail sets `runningAction` immediately before spawning the surface with no `await`
/// between — guard and launch are one atomic step a concurrent reload can't interleave.
extension WorkTaskCoordinator {

    /// Re-evaluates the loop engine for each worktree after a `TASK.md` reload. No-op for projects
    /// without a valid `.clearway/WORKFLOW.json`, so legacy projects are untouched. Idempotent: the
    /// pure transition decision ignores a `status` that already equals the running action.
    ///
    /// Detects an `autopilot` *flip* as a distinct trigger, mirroring how `runningAction` tracks
    /// `P`: an enable (false→true) while the worktree sits idle on its current action re-launches
    /// that action (resume) instead of advancing; a disable (true→false) is handled implicitly by
    /// the pure decision (any launch is demoted to ignore — the running step finishes untouched).
    @MainActor
    func handleTasksReloaded(branches: [String]) {
        // Refresh the cached toolbar gate on every `.clearway/` reload — this path already fires on
        // WORKFLOW.json adds/removes — *before* the gate guard, so a removal flips the cache too.
        refreshWorkflowJSONGate()
        guard isWorkflowJSONProject, let app = appProvider() else { return }
        for branch in branches {
            // Auto-pause on first sight: a worktree the engine is observing for the first time this
            // session (just opened, or present when the project loaded) must never auto-run from a
            // stale `autopilot: true`. Pausing here is what makes "open a worktree" inert — the loop
            // only ever (re)starts on an explicit play. Skips the rest for this branch when it paused.
            if pauseStaleAutopilotOnFirstSight(forBranch: branch) { continue }
            let resumed = handleAutopilotFlip(forBranch: branch, app: app)
            // The resume already drove a launch decision; advancing again on the same reload would
            // re-evaluate the now-running action (a harmless ignore), so skip the redundant call.
            guard !resumed else { continue }
            advanceWorkflow(forBranch: branch, app: app)
        }
    }

    /// The first time the engine observes a worktree this session, a persisted `autopilot: true` is
    /// treated as **stale** and flipped to `false` — so opening a worktree (or having one open when
    /// the project loads) never relaunches a workflow on its own. Autopilot is a session-live flag:
    /// after an app restart nothing is actually running (in-memory engine state is empty), so the
    /// loop must wait for an explicit play. Returns `true` when it paused (the caller then skips
    /// advancing this branch).
    ///
    /// "First sight" = `lastKnownAutopilot[branch] == nil` (the flip tracker hasn't recorded it yet).
    /// A worktree we're already running — e.g. one just seeded on creation, whose agent launched
    /// directly via `seedWorkflowStatus` before this reload — is **exempt**, so a fresh create still
    /// runs. Records the flip baseline as `false` so the follow-up reload isn't a second "first sight".
    @MainActor
    private func pauseStaleAutopilotOnFirstSight(forBranch branch: String) -> Bool {
        guard lastKnownAutopilot[branch] == nil,
              let task = workTaskManager.task(forWorktree: branch),
              task.autopilot == true else { return false }
        // A freshly-seeded create launched its agent directly — don't pause an active step.
        if let id = worktreeId(forBranch: branch), runningAction[id] != nil { return false }
        lastKnownAutopilot[branch] = false
        workTaskManager.setAutopilot(task, to: false)
        return true
    }

    /// Reacts to an `autopilot` change since the last reload. Updates the last-known value and, on an
    /// enable (`false`→`true`) of an idle worktree, idempotently re-launches the action the worktree
    /// currently sits on (the resume path the spec specifies — "status is X, X not running → run it").
    /// Returns `true` when it drove a resume launch so the caller skips the redundant advance.
    ///
    /// A disable (`true`→`false`) needs no action here: the pure decision suppresses the next launch
    /// on the following advance, and a running agent is never interrupted. No prior value (first
    /// observation) is treated as "no flip" — the normal advance/seed paths own the initial launch.
    @MainActor
    private func handleAutopilotFlip(forBranch branch: String, app: ghostty_app_t) -> Bool {
        guard let task = workTaskManager.task(forWorktree: branch) else { return false }
        let previous = lastKnownAutopilot[branch]
        if let current = task.autopilot { lastKnownAutopilot[branch] = current }

        // Resume only on a genuine false→true transition of an idle worktree. `previous == true` or
        // `nil` (first sight) is not an enable; a worktree with a live agent surface isn't idle, so
        // its current step keeps running and the normal advance handles the next status write.
        let isIdle = worktreeId(forBranch: branch).map { agentSurfaces[$0] == nil } ?? true
        guard previous == false, task.autopilot == true, isIdle else { return false }
        relaunchCurrentAction(forBranch: branch, app: app)
        return true
    }

    /// The worktree id (path) for a branch, or `nil` when no live worktree matches.
    @MainActor
    private func worktreeId(forBranch branch: String) -> String? {
        worktreeManager.worktrees.first(where: { $0.branch == branch })?.id
    }

    // MARK: - WORKFLOW.json Loop Engine

    /// Whether the project is driven by the new agent-driven loop engine — true only when a
    /// **valid** `.clearway/WORKFLOW.json` is present. Projects without one keep the legacy
    /// `WORKFLOW.md` path entirely unchanged, so every engine entry point gates on this.
    @MainActor
    func hasJSONWorkflow() -> Bool {
        WorkflowDefinition.hasJSONWorkflow(projectPath: workTaskManager.projectPath)
    }

    /// The WORKFLOW.json action slugs in flow order, for the status picker — or `nil` for a legacy
    /// project (which keeps its fixed `WORKFLOW.md` states).
    @MainActor
    func workflowActionSlugs() -> [String]? {
        guard let definition = try? WorkflowDefinition.load(projectPath: workTaskManager.projectPath) else {
            return nil
        }
        return definition.orderedActionSlugs()
    }

    /// Runs the worktree's **current** action manually — the aside's per-state play button. Sends the
    /// action's prompt (instructions + injection contract) to the worktree's **main terminal**, the
    /// legacy "send to terminal" model: `activate` opens the main terminal if none exists (and makes it
    /// active), then `sendToActiveMainTab` pastes the prompt into the live surface (where an agent like
    /// Claude picks it up) or drops it into the launcher draft. This is a manual paste, distinct from
    /// the toolbar autopilot loop (which spawns dedicated agent surfaces) — it never touches engine
    /// state. Always available; no-op only when the status isn't a real action or Ghostty isn't ready.
    @MainActor
    func playWorkflowAction(forBranch branch: String) {
        guard let definition = try? WorkflowDefinition.load(projectPath: workTaskManager.projectPath),
              let app = appProvider(),
              let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }),
              let task = workTaskManager.task(forWorktree: branch),
              let action = definition.actions[task.status] else { return }
        let nextValue = WorkflowLoopEngine.legalNextValue(from: task.status, definition: definition)
        let prompt = WorkflowLoopEngine.buildPrompt(instructions: action.instructions, nextValue: nextValue)
        terminalManager.activate(worktree, app: app, projectPath: workTaskManager.projectPath)
        terminalManager.sendToActiveMainTab(prompt, asCommand: false)
    }

    /// Writes a **manual** status change from the task aside's picker. A human pick is an explicit
    /// intent — the user may set **any** state — so it is never validated as a route. For a JSON
    /// project it:
    /// - **clears the running pointer** (`runningAction`) so the engine sees the worktree as *idle* on
    ///   the new state. The watcher's `advanceWorkflow` then takes the idle path (launch any real
    ///   action under autopilot, or hold under the pause gate) instead of route-validating a transition
    ///   from the previously-running action — which is what produced "X is not a legal next from Y".
    /// - **clears any halt + error** so a halted loop recovers from the pick.
    ///
    /// A legacy project just writes the status. No-op when the value is unchanged.
    @MainActor
    func setWorkflowStatus(_ task: WorkTask, to slug: String) {
        guard task.status != slug else { return }
        guard hasJSONWorkflow(), let branch = task.worktree else {
            workTaskManager.setStatus(task, to: slug)
            return
        }
        engineHalted.remove(branch)
        if let id = worktreeId(forBranch: branch) { runningAction.removeValue(forKey: id) }
        var updated = task
        updated.status = slug
        updated.errorMessage = nil
        workTaskManager.updateTask(updated)
    }

    /// Whether the loop engine has a step *actually running* for this worktree — a live agent
    /// surface and/or a tracked running action (`P`). Read-only window onto the engine's internal
    /// state for the toolbar's activity indicator; it never mutates `runningAction`/`agentSurfaces`,
    /// so the view can't leak engine state. The two move in lockstep (`performLaunch` sets
    /// `runningAction` immediately before spawning the surface), so either being set means a step
    /// is mid-run. Keyed by worktree id (its path), matching how the engine stores both.
    @MainActor
    func isAgentRunning(forWorktree worktreeId: String) -> Bool {
        runningAction[worktreeId] != nil || agentSurfaces[worktreeId] != nil
    }

    /// Whether a manual kill should terminate a surface for a worktree — true only when a live agent
    /// surface is tracked. Pure (a function of the surface dictionary) so the kill *decision* is
    /// unit-testable without a live Ghostty app; the actual `terminateSurface` side effect needs one.
    /// The kill always pauses autopilot regardless; this only governs the surface-termination half.
    @MainActor
    func shouldTerminateOnManualKill(forWorktree worktreeId: String) -> Bool {
        agentSurfaces[worktreeId] != nil
    }

    /// **Manual kill** — the engine operation distinct from the autopilot *pause* (which never
    /// interrupts a running agent). It does two things, in order:
    ///
    /// 1. Pauses the loop by writing `autopilot = false` via the existing `setAutopilot` field-write,
    ///    so even after the surface dies the loop won't auto-advance.
    /// 2. Terminates the worktree's currently-running agent surface via `TerminalManager`'s existing
    ///    `terminateSurface` (which routes through `closeMainTab` → `closeSurface()` / SIGHUP).
    ///
    /// Because `handleChildExited` clears `runningAction` when the live surface exits (Phase 3), the
    /// termination tears down the engine's in-memory `P`, and the now-paused loop stays put. This is
    /// the **only** path allowed to interrupt a running agent. No-op for a worktree with no task /
    /// no live surface (nothing to kill — but autopilot is still paused if a task exists).
    @MainActor
    func manualKill(forBranch branch: String) {
        guard let task = workTaskManager.task(forWorktree: branch) else { return }
        // 1. Pause first so a race between the SIGHUP and the next reload can't auto-advance.
        workTaskManager.setAutopilot(task, to: false)
        // 2. Terminate the live agent surface for this worktree, if one is running.
        guard let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }),
              shouldTerminateOnManualKill(forWorktree: worktree.id),
              let surface = agentSurfaces[worktree.id] else { return }
        terminalManager.terminateSurface(surface, in: worktree.id)
    }

    #if DEBUG
    /// Test/restart seam: sets the in-memory running action (`P`) for a worktree directly, without a
    /// launch. Phase 3's restart-resume rebuilds this from disk; tests use it to stage a mid-loop
    /// state. The worktree id (its path) is the key, matching how `advanceWorkflow` reads `P`.
    /// DEBUG-only — the test bundle builds DEBUG, so this stays reachable from tests but never ships.
    @MainActor
    func setRunningActionForTesting(_ slug: String, branch: String, worktreePath: String) {
        let worktreeId = Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached).id
        runningAction[worktreeId] = slug
    }
    #endif

    /// The outcome of feeding a `TASK.md` change through the loop engine.
    enum WorkflowAdvanceResult: Equatable {
        case launched(slug: String)
        case ignored
        case ended(slug: String)
        case halted(reason: String)
    }

    /// Seeds a freshly created worktree's `TASK.md` with the workflow's `start` slug — the engine's
    /// **only** write to `status` — and defaults `autopilot` to `true` in the same write (a valid
    /// `WORKFLOW.json` project gets autopilot on by default). No-op for projects without a valid
    /// `.clearway/WORKFLOW.json`, so legacy projects keep no autopilot field and are untouched.
    /// Idempotent: only seeds when the task isn't already sitting on a **real action slug** — a
    /// re-created or resumed mid-loop worktree (status on any defined action) keeps its place rather
    /// than being yanked back to `start`. At creation `status` is a backlog/legacy value (not an
    /// action), so the seed still fires. It still backfills `autopilot` if absent, so a worktree
    /// already sitting on a real action only-missing-the-flag gains the default without losing place.
    @MainActor
    func seedWorkflowStatus(forBranch branch: String) {
        guard let definition = try? WorkflowDefinition.load(projectPath: workTaskManager.projectPath),
              var task = workTaskManager.task(forWorktree: branch),
              definition.actions[task.status] == nil || task.autopilot == nil else { return }
        // Seed `status` only when it isn't already a real action — a mid-loop worktree we're here
        // solely to backfill `autopilot` for keeps its place (the guard let it through on the flag).
        if definition.actions[task.status] == nil { task.status = definition.start }
        // Default autopilot on **only when the task has content** to work on — a manually-created
        // worktree with a blank TASK.md starts paused (`false`, not `nil`, since the engine treats a
        // missing flag as on and would launch anyway). Written alongside the seed as one coherent
        // creation write; only set when absent so a user's prior pause isn't clobbered.
        if task.autopilot == nil { task.autopilot = task.hasContent }
        task.errorMessage = nil
        // Clear any stale halt for a reused branch so the fresh seed can launch.
        engineHalted.remove(branch)
        workTaskManager.updateTask(task)

        // `updateTask` mutates the in-memory pool without re-running `reload()`, so the
        // `onTasksReloaded` engine hook won't fire for the seed. Kick the first launch directly.
        if let app = appProvider() {
            _ = advanceWorkflow(forBranch: branch, app: app)
        }
    }

    /// Feeds a worktree's current `TASK.md` `status` through the pure transition decision and acts on
    /// the result: launches the next action, ends on a terminal action, halts (surfacing the error)
    /// on an illegal/unknown value, or ignores a no-op. Gated end-to-end on a valid
    /// `.clearway/WORKFLOW.json`; legacy projects never reach here.
    @discardableResult
    @MainActor
    func advanceWorkflow(forBranch branch: String, app: ghostty_app_t) -> WorkflowAdvanceResult {
        guard let definition = try? WorkflowDefinition.load(projectPath: workTaskManager.projectPath) else {
            return .ignored
        }
        // A halted loop stays halted until something external clears it; don't re-evaluate.
        guard !engineHalted.contains(branch) else { return .ignored }
        guard let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }),
              var task = workTaskManager.task(forWorktree: branch) else { return .ignored }

        let decision = WorkflowLoopEngine.decideTransition(
            running: runningAction[worktree.id],
            written: task.status,
            autopilot: task.autopilot,
            definition: definition
        )

        switch decision {
        case .ignore:
            return .ignored

        case .halt(let reason):
            engineHalted.insert(branch)
            runningAction.removeValue(forKey: worktree.id)
            task.errorMessage = reason
            workTaskManager.updateTask(task)
            return .halted(reason: reason)

        case .launch(let slug, let nextValue):
            return performLaunch(slug: slug, nextValue: nextValue, in: worktree, definition: definition, app: app)
        }
    }

    /// Re-launches the action a worktree currently sits on — the autopilot **resume** path. Unlike
    /// `advanceWorkflow` this is not an advance (no route validation): an enable flip resumes the
    /// *current* state, so the engine relaunches whatever action `status` names, computing its
    /// injected next value the same way a launch would. Idempotent. No-op if the loop is halted, the
    /// status isn't a real action, or that action is already running.
    @discardableResult
    @MainActor
    private func relaunchCurrentAction(forBranch branch: String, app: ghostty_app_t) -> WorkflowAdvanceResult {
        guard let definition = try? WorkflowDefinition.load(projectPath: workTaskManager.projectPath) else {
            return .ignored
        }
        guard !engineHalted.contains(branch) else { return .ignored }
        guard let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }),
              let task = workTaskManager.task(forWorktree: branch),
              definition.actions[task.status] != nil,
              runningAction[worktree.id] != task.status else { return .ignored }

        let nextValue = WorkflowLoopEngine.legalNextValue(from: task.status, definition: definition)
        return performLaunch(slug: task.status, nextValue: nextValue, in: worktree, definition: definition, app: app)
    }

    /// Shared launch tail for `advanceWorkflow` and `relaunchCurrentAction`: builds the prompt, sets
    /// the idempotency guard (`runningAction`), and spawns the agent surface. Returns `.ended` for a
    /// terminal action; else `.launched`. `runningAction` is set immediately before the surface spawn
    /// with no `await` between — the method is synchronous on `@MainActor`, so guard+launch are atomic
    /// (a concurrent reload can't interleave between the idempotency guard being set and the spawn).
    ///
    /// The actual surface spawn goes through `workflowAgentLauncher` — `nil` in production (so the real
    /// `launchWorkflowAgent` runs), overridable in harness tests so they can observe a launch without a
    /// live Ghostty surface (mirroring the `appProvider` seam).
    @MainActor
    private func performLaunch(
        slug: String,
        nextValue: String?,
        in worktree: Worktree,
        definition: WorkflowDefinition,
        app: ghostty_app_t
    ) -> WorkflowAdvanceResult {
        guard let action = definition.actions[slug] else { return .ignored }
        let prompt = WorkflowLoopEngine.buildPrompt(instructions: action.instructions, nextValue: nextValue)
        runningAction[worktree.id] = slug
        if let launcher = workflowAgentLauncher {
            launcher(prompt, definition.agent.command, worktree, app)
        } else {
            launchWorkflowAgent(prompt: prompt, command: definition.agent.command, in: worktree, app: app)
        }
        return nextValue == nil ? .ended(slug: slug) : .launched(slug: slug)
    }

    /// Launches an action's agent in `worktree`, reusing the prompt-file → stdin → Ghostty-surface
    /// plumbing but driven by `WORKFLOW.json`'s `agent.command`. Deliberately does **not** attach the
    /// legacy activity/stall observers (which mutate `status` to `in_progress`/`done`) — under the
    /// JSON engine the agent owns every `status` advance, so the engine must never write status
    /// other than the initial seed. The surface is still tracked for teardown/`isAgentSurface`.
    @MainActor
    private func launchWorkflowAgent(prompt: String, command: String, in worktree: Worktree, app: ghostty_app_t) {
        // Unique per-launch prompt file (same contract as the legacy launch).
        let tempDir = NSTemporaryDirectory()
        let launchId = UUID().uuidString
        let promptFile = (tempDir as NSString).appendingPathComponent("clearway-workflow-prompt-\(launchId).md")
        FileManager.default.createFile(atPath: promptFile, contents: prompt.data(using: .utf8), attributes: [.posixPermissions: 0o600])

        // Pipe prompt file to the agent command via stdin. Command + path are positional args to
        // avoid shell injection; $1 is unquoted so multi-word commands word-split; $3 injects PATH.
        let script = shellEscape("export PATH=\"$3\"; set -f; cat \"$2\" | $1")
        let args = [command, promptFile, ShellEnvironment.path].map(shellEscape).joined(separator: " ")
        let shellCommand = "/bin/sh -c \(script) -- \(args)"

        let surface = terminalManager.launchAgentTab(for: worktree, app: app, command: shellCommand)
        setAgentSurface(surface, forWorktree: worktree.id)
        agentSurfaceIdentities[worktree.id, default: []].insert(ObjectIdentifier(surface))
        launchPromptFiles[ObjectIdentifier(surface)] = promptFile
        Ghostty.logger.info("Workflow agent launched for worktree \(worktree.id, privacy: .public), surface: \(ObjectIdentifier(surface).debugDescription, privacy: .public)")
    }
}
