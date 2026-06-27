import Foundation

/// The agent-driven loop engine for `WORKFLOW.json` projects.
///
/// The heart of the feature is `decideTransition` — a **pure, side-effect-free** function that,
/// given the action currently running (`P`), the `status` value just written to `TASK.md` (`S`),
/// and the parsed `WorkflowDefinition`, decides what the engine should do next. Keeping it pure
/// means the routing/validation contract is unit-testable without file watchers or Ghostty; the
/// stateful launch plumbing lives in `WorkTaskCoordinator` and feeds its inputs through here.
enum WorkflowLoopEngine {

    /// The decision a `TASK.md` `status` change resolves to. The engine never guesses: a value it
    /// can't legally reach from the running action `halt`s and surfaces rather than launching.
    enum Transition: Equatable {
        /// Launch the action `slug`. `nextValue` is the single legal next `status` value to inject
        /// into the agent's prompt (the advance contract), or `nil` when `slug` is terminal — a
        /// terminal action runs once and no advance is injected.
        case launch(slug: String, nextValue: String?)

        /// Nothing to do: the written status equals the running action (a mid-step body edit) or is
        /// a backlog marker that isn't the engine's concern.
        case ignore

        /// The written status can't be reached from the running action (an illegal route while a
        /// step is running, or an unknown slug). The caller surfaces `reason` and stops the loop.
        case halt(reason: String)

        /// A terminal action's agent signaled a deliberate finish (`completed: true` on a routeless
        /// action). The caller ends the loop — pauses autopilot, launches nothing. Honored only when
        /// `written` is terminal; a stray `completed` elsewhere falls through to normal routing, so a
        /// misbehaving agent can't end the loop early.
        case complete(slug: String)
    }

    /// Decides the engine's response to a `status` value written to `TASK.md`.
    ///
    /// - Parameters:
    ///   - running: The action currently running in the worktree (`P`), or `nil` before the first
    ///     launch (right after the `start` seed, or after a halt/restart with nothing running).
    ///   - written: The `status` value just read from `TASK.md` (`S`).
    ///   - autopilot: Whether the worktree's loop is live. `false` = paused: a step that resolves to
    ///     a launch is suppressed (`.ignore`) — the running agent finishes, but the engine never
    ///     advances. Halts and no-op ignores are unaffected (a paused loop still surfaces an illegal
    ///     write). `nil` is treated as on (a JSON-workflow worktree seeds `true`; this guards the
    ///     theoretical case of a missing flag rather than silently pausing). This is the single
    ///     source of truth for the pause gate — the coordinator never re-decides it.
    ///   - completed: The task's `completed` flag — `true` only when a terminal action's agent
    ///     deliberately signaled it is done. Defaults to `nil` (the common routing case); when set,
    ///     it resolves to `.complete` on a terminal action ahead of any routing.
    ///   - definition: The project's parsed, validated `WorkflowDefinition`.
    /// - Returns: The `Transition` the caller should act on. Pure — no I/O, no mutation.
    static func decideTransition(
        running: String?,
        written: String,
        autopilot: Bool?,
        completed: Bool? = nil,
        definition: WorkflowDefinition
    ) -> Transition {
        let decision = routeTransition(running: running, written: written, completed: completed, definition: definition)
        // Pause gate: a paused worktree (`autopilot == false`) never launches. A `.launch` is
        // demoted to `.ignore` — the running step finishes, nothing new starts. `.ignore`/`.halt`/
        // `.complete` pass through so a paused loop still no-ops on its own status, still surfaces an
        // illegal write, and still ends on a completed terminal action. `nil`/`true` launches normally.
        if autopilot == false, case .launch = decision {
            return .ignore
        }
        return decision
    }

