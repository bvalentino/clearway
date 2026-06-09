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
        guard hasJSONWorkflow(), let app = appProvider() else { return }
        for branch in branches {
            let resumed = handleAutopilotFlip(forBranch: branch, app: app)
            // The resume already drove a launch decision; advancing again on the same reload would
            // re-evaluate the now-running action (a harmless ignore), so skip the redundant call.
            guard !resumed else { continue }
            if case .needsTrust = advanceWorkflow(forBranch: branch, app: app) {
                surfaceNeedsTrust(forBranch: branch)
            }
        }
    }

    /// Rebuilds the watch-set on app/project startup: enumerates the project's live worktrees, reads
    /// each one's persisted `TASK.md` (`status` + `autopilot`), and relaunches the matching action —
    /// **only** for worktrees `WorkflowLoopEngine.shouldResumeOnRestart` deems resumable (autopilot on,
    /// status on a real non-terminal action). A paused, halted, terminal, backlog, or unknown-slug
    /// worktree stays put. No-op for projects without a valid `.clearway/WORKFLOW.json`.
    ///
    /// Idempotent: `relaunchCurrentAction` skips a worktree whose action is already running, so a
    /// double startup (or a reload firing right after) never double-launches. Reads the already-merged
    /// task pool (the manager loads every worktree's `TASK.md`) rather than re-shelling `git worktree
    /// list`, reusing existing plumbing while honoring the "enumerate worktrees" contract.
    @MainActor
    func resumeWorkflowsOnStartup() {
        // Run once per window, and only once the worktree set has loaded — an empty set means
        // worktrees haven't arrived yet (the caller retries on the next lifecycle tick). Leaving the
        // guard unset until then lets a later call with a real set do the work.
        guard !didResumeWorkflows, !worktreeManager.worktrees.isEmpty else { return }
        guard let definition = try? WorkflowDefinition.load(projectPath: workTaskManager.projectPath),
              let app = appProvider() else { return }
        didResumeWorkflows = true
        for worktree in worktreeManager.worktrees {
            guard let branch = worktree.branch,
                  let task = workTaskManager.task(forWorktree: branch) else { continue }
            // Seed the flip baseline so the first post-resume reload doesn't read a false→true edge.
            if let autopilot = task.autopilot { lastKnownAutopilot[branch] = autopilot }
            guard WorkflowLoopEngine.shouldResumeOnRestart(
                status: task.status, autopilot: task.autopilot, definition: definition
            ) else { continue }
            if case .needsTrust = relaunchCurrentAction(forBranch: branch, app: app) {
                surfaceNeedsTrust(forBranch: branch)
            }
        }
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
        if case .needsTrust = relaunchCurrentAction(forBranch: branch, app: app) {
            surfaceNeedsTrust(forBranch: branch)
        }
        return true
    }

    /// The worktree id (path) for a branch, or `nil` when no live worktree matches.
    @MainActor
    private func worktreeId(forBranch branch: String) -> String? {
        worktreeManager.worktrees.first(where: { $0.branch == branch })?.id
    }

    /// Surfaces a stalled-on-trust loop the same way a halt surfaces its reason: writes a diagnosable
    /// `errorMessage` onto the task so the dead loop is visible. Does **not** auto-trust and — unlike
    /// the seed — never writes a `status` value, keeping the "engine writes status only for seed"
    /// invariant intact. Idempotent: skips the write if the message is already set.
    @MainActor
    private func surfaceNeedsTrust(forBranch branch: String) {
        let message = "Workflow paused: .clearway/WORKFLOW.json is not trusted. Approve it to run."
        guard var task = workTaskManager.task(forWorktree: branch),
              task.errorMessage != message else { return }
        task.errorMessage = message
        workTaskManager.updateTask(task)
    }

    // MARK: - WORKFLOW.json Loop Engine

    /// Whether the project is driven by the new agent-driven loop engine — true only when a
    /// **valid** `.clearway/WORKFLOW.json` is present. Projects without one keep the legacy
    /// `WORKFLOW.md` path entirely unchanged, so every engine entry point gates on this.
    @MainActor
    func hasJSONWorkflow() -> Bool {
        WorkflowDefinition.hasJSONWorkflow(projectPath: workTaskManager.projectPath)
    }

    /// Marks the current `.clearway/WORKFLOW.json` as trusted for this project, so its
    /// `agent.command` / `hooks` may execute. Mirrors `approveTrust()` for the legacy path.
    @MainActor
    func approveJSONWorkflowTrust() {
        WorkflowDefinition.markTrusted(projectPath: workTaskManager.projectPath)
    }

    /// Test/restart seam: sets the in-memory running action (`P`) for a worktree directly, without a
    /// launch. Phase 3's restart-resume rebuilds this from disk; tests use it to stage a mid-loop
    /// state. The worktree id (its path) is the key, matching how `advanceWorkflow` reads `P`.
    @MainActor
    func setRunningActionForTesting(_ slug: String, branch: String, worktreePath: String) {
        let worktreeId = Worktree(branch: branch, path: worktreePath, isMain: false, headStatus: .attached).id
        runningAction[worktreeId] = slug
    }

    /// The outcome of feeding a `TASK.md` change through the loop engine.
    enum WorkflowAdvanceResult: Equatable {
        case launched(slug: String)
        case ignored
        case ended(slug: String)
        case halted(reason: String)
        /// The `.clearway/WORKFLOW.json` carries executable config that the user hasn't approved.
        /// The caller surfaces this (it does **not** execute) and may call `approveJSONWorkflowTrust()`.
        case needsTrust
    }

    /// Seeds a freshly created worktree's `TASK.md` with the workflow's `start` slug — the engine's
    /// **only** write to `status` — and defaults `autopilot` to `true` in the same write (a valid
    /// `WORKFLOW.json` project gets autopilot on by default). No-op for projects without a valid
    /// `.clearway/WORKFLOW.json`, so legacy projects keep no autopilot field and are untouched.
    /// Idempotent: only seeds when the task isn't already sitting on the start action (e.g. a
    /// re-created or resumed worktree keeps its place) — but still backfills `autopilot` if absent,
    /// so a worktree that already sits on `start` (from a prior write) still gains the default flag.
    @MainActor
    func seedWorkflowStatus(forBranch branch: String) {
        guard let definition = try? WorkflowDefinition.load(projectPath: workTaskManager.projectPath),
              var task = workTaskManager.task(forWorktree: branch),
              task.status != definition.start || task.autopilot == nil else { return }
        task.status = definition.start
        // Default autopilot on for a JSON-workflow project — written alongside the seed as a single
        // coherent creation write. Only set when absent so a user's prior pause isn't clobbered.
        if task.autopilot == nil { task.autopilot = true }
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
    /// on an illegal/unknown value, or ignores a no-op. Gated end-to-end on a valid, **trusted**
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
    /// injected next value the same way a launch would. Idempotent and trust-gated. No-op if the
    /// loop is halted, the status isn't a real action, or that action is already running.
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

    /// Shared launch tail for `advanceWorkflow` and `relaunchCurrentAction`: trust-gates, builds the
    /// prompt, sets the idempotency guard (`runningAction`), and spawns the agent surface. Returns
    /// `.needsTrust` (surfaced, never run) when unapproved; `.ended` for a terminal action, else
    /// `.launched`. `runningAction` is set immediately before `launchWorkflowAgent` with no `await`
    /// between them — the method is synchronous on `@MainActor`, so guard+launch are one atomic step.
    @MainActor
    private func performLaunch(
        slug: String,
        nextValue: String?,
        in worktree: Worktree,
        definition: WorkflowDefinition,
        app: ghostty_app_t
    ) -> WorkflowAdvanceResult {
        // Resolve everything that can early-return BEFORE any state mutation, so the only thing
        // left to do after `runningAction` is set is the launch itself.
        guard let action = definition.actions[slug] else { return .ignored }
        // Executable config — gate on trust before launching anything. Surface, never run silently.
        // Untrusted returns without setting `runningAction` or launching.
        guard WorkflowDefinition.isTrusted(projectPath: workTaskManager.projectPath) else {
            return .needsTrust
        }
        let prompt = WorkflowLoopEngine.buildPrompt(instructions: action.instructions, nextValue: nextValue)
        runningAction[worktree.id] = slug
        launchWorkflowAgent(prompt: prompt, command: definition.agent.command, in: worktree, app: app)
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
