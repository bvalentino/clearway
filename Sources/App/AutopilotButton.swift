import SwiftUI

/// Full-width play/pause row for the `WORKFLOW.json` loop engine, pinned below the task aside's
/// workflow step cards.
///
/// State derives entirely from observed model state, so the row reacts to `TASK.md` reloads and
/// engine launches without any local `@State`:
/// - **Pause glyph** with `Autopilot: Enabled` when the worktree's loop is live (`autopilot == true`);
///   **play glyph** with `Autopilot: Disabled` when it is paused. A missing `autopilot` (not yet
///   seeded) reads as paused. The glyph reflects `autopilot` *directly* — there is no spinner state,
///   because the agent's Ghostty terminal persists after a step finishes, so an activity indicator
///   would never clear.
/// - **Disabled** when the worktree's task has no content (`WorkTask.hasContent` false), or is a
///   hidden shadow with no current step (no task associated — the engine ignores it, so there is
///   nothing to start), and no agent surface is live. A live agent keeps the row enabled so pause
///   stays reachable.
///
/// The call site already gates on a valid `.clearway/WORKFLOW.json` and a non-main worktree (the
/// aside's Task tab is dropped on main), so the row carries no gate of its own.
///
/// Clicking is the only write: Clearway flips the `autopilot` field in `.clearway/TASK.md` via
/// `WorkTaskManager.setAutopilot`. The established watcher flip path (`handleAutopilotFlip`) then
/// enacts the intent — enable resumes the current action, disable pauses after the running step
/// finishes. The view adds no second launch path, and offers no way to interrupt a running agent:
/// Ctrl-C in the agent's terminal or closing its tab does that, and auto-pauses the loop.
struct AutopilotButton: View {
    let worktreeBranch: String
    let worktreeId: String

    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator

    private static let cornerRadius: CGFloat = 12

    /// The task backing this worktree, the source of the `autopilot` flag.
    private var task: WorkTask? {
        workTaskManager.task(forWorktree: worktreeBranch)
    }

    /// The loop is live when its task explicitly opts in; absent/false reads as paused.
    private var isLive: Bool { task?.autopilot == true }

    /// Whether a live agent surface is tracked for this worktree. NOT a "step in progress" signal —
    /// the agent's Ghostty terminal persists after a step finishes, so this stays true across the
    /// whole loop. Used only to keep the row enabled, never to drive the glyph (which reflects
    /// `autopilot`).
    private var hasLiveAgent: Bool { workTaskCoordinator.isAgentRunning(forWorktree: worktreeId) }

    /// Whether the task has anything for an agent to act on. Autopilot is pointless against a blank
    /// `TASK.md` (e.g. a freshly-created manual worktree), so the row is disabled until it does.
    private var hasContent: Bool { task?.hasContent ?? false }

    /// A hidden shadow sitting on no action is a worktree with no task associated: `advanceWorkflow`
    /// ignores it, so play has nothing to start. A step card's Set Current gives it a real action and
    /// the control comes back.
    private var isUnassociated: Bool {
        task?.hidden == true && workTaskCoordinator.currentWorkflowStep(forWorktree: worktreeId) == nil
    }

    /// Why autopilot can't run here, or `nil` when it can. A live agent overrides both reasons so
    /// pause stays reachable mid-step. The single source for both the disabled state and the copy
    /// that explains it — deriving them separately let an enabled row announce itself unavailable.
    private enum Unavailable {
        case unassociated
        case empty
    }

    private var unavailable: Unavailable? {
        guard !hasLiveAgent else { return nil }
        if isUnassociated { return .unassociated }
        if !hasContent { return .empty }
        return nil
    }

    private var isDisabled: Bool { unavailable != nil }

    var body: some View {
        // The glyph reflects `autopilot` directly: pause when live, play when paused. (No spinner —
        // the agent surface persists, so an "activity" indicator off `hasLiveAgent` would never clear
        // and would mask the play/pause state the user acts on.)
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: isLive ? "pause.fill" : "play.fill")
                Text(label)
                    .font(.headline)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(.thickMaterial)
        )
        .disabled(isDisabled)
        .help(helpText)
        .accessibilityLabel(label)
        .accessibilityHint(isLive ? "Pauses autopilot" : "Starts autopilot")
        .accessibilityValue(accessibilityValue)
    }

    /// The row's visible text, reused verbatim as its accessibility label: a control whose
    /// accessible name omits its own visible words is unreachable by name in Voice Control. The
    /// *action* lives in the hint, which is why the label states the state rather than the verb.
    private var label: String {
        isLive ? "Autopilot: Enabled" : "Autopilot: Disabled"
    }

    /// Only the unavailable reasons — the label already carries enabled/disabled, so restating it
    /// here would just double it in the announcement.
    private var accessibilityValue: String {
        switch unavailable {
        case .unassociated: return "Unavailable — create a task for this worktree first"
        case .empty: return "Unavailable — add a task description first"
        case nil: return ""
        }
    }

    private var helpText: String {
        switch unavailable {
        case .unassociated: return "Create a task for this worktree to enable autopilot"
        case .empty: return "Add a task description to enable autopilot"
        case nil:
            return isLive
                ? "Autopilot runs each workflow step automatically. Pausing lets the running step finish; nothing new starts."
                : "Autopilot runs each workflow step automatically, advancing when the agent finishes."
        }
    }

    /// Writes the toggled `autopilot` flag; the watcher flip path enacts resume/pause. No-op when
    /// the worktree has no task yet (nothing to write to).
    private func toggle() {
        guard let task else { return }
        workTaskManager.setAutopilot(task, to: !isLive)
    }
}
