import Foundation
import GhosttyKit

/// A pending auto-run countdown for a worktree: the action about to launch and the deadline the card
/// animates against. The cancellation handle lives separately on the coordinator (`countdownWorkItems`);
/// this carries only what the view renders, so it stays a value type the `@Published` map can diff.
struct WorkflowCountdown: Equatable {
    let slug: String
    let deadline: Date
}

/// Identifies one launch: which action, and which launch *of* that action. A launch suspends while it
/// awaits the resolved PATH, and needs both halves to decide on resume whether it is still the one the
/// engine wants — see `isLaunchCurrent(_:forWorktree:)`.
struct WorkflowLaunchID: Equatable {
    let slug: String
    let generation: Int
}

/// The `WORKFLOW.json` agent-driven loop engine, factored out of `WorkTaskCoordinator` to keep that
/// file focused on the legacy agent lifecycle. Mirrors the `+ConfigWatching` extension split: the
/// engine's in-memory state (`runningAction`, `engineHalted`, `lastKnownAutopilot`) and the surface-
/// tracking dictionaries it shares are declared `internal` on the coordinator so this cross-file
/// extension can reach them; only the coordinator and this file mutate them.
///
/// Everything here runs on `@MainActor` (the type is `@MainActor`-isolated): the watcher hops to the
/// main queue before invoking `onTasksReloaded`, so the engine never touches its state off-main, and
/// the launch tail sets `runningAction` synchronously with the decision that produced it, so a
/// concurrent reload can't interleave between the two. The surface spawn that follows *does* suspend
/// (it awaits the resolved PATH), so it re-reads the guard before spawning — see `launchWorkflowAgent`.
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
        // The cached gate + definition are refreshed by the manager's always-fired `onClearwayChanged`
        // hook (wired in init), which runs *before* this engine advance on the same `reload()` — and
        // crucially also fires on a WORKFLOW.json add/remove/edit that changes no task, which this
        // pool-changed-only path would miss. So the gate is already current here; just read it.
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
            // The watch path is the agent-driven hand-off seam: a launch here is the mid-loop
            // transition that gets the visible, interruptible grace period (seed/resume stay immediate).
            advanceWorkflow(forBranch: branch, app: app, gracePeriod: true)
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

        // A pause (true→false) cancels any armed hand-off countdown — the central chokepoint every
        // pause path reaches via the autopilot write's reload, including the toolbar button, which
        // (unlike the card's Pause and the manual kill) has no synchronous cancel of its own.
        if previous == true, task.autopilot == false, let id = worktreeId(forBranch: branch) {
            cancelCountdown(forWorktree: id)
        }

        // Resume only on a genuine false→true transition of an idle worktree. `previous == true` or
        // `nil` (first sight) is not an enable; a worktree with a live agent surface isn't idle, so
        // its current step keeps running and the normal advance handles the next status write.
        let isIdle = worktreeId(forBranch: branch).map { agentSurfaces[$0] == nil } ?? true
        guard previous == false, task.autopilot == true, isIdle else { return false }

        // Re-enabling a **completed** task reopens it rather than resuming: clear `completed` and
        // re-pause (correct the button's optimistic enable back to `false`), launching nothing. The
        // loop is reopened/resumable and idle — the idle-launch rule would otherwise immediately
        // re-run the terminal action, so the user must steer it with a manual pick.
        if task.completed == true {
            workTaskManager.updateFields(id: task.id) {
                $0.completed = nil
                $0.autopilot = false
            }
            lastKnownAutopilot[branch] = false
            return true
        }

        relaunchCurrentAction(forBranch: branch, app: app)
        return true
    }

    /// The worktree id (path) for a branch, or `nil` when no live worktree matches.
    @MainActor
    private func worktreeId(forBranch branch: String) -> String? {
        worktreeManager.worktrees.first(where: { $0.branch == branch })?.id
    }

    /// The branch of the worktree with this id, or `nil` when no live worktree matches. The mirror
    /// of `worktreeId(forBranch:)`: engine state is keyed by worktree id, task state by branch.
    @MainActor
    func branch(forWorktree worktreeId: String) -> String? {
        worktreeManager.worktrees.first(where: { $0.id == worktreeId })?.branch
    }

    /// The pending auto-run countdown for a branch's worktree, or `nil` when none is scheduled — the
    /// read-only window the task aside's current card uses to render its depleting ring + Pause.
    @MainActor
    func workflowCountdown(forBranch branch: String) -> WorkflowCountdown? {
        worktreeId(forBranch: branch).flatMap { workflowCountdowns[$0] }
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
    /// project (which keeps its fixed `WORKFLOW.md` states). Reads the **cached** definition (refreshed
    /// in lockstep with the gate via `onClearwayChanged`), not a fresh disk load: this is a per-render
    /// view path (`TaskAsideView` calls it twice per `body`), so a load+decode+validate here would be
    /// repeated filesystem I/O on every render — the whole point of caching the definition.
    @MainActor
    func workflowActionSlugs() -> [String]? {
        workflowDefinition?.orderedActionSlugs()
    }

    /// An action's display label, read from the **cached** definition like `workflowActionSlugs()`
    /// so the tab strip never hits disk per render.
    func workflowActionName(_ slug: String) -> String? {
        workflowDefinition?.actions[slug]?.name
    }

    /// The workflow step a worktree currently sits on — what a newly opened tab is badged with.
    ///
    /// Sourced from the task's `status`, **not** `runningAction`: the latter holds a slug only while
    /// an agent process is alive, so it is empty for the whole of normal manual use (opening a
    /// worktree pauses autopilot, and a manual step pick clears it outright) and would leave every
    /// hand-opened tab unbadged. Admitting the status only when it names a real action is what keeps
    /// reserved backlog markers, the legacy fixed states, and projects with no `WORKFLOW.json` from
    /// badging anything — no caller needs to branch on `isWorkflowJSONProject`.
    @MainActor
    func currentWorkflowStep(forWorktree worktreeId: String) -> String? {
        guard let branch = branch(forWorktree: worktreeId),
              let status = workTaskManager.task(forWorktree: branch)?.status,
              workflowDefinition?.actions[status] != nil else { return nil }
        return status
    }

    /// Writes a **manual** status change from the task aside's picker. A human pick is an explicit
    /// intent — the user may set **any** state — so it is never validated as a route. For a JSON
    /// project it:
    /// - **terminates the running agent surface, if one is live**, before writing the new status. A
    ///   manual pick mid-step would otherwise leave a zombie: clearing `runningAction` makes the
    ///   watcher launch the picked action (under autopilot), overwriting `agentSurfaces` — two agents
    ///   then run in the same worktree, both editing `TASK.md`, and the superseded one's eventual write
    ///   gets route-validated against the *new* running action and halts with a confusing error.
    ///   Terminating reuses the manual-kill plumbing (`shouldTerminateOnManualKill` /
    ///   `terminateSurface`) but, unlike `manualKill`, does **not** pause autopilot — the user is
    ///   *steering* the loop, not stopping it. Order matters: terminate **before** the status write so
    ///   the SIGHUP'd old agent is already superseded when the watcher reacts to the new status — and
    ///   so `handleChildExited`'s `shouldClearLiveAgentState` guard sees the freshly-launched next
    ///   action as the live surface (not the dying one) and leaves its `runningAction` intact.
    /// - **clears the running pointer** (`runningAction`) so the engine sees the worktree as *idle* on
    ///   the new state. The watcher's `advanceWorkflow` then takes the idle path (launch any real
    ///   action under autopilot, or hold under the pause gate) instead of route-validating a transition
    ///   from the previously-running action — which is what produced "X is not a legal next from Y".
    /// - **clears any halt + error, and any `completed` flag** so a halted or completed loop reopens
    ///   from the pick.
    ///
    /// A legacy project just writes the status. For a JSON project the status write may be a no-op
    /// (the picked slug already equals the current state) yet still has reopening to do — clearing
    /// `completed`, the halt, and the error — so the no-op short-circuit fires only when there is
    /// genuinely nothing to change. This is what lets `setWorkflowActionCurrent` reopen the *current*
    /// terminal action of a completed task.
    @MainActor
    func setWorkflowStatus(_ task: WorkTask, to slug: String) {
        guard hasJSONWorkflow(), let branch = task.worktree else {
            workTaskManager.setStatus(task, to: slug)
            return
        }
        let hasReopenWork = task.completed != nil || task.errorMessage != nil || engineHalted.contains(branch)
        guard task.status != slug || hasReopenWork else { return }
        // Supersede the in-flight agent first (no autopilot pause — this is steering, not stopping),
        // so the dying surface can't race the watcher's relaunch into a two-agent / halt tangle.
        if let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }),
           shouldTerminateOnManualKill(forWorktree: worktree.id),
           let surface = agentSurfaces[worktree.id] {
            terminalManager.terminateSurface(surface, in: worktree.id)
        }
        engineHalted.remove(branch)
        if let id = worktreeId(forBranch: branch) {
            runningAction.removeValue(forKey: id)
            // Steering supersedes any imminent auto-launch: drop its countdown so the card stops
            // counting down to an action the user just overrode.
            cancelCountdown(forWorktree: id)
        }
        workTaskManager.updateFields(id: task.id) {
            $0.status = slug
            $0.errorMessage = nil
            // Clear completion so a completed loop reopens (writes `nil` — omits the line — never `false`).
            $0.completed = nil
        }
    }

    /// A sidebar action card's **Set as current** — steer `status` to `slug` without launching it,
    /// taking manual control of the loop. Unlike `setWorkflowStatus` (which steers *without* pausing),
    /// this pauses autopilot: manual per-card control and the autopilot loop are mutually exclusive,
    /// and the user re-enables the loop via the toolbar button. The pause is **unconditional** — it
    /// fires even when `slug` already equals the current status (a no-op status write that
    /// `setWorkflowStatus` skips), so clicking a card always hands control over.
    ///
    /// The freshly-paused task is re-read before the status write so it preserves `autopilot:false`
    /// rather than restoring it from the now-stale captured `task`.
    @MainActor
    func setWorkflowActionCurrent(_ task: WorkTask, to slug: String) {
        // Cancel here too: when `slug` already equals the current status, `setWorkflowStatus`
        // early-returns without cancelling, but taking manual control must still stop the countdown.
        if let id = task.worktree.flatMap(worktreeId(forBranch:)) { cancelCountdown(forWorktree: id) }
        workTaskManager.setAutopilot(task, to: false)
        let paused = task.worktree.flatMap { workTaskManager.task(forWorktree: $0) } ?? task
        setWorkflowStatus(paused, to: slug)
    }

    /// A sidebar action card's **Run** — set `slug` as current (pausing autopilot), then deliver its
    /// prompt to a terminal in the manual-paste model. `inNewTerminal` opens a fresh launcher tab and
    /// fills its draft; otherwise it pastes into the worktree's existing main terminal (opening one if
    /// needed). Neither spawns the autonomous agent surface autopilot uses.
    ///
    /// Engine state is steered **first** so the status write supersedes any live agent before the
    /// paste lands (no running-agent-vs-paste race), and so the pool reflects the new current action
    /// even when no Ghostty app is available to take the paste (the test harness).
    @MainActor
    func runWorkflowAction(forBranch branch: String, slug: String, inNewTerminal: Bool) {
        guard let definition = try? WorkflowDefinition.load(projectPath: workTaskManager.projectPath),
              let action = definition.actions[slug],
              let task = workTaskManager.task(forWorktree: branch) else { return }
        setWorkflowActionCurrent(task, to: slug)

        guard let app = appProvider(),
              let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }) else { return }
        let nextValue = WorkflowLoopEngine.legalNextValue(from: slug, definition: definition)
        let prompt = WorkflowLoopEngine.buildPrompt(instructions: action.instructions, nextValue: nextValue)
        if inNewTerminal {
            let command = workflowAgentCommand(for: definition, action: action)
            if let appender = launcherTabAppender {
                appender(worktree, command)
            } else {
                terminalManager.appendLauncherTab(
                    for: worktree,
                    app: app,
                    projectPath: workTaskManager.projectPath,
                    command: command
                )
            }
        } else {
            terminalManager.activate(worktree, app: app, projectPath: workTaskManager.projectPath)
        }
        terminalManager.sendToActiveMainTab(prompt, asCommand: false)
    }

    /// Whether the loop engine has a step *actually running* for this worktree — a live agent
    /// surface and/or a tracked running action (`P`). Read-only window onto the engine's internal
    /// state for the toolbar's activity indicator; it never mutates `runningAction`/`agentSurfaces`,
    /// so the view can't leak engine state. Either being set means a step is mid-run: `runningAction`
    /// alone covers the window where `launchWorkflowAgent` is still awaiting the PATH and no surface
    /// exists yet. Keyed by worktree id (its path), matching how the engine stores both.
    @MainActor
    func isAgentRunning(forWorktree worktreeId: String) -> Bool {
        runningAction[worktreeId] != nil || agentSurfaces[worktreeId] != nil
    }

    /// Records a new launch of `slug` for the worktree — the idempotency guard (`runningAction`) plus
    /// this launch's generation — and returns its identity for the resume check below.
    @MainActor
    private func beginLaunch(slug: String, forWorktree worktreeId: String) -> WorkflowLaunchID {
        runningAction[worktreeId] = slug
        let generation = (launchGeneration[worktreeId] ?? 0) + 1
        launchGeneration[worktreeId] = generation
        return WorkflowLaunchID(slug: slug, generation: generation)
    }

    /// Whether `launch` is still the launch the engine wants — the check it makes when it resumes
    /// from awaiting the resolved PATH.
    ///
    /// Both halves are load-bearing. The slug catches a *steer*: a manual pick or a halt moves
    /// `runningAction` to another action, or clears it, and never bumps the generation. The
    /// generation catches a *relaunch of the same action*: a kill clears `runningAction`, a play
    /// re-launches the action the worktree still sits on, and the superseded launch would otherwise
    /// read its own slug back and spawn a second agent into the worktree.
    @MainActor
    func isLaunchCurrent(_ launch: WorkflowLaunchID, forWorktree worktreeId: String) -> Bool {
        runningAction[worktreeId] == launch.slug && launchGeneration[worktreeId] == launch.generation
    }

    /// Whether a manual kill should terminate a surface for a worktree — true only when a live agent
    /// surface is tracked. Pure (a function of the surface dictionary) so the kill *decision* is
    /// unit-testable without a live Ghostty app; the actual `terminateSurface` side effect needs one.
    /// The kill always pauses autopilot regardless; this only governs the surface-termination half.
    @MainActor
    func shouldTerminateOnManualKill(forWorktree worktreeId: String) -> Bool {
        agentSurfaces[worktreeId] != nil
    }

    /// Pauses autopilot when the live agent **died mid-step** — exited without advancing `status`
    /// (crash, Ctrl-C, the user closing its terminal/tab). Called from `handleChildExited` right
    /// after it clears the live-agent state, with the `runningAction` slug it cleared.
    ///
    /// Why: clearing `runningAction` leaves the worktree *idle* with `status` still on the action
    /// that was running. Under `autopilot: true`, the engine's idle rule launches any real action a
    /// reload observes — so without this pause, the very next reload would respawn the agent the
    /// user just killed (and a finished **terminal** action would re-run on every later reload).
    /// Pausing keeps the design rule intact: the loop only ever (re)starts on an explicit play or a
    /// manual status pick. Manual-kill semantics minus the terminate (the agent is already dead).
    ///
    /// "Died mid-step" is judged against a **fresh disk read** (`freshStatus`), not the in-memory
    /// pool: an agent that wrote its advance and exited immediately may beat the watcher's debounced
    /// reload, so the pool can still show the old status during a normal advance. Disk is
    /// authoritative and race-free here — a process that has already exited can't write afterwards.
    /// If disk status moved off the cleared action, the advance is in flight: don't pause, the
    /// pending reload launches the next action as usual. No-op for legacy projects, a worktree
    /// with no task, or a loop already paused.
    @MainActor
    func pauseIfAgentDiedMidStep(worktreeId: String, clearedAction: String?) {
        guard let clearedAction,
              hasJSONWorkflow(),
              let branch = branch(forWorktree: worktreeId),
              let task = workTaskManager.task(forWorktree: branch),
              task.autopilot != false else { return }
        let diskStatus = workTaskManager.freshStatus(forWorktree: branch) ?? task.status
        guard diskStatus == clearedAction else { return }
        workTaskManager.setAutopilot(task, to: false)
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
    /// the **pause-and-interrupt** path: it stops the loop. (A manual status pick — `setWorkflowStatus`
    /// — also terminates a running agent, but it *steers* the loop instead of pausing it.) No-op for a
    /// worktree with no task / no live surface (nothing to kill — but autopilot is still paused if a
    /// task exists).
    @MainActor
    func manualKill(forBranch branch: String) {
        guard let task = workTaskManager.task(forWorktree: branch) else { return }
        // 1. Pause first so a race between the SIGHUP and the next reload can't auto-advance.
        workTaskManager.setAutopilot(task, to: false)
        // 2. Terminate the live agent surface for this worktree, if one is running.
        guard let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }) else { return }
        // Drop any pending auto-launch countdown — stopping the loop must also stop its next launch.
        cancelCountdown(forWorktree: worktree.id)
        guard shouldTerminateOnManualKill(forWorktree: worktree.id),
              let surface = agentSurfaces[worktree.id] else {
            // A running action with no surface means `launchWorkflowAgent` is mid-await on the PATH.
            // Nothing will exit later to clear `P`, so clear it here: that both un-wedges the engine
            // and makes the resumed launch abandon itself.
            runningAction.removeValue(forKey: worktree.id)
            return
        }
        terminalManager.terminateSurface(surface, in: worktree.id)
    }

    #if DEBUG
    /// Test/restart seam: sets the in-memory running action (`P`) for a worktree directly, without a
    /// launch. Phase 3's restart-resume rebuilds this from disk; tests use it to stage a mid-loop
    /// state. The worktree id (its path) is the key, matching how `advanceWorkflow` reads `P`.
    /// Goes through `beginLaunch`, so a staged step is indistinguishable from a launched one; the
    /// returned identity is what a test needs to stand in for a launch still awaiting its PATH.
    /// DEBUG-only — the test bundle builds DEBUG, so this stays reachable from tests but never ships.
    @MainActor
    @discardableResult
    func setRunningActionForTesting(_ slug: String, branch: String, worktreePath: String) -> WorkflowLaunchID {
        let worktreeId = Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached).id
        return beginLaunch(slug: slug, forWorktree: worktreeId)
    }
    #endif

    /// The outcome of feeding a `TASK.md` change through the loop engine.
    enum WorkflowAdvanceResult: Equatable {
        case launched(slug: String)
        case ignored
        case ended(slug: String)
        case completed(slug: String)
        case halted(reason: String)
        /// A grace-period advance scheduled a countdown for `slug` instead of launching it now. The
        /// launch happens when the countdown fires (re-running the advance immediately), unless a
        /// pause/steer cancels it first.
        case deferred(slug: String)
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
              let task = workTaskManager.task(forWorktree: branch),
              definition.actions[task.status] == nil || task.autopilot == nil else { return }
        // Clear any stale halt for a reused branch so the fresh seed can launch.
        engineHalted.remove(branch)
        workTaskManager.updateFields(id: task.id) { updated in
            // Seed `status` only when it isn't already a real action — a mid-loop worktree we're here
            // solely to backfill `autopilot` for keeps its place (the guard let it through on the flag).
            // A **hidden** task is a shadow: no task is associated with the worktree yet, so it gets no
            // step until `exposeTask` associates one and calls back here.
            if definition.actions[updated.status] == nil && !updated.hidden { updated.status = definition.start }
            // Default autopilot on **only when the task has content** to work on — a manually-created
            // worktree with a blank TASK.md starts paused (`false`, not `nil`, since the engine treats a
            // missing flag as on and would launch anyway). Written alongside the seed as one coherent
            // creation write; only set when absent so a user's prior pause isn't clobbered.
            if updated.autopilot == nil { updated.autopilot = updated.hasContent }
            updated.errorMessage = nil
        }

        // Seed write bypasses the reload watcher — kick the first launch directly.
        if let app = appProvider() {
            _ = advanceWorkflow(forBranch: branch, app: app)
        }
    }

    /// Feeds a worktree's current `TASK.md` `status` (and `completed` flag) through the pure transition
    /// decision and acts on the result: launches the next action, ends on a terminal action, completes
    /// (pausing autopilot) when a terminal action signaled `completed: true`, halts (surfacing the
    /// error) on an illegal/unknown value, or ignores a no-op. Gated end-to-end on a valid
    /// `.clearway/WORKFLOW.json`; legacy projects never reach here.
    ///
    /// `gracePeriod` makes a launch *deferred*: the watch path (`handleTasksReloaded`) passes `true`
    /// so an agent-driven mid-loop hand-off schedules a visible, interruptible countdown instead of
    /// launching immediately, returning `.deferred`. The seed, the countdown's own fire, and the
    /// resume path keep the default `false` (immediate launch). The pure decision is unchanged — the
    /// grace lives entirely in this launch plumbing.
    @discardableResult
    @MainActor
    func advanceWorkflow(forBranch branch: String, app: ghostty_app_t, gracePeriod: Bool = false) -> WorkflowAdvanceResult {
        guard let definition = try? WorkflowDefinition.load(projectPath: workTaskManager.projectPath) else {
            return .ignored
        }
        // A halted loop stays halted until something external clears it; don't re-evaluate.
        guard !engineHalted.contains(branch) else { return .ignored }
        guard let worktree = worktreeManager.worktrees.first(where: { $0.branch == branch }),
              let task = workTaskManager.task(forWorktree: branch) else { return .ignored }
        // A hidden shadow the seed deliberately left un-stepped has no task associated, so its status
        // is Clearway's own marker rather than an agent write — halting on it would blame a
        // hallucination that never happened, and stick, swallowing every later advance. A step card's
        // Set Current gives such a worktree a real action, and then it runs normally.
        guard !task.hidden || definition.actions[task.status] != nil else { return .ignored }

        let decision = WorkflowLoopEngine.decideTransition(
            running: runningAction[worktree.id],
            written: task.status,
            autopilot: task.autopilot,
            completed: task.completed,
            definition: definition
        )

        switch decision {
        case .ignore:
            return .ignored

        case .halt(let reason):
            engineHalted.insert(branch)
            runningAction.removeValue(forKey: worktree.id)
            // A halt leaves the normal advance path — drop any countdown armed by a prior legal
            // advance so the card stops counting down to a launch the halted loop won't perform.
            cancelCountdown(forWorktree: worktree.id)
            workTaskManager.updateFields(id: task.id) { $0.errorMessage = reason }
            return .halted(reason: reason)

        case .launch(let slug, let nextValue):
            if gracePeriod {
                return scheduleCountdown(slug: slug, branch: branch, worktreeId: worktree.id)
            }
            return performLaunch(slug: slug, nextValue: nextValue, in: worktree, definition: definition, app: app)

        // A terminal action's agent signaled a deliberate finish. End the loop: pause autopilot and
        // launch nothing, so the idle rule never respawns the terminal action on any later reload.
        case .complete(let slug):
            workTaskManager.setAutopilot(task, to: false)
            return .completed(slug: slug)
        }
    }

    /// Schedules the grace-period countdown for an imminent auto-launch and returns `.deferred`. The
    /// fire (after `countdownDuration`) re-runs the **immediate** `advanceWorkflow`, so the autopilot
    /// pause gate is re-read at fire time and the actual launch reuses the normal path. Idempotent per
    /// worktree+slug: a repeated watch reload for the same pending action keeps the original deadline
    /// rather than resetting it; a different slug replaces a stale countdown.
    @MainActor
    private func scheduleCountdown(slug: String, branch: String, worktreeId: String) -> WorkflowAdvanceResult {
        if workflowCountdowns[worktreeId]?.slug == slug { return .deferred(slug: slug) }
        cancelCountdown(forWorktree: worktreeId)

        workflowCountdowns[worktreeId] = WorkflowCountdown(
            slug: slug,
            deadline: Date().addingTimeInterval(Self.countdownDuration)
        )
        let fire: @MainActor () -> Void = { [weak self] in
            self?.fireCountdown(forBranch: branch, worktreeId: worktreeId)
        }
        if let scheduler = workflowCountdownScheduler {
            scheduler(fire)
        } else {
            let work = DispatchWorkItem { fire() }
            countdownWorkItems[worktreeId] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.countdownDuration, execute: work)
        }
        return .deferred(slug: slug)
    }

    /// The countdown elapsed: clear its state and re-run the **immediate** advance, which performs the
    /// launch the countdown was gating (or, if a pause/steer slipped in, is suppressed by the pause
    /// gate / superseded by the new running pointer). No-op if Ghostty isn't ready.
    @MainActor
    func fireCountdown(forBranch branch: String, worktreeId: String) {
        workflowCountdowns.removeValue(forKey: worktreeId)
        countdownWorkItems.removeValue(forKey: worktreeId)
        guard let app = appProvider() else { return }
        advanceWorkflow(forBranch: branch, app: app)
    }

    /// Cancels a pending countdown for a worktree — stops the scheduled fire and clears the card's
    /// countdown state. Safe to call when none is pending. Used by the pause control and by manual
    /// steer/kill so a hand-off in its grace window doesn't fire after the user takes control.
    @MainActor
    func cancelCountdown(forWorktree worktreeId: String) {
        countdownWorkItems.removeValue(forKey: worktreeId)?.cancel()
        workflowCountdowns.removeValue(forKey: worktreeId)
    }

    /// The countdown card's **Pause** — cancel the imminent auto-launch and pause autopilot, reusing
    /// the existing pause path (`setAutopilot(false)`). Functionally identical to pressing the toolbar
    /// pause at that instant: the pending action does not launch, and future launches are suppressed
    /// until the user resumes. No-op for a branch with no task / no live worktree.
    @MainActor
    func pauseFromCountdown(forBranch branch: String) {
        if let id = worktreeId(forBranch: branch) {
            cancelCountdown(forWorktree: id)
        }
        guard let task = workTaskManager.task(forWorktree: branch) else { return }
        workTaskManager.setAutopilot(task, to: false)
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
    /// the idempotency guard (`runningAction`) and this launch's generation, and spawns the agent
    /// surface. Returns `.ended` for a terminal action; else `.launched`. Both are set synchronously
    /// on `@MainActor`, so a concurrent reload can't interleave between the decision and the guard.
    ///
    /// The spawn itself is *not* synchronous — it awaits the resolved PATH — so `launchWorkflowAgent`
    /// re-checks `isLaunchCurrent` before creating the surface. See its docstring.
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
        let launch = beginLaunch(slug: slug, forWorktree: worktree.id)
        let command = workflowAgentCommand(for: definition, action: action)
        if let launcher = workflowAgentLauncher {
            launcher(prompt, command, worktree, app)
        } else {
            launchWorkflowAgent(prompt: prompt, command: command, launch: launch, in: worktree, app: app)
        }
        return nextValue == nil ? .ended(slug: slug) : .launched(slug: slug)
    }

    /// Launches an action's agent in `worktree` via `buildAgentPromptCommand` (positional prompt
    /// arg → Ghostty surface). `command` is already resolved (workflow override or Main Terminal).
    /// Deliberately does **not** attach the legacy activity/stall observers (which mutate `status`
    /// to `in_progress`/`done`) — under the JSON engine the agent owns every `status` advance, so
    /// the engine must never write status other than the initial seed. The surface is still tracked
    /// for teardown/`isAgentSurface`.
    ///
    /// Awaiting the resolved PATH suspends between `performLaunch` setting the guard and the surface
    /// existing, so `isLaunchCurrent` is re-read on resume: a manual status pick
    /// (`setWorkflowStatus`), a manual kill, or a fresh launch landing in that window abandons this
    /// one. Without it the superseded agent would still spawn — untracked, since the steering path
    /// already ran its teardown — and its eventual status write would halt the loop.
    @MainActor
    private func launchWorkflowAgent(
        prompt: String,
        command: String,
        launch: WorkflowLaunchID,
        in worktree: Worktree,
        app: ghostty_app_t
    ) {
        Task { @MainActor in
            let agent = buildAgentPromptCommand(
                agentCommand: command,
                prompt: prompt,
                path: await ShellEnvironment.awaitPath(),
                filePrefix: "clearway-workflow-prompt"
            )
            guard isLaunchCurrent(launch, forWorktree: worktree.id) else {
                try? FileManager.default.removeItem(atPath: agent.promptFile)
                Ghostty.logger.info(
                    "Workflow agent launch abandoned worktree=\(worktree.id, privacy: .public) action=\(launch.slug, privacy: .public)"
                )
                return
            }
            let surface = terminalManager.launchAgentTab(for: worktree, app: app, command: agent.command)
            setAgentSurface(surface, forWorktree: worktree.id)
            agentSurfaceIdentities[worktree.id, default: []].insert(ObjectIdentifier(surface))
            launchPromptFiles[ObjectIdentifier(surface)] = agent.promptFile
            let surfaceId = ObjectIdentifier(surface).debugDescription
            Ghostty.logger.info(
                "Workflow agent launched worktree=\(worktree.id, privacy: .public) agent=\(command, privacy: .public)"
            )
            Ghostty.logger.info(
                "Workflow agent promptFile=\(agent.promptFile, privacy: .public) surface=\(surfaceId, privacy: .public)"
            )
        }
    }
}
