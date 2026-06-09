import SwiftUI

/// Worktree-toolbar play/pause control for the `WORKFLOW.json` loop engine.
///
/// Visibility and state derive entirely from observed model state, so the button reacts to
/// `TASK.md` reloads and engine launches without any local `@State`:
/// - **Hidden** unless the project has a valid `.clearway/WORKFLOW.json` (Success Criterion #5/#7).
///   Legacy `WORKFLOW.md` projects show no button and are byte-for-byte unchanged.
/// - **Play glyph** when the worktree's loop is paused (`autopilot == false`); **pause glyph**
///   when live (`autopilot == true`). A missing `autopilot` (not yet seeded) reads as paused.
/// - **Activity indicator** in place of the glyph while a step is actually running — derived from
///   the coordinator's read-only `isAgentRunning(forWorktree:)`, which never leaks mutable engine
///   state into the view. While running, the accessibility label/value/help shift to a third state
///   ("Autopilot running") so VoiceOver reflects the in-flight step.
///
/// Clicking is the primary write: Clearway flips the `autopilot` field in `.clearway/TASK.md` via
/// `WorkTaskManager.setAutopilot`. The established watcher flip path (`handleAutopilotFlip`) then
/// enacts the intent — enable resumes the current action, disable pauses after the running step
/// finishes. The view adds no second launch path.
///
/// A **context-menu "Stop Agent"** item (shown only while a step is running) is the lone exception:
/// it invokes the coordinator's `manualKill`, which pauses *and* terminates the running agent
/// surface. This is the spec's manual kill — the one affordance that interrupts a running agent,
/// kept distinct from the pause toggle that lets the in-flight step finish.
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

    /// A step is mid-run when the engine has a live agent / running action for this worktree.
    private var isRunning: Bool { workTaskCoordinator.isAgentRunning(forWorktree: worktree.id) }

    var body: some View {
        // Gate on a valid WORKFLOW.json — projects without one render nothing at all. Reads the
        // coordinator's cached, reactive flag (no per-render filesystem parse; shows/hides when the
        // file is added/removed).
        if workTaskCoordinator.isWorkflowJSONProject {
            Button(action: toggle) {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isLive ? "pause.fill" : "play.fill")
                }
            }
            .help(helpText)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .contextMenu {
                // Manual kill — the only affordance that interrupts a running agent (distinct from
                // the pause toggle, which lets the running step finish). Shown only while a step is
                // mid-run, since there is nothing to terminate otherwise.
                if isRunning {
                    Button("Stop Agent", role: .destructive, action: manualKill)
                }
            }
        }
    }

    /// Three-state accessibility/help strings so VoiceOver reflects a running step — not just the
    /// paused/live glyph. Running takes precedence over `isLive` because the ProgressView replaces
    /// the glyph while a step is in flight.
    private var accessibilityLabel: String {
        if isRunning { return "Autopilot running" }
        return isLive ? "Pause autopilot" : "Start autopilot"
    }

    private var accessibilityValue: String {
        if isRunning { return "Step in progress" }
        return isLive ? "Active" : "Paused"
    }

    private var helpText: String {
        if isRunning { return "Autopilot step running…" }
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