    /// The autopilot-independent routing/validation decision. Pure — separated from the pause gate
    /// so `decideTransition` can layer autopilot on top while this stays the one place that knows
    /// the graph rules (S == P, backlog markers, unknown slug, idle-launches-any-action, and route
    /// validation only while a step is running).
    private static func routeTransition(
        running: String?,
        written: String,
        completed: Bool?,
        definition: WorkflowDefinition
    ) -> Transition {
        // 0. Completion: a terminal action's agent wrote `completed: true` — the deliberate finish
        //    signal. End the loop ahead of any routing (the S == P step would otherwise ignore the
        //    terminal action re-writing its own status). Honored only on a terminal action; a stray
        //    `completed` on a non-terminal action falls through and routes normally.
        if completed == true, definition.isTerminal(written) {
            return .complete(slug: written)
        }

        // 1. S == P: the running action re-wrote its own status (or a mid-step body edit
        //    re-triggered the watcher). Nothing advances.
        if let running, written == running {
            return .ignore
        }

        // 2. Backlog markers are pre-worktree and never the engine's concern.
        if written == WorkTask.ReservedStatus.new || written == WorkTask.ReservedStatus.readyToStart {
            return .ignore
        }

        // 3. S must resolve to a real action. A value matching no action is a typo/hallucination —
        //    halt rather than guess.
        guard definition.actions[written] != nil else {
            return .halt(reason: "Unknown action '\(written)' is not defined in WORKFLOW.json.")
        }

        // 4. Nothing running: there's no active step to validate an advance against, so launch
        //    whatever real action `written` names (step 3 already proved it resolves; step 2 peeled
        //    off backlog markers). This covers the seed's `start`, a resume, and a **manual status
        //    pick** — none is a hallucinated advance to guard against. Route validation (step 5)
        //    applies only while a step is actively running, which is the case that matters.
        guard let running else {
            return launchTransition(for: written, definition: definition)
        }

        // 5. Advancing from a running action: S must be a legal route out of P.
        if definition.legalNext(from: running).contains(written) {
            return launchTransition(for: written, definition: definition)
        }

        return .halt(reason: "Status '\(written)' is not a legal next step from '\(running)'.")
    }

    /// Builds the `.launch` transition for `slug`, computing the single legal next value to inject
    /// (or `nil` when terminal).
    private static func launchTransition(for slug: String, definition: WorkflowDefinition) -> Transition {
        .launch(slug: slug, nextValue: legalNextValue(from: slug, definition: definition))
    }

    /// The single `status` value to inject into `slug`'s prompt as the advance contract, or `nil`
    /// when `slug` is terminal (routeless). v1 routing is action→action, so a non-terminal action
    /// has exactly one legal next value; if multiple are present (a future branch) the deterministic
    /// (sorted-first) one is taken so the contract stays single-valued. Shared by the pure decision
    /// and the coordinator's resume path so both inject the identical value.
    static func legalNextValue(from slug: String, definition: WorkflowDefinition) -> String? {
        if definition.isTerminal(slug) { return nil }
        return definition.legalNext(from: slug).first   // legalNext is already sorted (deterministic)
    }

    // MARK: - Prompt injection

    /// Builds the agent prompt for an action launch: a **Clearway context preamble** prepended to the
    /// action's own `instructions`, which land last so the actual work gets the highest-recency
    /// emphasis. The preamble is an explicitly delimited, labeled block — a `Context:` label closed by
    /// a `---` thematic break — so the agent can tell unambiguously where the context ends and its task
    /// begins. It leads with the label, never a `---` fence, so the block can't be mistaken for the
    /// YAML frontmatter the prompt is delivered as — the very construct fact #2 tells the agent to
    /// ignore.
    ///
    /// It carries exactly three facts the engine owns, not the action author: where the task lives
    /// (`.clearway/TASK.md`), that the TASK.md YAML frontmatter is Clearway's bookkeeping rather than
    /// agent instructions, and the status/completion signal to write *as the last thing done*. The
    /// signal varies by action: a non-terminal action (`nextValue != nil`) gets the **advance**
    /// contract — the next `status` value; a **terminal** action (`nextValue == nil`) gets the
    /// **completion** contract — `completed: true` — the deliberate finish signal the engine ends the
    /// loop on.
    ///
    /// Routing authority stays in `WORKFLOW.json`: a non-terminal agent can only write the value
    /// Clearway handed it (validated by `decideTransition`); a terminal agent only signals it is done.
    static func buildPrompt(instructions: String, nextValue: String?) -> String {
        let signal = nextValue.map { "set the `status:` field in the task's frontmatter to `\($0)`" }
            ?? "set `completed: true` in the task's frontmatter"
        let preamble = """
        Context:
        - The task in progress is .clearway/TASK.md.
        - The YAML frontmatter of the task is internal data not relevant to you. Only use it when needing to update it.
        - When done, \(signal) as the last thing you do.

        ---
        """
        return "\(preamble)\n\n\(instructions)"
    }
}
