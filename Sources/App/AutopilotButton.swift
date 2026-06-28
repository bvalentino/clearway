import SwiftUI

/// Worktree-toolbar play/pause control for the `WORKFLOW.json` loop engine.
///
/// Visibility and state derive entirely from observed model state, so the button reacts to
/// `TASK.md` reloads and engine launches without any local `@State`:
/// - **Hidden** unless the project has a valid `.clearway/WORKFLOW.json` (Success Criterion #5/#7).
///   Legacy `WORKFLOW.md` projects show no button and are byte-for-byte unchanged.
/// - **Play glyph** when the worktree's loop is paused (`autopilot == false`); **pause glyph**
///   when live (`autopilot == true`). A missing `autopilot` (not yet seeded) reads as paused. The
///   glyph reflects `autopilot` *directly* — there is no spinner state, because the agent's Ghostty
///   terminal persists after a step finishes, so an activity indicator would never clear.
/// - **Disabled** when the worktree's task has no content (`WorkTask.hasContent` false) and no agent
///   surface is live — there is nothing for an agent to do against a blank `TASK.md`, so autopilot
///   can't be toggled on until the user adds a title/body. A live agent keeps the control enabled so
///   pause / Stop Agent stay reachable.
///
/// Clicking is the primary write: Clearway flips the `autopilot` field in `.clearway/TASK.md` via
/// `WorkTaskManager.setAutopilot`. The established watcher flip path (`handleAutopilotFlip`) then
/// enacts the intent — enable resumes the current action, disable pauses after the running step
/// finishes. The view adds no second launch path.
///
/// A **context-menu "Stop Agent"** item (shown only while a step is running) is the lone *pause*
/// exception: it invokes the coordinator's `manualKill`, which pauses *and* terminates the running
/// agent surface — kept distinct from the pause toggle that lets the in-flight step finish. (A manual
/// status pick in the aside also terminates a running agent, but it *steers* the loop rather than
/// pausing it, so it isn't surfaced here.)
struct AutopilotButton: View {
    let worktree: Worktree

    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator

    /// The task backing this worktree, the source of the `autopilot` flag.
    private var task: WorkTask? {
        guard let branch = worktree.branch else { return nil }
        return workTaskManager.task(forWorktree: branch)
    }

    /// The loop is live when its task explicitly opts in; absent/false reads as paused.
    private var isLive: Bool { task?.autopilot == true }

    /// Whether a live agent surface is tracked for this worktree. NOT a "step in progress" signal —
    /// the agent's Ghostty terminal persists after a step finishes, so this stays true across the
    /// whole loop. Used only to offer "Stop Agent" and to keep the control enabled, never to drive
    /// the glyph (which reflects `autopilot`).
    private var hasLiveAgent: Bool { workTaskCoordinator.isAgentRunning(forWorktree: worktree.id) }

    /// Whether the task has anything for an agent to act on. Autopilot is pointless against a blank
    /// `TASK.md` (e.g. a freshly-created manual worktree), so the button is disabled until it does.
    private var hasContent: Bool { task?.hasContent ?? false }

    /// Disabled when there's nothing to run — no task content and no live agent. A live agent keeps
    /// the control reachable so pause / Stop Agent stay available.
    private var isDisabled: Bool { !hasContent && !hasLiveAgent }

    var body: some View {
        // Gate on a valid WORKFLOW.json — projects without one render nothing at all. Reads the
        // coordinator's cached, reactive flag (no per-render filesystem parse; shows/hides when the
        // file is added/removed). The main branch never drives a workflow loop, so the control is
        // hidden there too even when the project has a WORKFLOW.json.
        if workTaskCoordinator.isWorkflowJSONProject && !worktree.isMain {
            // The glyph reflects `autopilot` directly: pause when live, play when paused. (No spinner
            // — the agent surface persists, so an "activity" indicator off `hasLiveAgent` would never
            // clear and would mask the play/pause state the user acts on.)
            Button(action: toggle) {
                Image(systemName: isLive ? "pause.fill" : "play.fill")
            }
            .disabled(isDisabled)
            .help(helpText)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .contextMenu {
                // Manual kill — the pause-and-interrupt affordance (distinct from the pause toggle,
                // which lets the running step finish; a manual status pick also interrupts, but steers
                // rather than pauses). Shown only while an agent surface is live, since there is
                // nothing to terminate otherwise.
                if hasLiveAgent {
                    Button("Stop Agent", role: .destructive, action: manualKill)
                }
            }
        }
    }

    private var accessibilityLabel: String {
        isLive ? "Pause autopilot" : "Start autopilot"
    }

    private var accessibilityValue: String {
        if !hasContent { return "Unavailable — add a task description first" }
        return isLive ? "Active" : "Paused"
    }

    private var helpText: String {
        if !hasContent { return "Add a task description to enable autopilot" }
        return isLive ? "Pause autopilot" : "Start autopilot"
    }

    /// Writes the toggled `autopilot` flag; the watcher flip path enacts resume/pause. No-op when
    /// the worktree has no task yet (nothing to write to).
    private func toggle() {
        guard let task else { return }
        workTaskManager.setAutopilot(task, to: !isLive)
    }

    /// Pauses the loop and terminates the running agent surface — the manual kill. Unlike `toggle`,
    /// this interrupts the in-flight step rather than letting it finish.
    private func manualKill() {
        guard let branch = worktree.branch else { return }
        workTaskCoordinator.manualKill(forBranch: branch)
    }
}
