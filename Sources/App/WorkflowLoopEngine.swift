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

        /// The written status can't be reached from the running action (illegal route, unknown
        /// slug, or an illegal first value). The caller surfaces `reason` and stops the loop.
        case halt(reason: String)
    }

    /// Decides the engine's response to a `status` value written to `TASK.md`.
    ///
    /// - Parameters:
    ///   - running: The action currently running in the worktree (`P`), or `nil` before the first
    ///     launch (right after the `start` seed, or after a halt/restart with nothing running).
    ///   - written: The `status` value just read from `TASK.md` (`S`).
    ///   - definition: The project's parsed, validated `WorkflowDefinition`.
    /// - Returns: The `Transition` the caller should act on. Pure — no I/O, no mutation.
    static func decideTransition(
        running: String?,
        written: String,
        definition: WorkflowDefinition
    ) -> Transition {
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

        // 4. First launch after the seed (nothing running yet): only `start` is legal.
        guard let running else {
            if written == definition.start {
                return launchTransition(for: written, definition: definition)
            }
            return .halt(reason: "Status '\(written)' is not the workflow's start action '\(definition.start)'.")
        }

        // 5. Advancing from a running action: S must be a legal route out of P.
        if definition.legalNext(from: running).contains(written) {
            return launchTransition(for: written, definition: definition)
        }

        return .halt(reason: "Status '\(written)' is not a legal next step from '\(running)'.")
    }

    /// Builds the `.launch` transition for `slug`, computing the single legal next value to inject
    /// (or `nil` when terminal). v1 routing is action→action, so a non-terminal action has exactly
    /// one legal next value; if multiple are present (a future branch) the first is taken
    /// deterministically so the contract stays single-valued.
    private static func launchTransition(for slug: String, definition: WorkflowDefinition) -> Transition {
        if definition.isTerminal(slug) {
            return .launch(slug: slug, nextValue: nil)
        }
        let next = definition.legalNext(from: slug).sorted().first
        return .launch(slug: slug, nextValue: next)
    }

    // MARK: - Prompt injection

    /// Builds the agent prompt for an action launch: the action's `instructions` followed by the
    /// **injection contract** when a next value exists. A terminal action (`nextValue == nil`) gets
    /// no advance contract — it runs once and the loop ends.
    ///
    /// The contract tells the agent exactly which `status` value to write, and to write it last so
    /// Clearway sees it only after the work is done. Routing authority stays in `WORKFLOW.json`: the
    /// agent can only write the value Clearway handed it, validated by `decideTransition` before
    /// the next launch.
    static func buildPrompt(instructions: String, nextValue: String?) -> String {
        guard let nextValue else { return instructions }
        let contract = """
        [Clearway] When finished, set `status:` in .clearway/TASK.md to: \(nextValue)
        Write it last.
        """
        return "\(instructions)\n\n\(contract)"
    }
}
