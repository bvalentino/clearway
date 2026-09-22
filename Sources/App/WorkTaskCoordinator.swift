import Foundation
import os

/// Coordinates starting a task: resolving or creating its worktree and relocating its `TASK.md`
/// into it. Extracted from ContentView to keep the view focused on layout and navigation.
@MainActor
class WorkTaskCoordinator: ObservableObject {

    /// What the Start Task sheet opens with. The branch is resolved here rather than in the view
    /// so `deriveBranchName` stays beside the rest of the task logic.
    struct StartPrefill: Equatable, Identifiable {
        let taskId: UUID
        let title: String
        let branch: String

        var id: UUID { taskId }
    }

    /// A worktree creation this coordinator is waiting on. `command` is the agent command to run
    /// once the worktree is live.
    struct PendingCreate: Equatable {
        /// The task this create links, carrying the three system-managed fields `confirmCreate`
        /// overwrote as they read before it did — one value rather than two optionals, so a link
        /// `abandonPendingCreate` cannot unwind is unrepresentable.
        struct TaskLink: Equatable {
            let id: UUID
            let priorStatus: String
            let priorWorktree: String?
            let priorAttempt: Int?
        }

        /// `nil` for a hand-made worktree, which has no task to link or unwind.
        let task: TaskLink?
        let branch: String
        let command: SavedCommand?
    }

    /// Set only by `confirmCreate`, which is the one place a well-formed record can be built:
    /// the record carries an obligation to unwind, so it must not be assignable from outside.
    private(set) var pendingCreate: PendingCreate?

    // MARK: - Dependencies

    let workTaskManager: WorkTaskManager
    let terminalManager: TerminalManager
    let worktreeManager: WorktreeManager

    init(workTaskManager: WorkTaskManager, terminalManager: TerminalManager, worktreeManager: WorktreeManager) {
        self.workTaskManager = workTaskManager
        self.terminalManager = terminalManager
        self.worktreeManager = worktreeManager
    }

    // MARK: - Actions

    enum StartResult {
        case ignored
        case reuse(Worktree)
        case prefill(StartPrefill)
    }

    /// Start Now. Resolves what the task would start as and writes nothing: the frontmatter write
    /// belongs to Create, so a sheet the user cancels leaves the task on its backlog marker.
    func resolveStart(_ task: WorkTask) -> StartResult {
        // Content authority is disk/pool by id — never the UI-captured snapshot (a stale title/body
        // would otherwise clobber whatever the task terminal just wrote, on the bookkeeping save).
        guard let current = workTaskManager.freshTask(id: task.id) else { return .ignored }
        guard current.status == WorkTask.ReservedStatus.new
                || current.status == WorkTask.ReservedStatus.canceled else { return .ignored }

        // Starting a task creates (or focuses) its worktree. Clearway launches no agent of its own.
        // Branch-keyed lookup resolves the correct worktree even when HEAD is detached (e.g. mid-rebase).
        if let branch = current.worktree,
           let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) {
            return .reuse(wt)
        }
        let existingBranches = Set(worktreeManager.worktrees.compactMap(\.branch))
        let branch = current.worktree
            ?? workTaskManager.deriveBranchName(from: current.title, existingBranches: existingBranches)
        return .prefill(StartPrefill(taskId: current.id, title: current.title, branch: branch))
    }

    /// The Create button on either presentation of the worktree sheet. Links the task to the branch
    /// the operator confirmed and records the pending create so `completePendingCreate` can relocate
    /// TASK.md and run the command once the worktree is live. A hand-made worktree passes no task id
    /// and so writes no task file.
    ///
    /// It also closes the promoted task's bottom terminal. The link written here takes the task out
    /// of `backlogTasks`, which is the only renderer of `taskPhases`, so an agent left running there
    /// would light no dot anywhere.
    func confirmCreate(taskId: UUID?, branch: String, command: SavedCommand?) {
        var link: PendingCreate.TaskLink?
        if let taskId {
            let written = workTaskManager.updateFields(id: taskId) { updated in
                link = PendingCreate.TaskLink(
                    id: taskId,
                    priorStatus: updated.status,
                    priorWorktree: updated.worktree,
                    priorAttempt: updated.attempt
                )
                if updated.status == WorkTask.ReservedStatus.canceled {
                    updated.attempt = (updated.attempt ?? 0) + 1
                }
                updated.status = WorkTask.ReservedStatus.inProgress
                updated.worktree = branch
            }
            // The task's file can disappear between Start Now and Create — another window's
            // Delete, a `git pull`. The worktree the operator confirmed is still created, but
            // nothing was written, so there is nothing to unwind and nothing to relocate: a link
            // recorded here would claim a write that never landed.
            if written == nil {
                link = nil
                Ghostty.logger.error(
                    "confirmCreate: task \(taskId, privacy: .public) no longer exists; creating \(branch, privacy: .public) unlinked")
            }
            terminalManager.closeTaskTerminal(taskId)
        }
        pendingCreate = PendingCreate(task: link, branch: branch, command: command)
    }

    /// Unwinds a create that never happened. `confirmCreate` writes the frontmatter before
    /// `git worktree add` runs, so a failed create would otherwise leave the task on `in_progress`
    /// naming a branch with no worktree — a state `resolveStart` refuses, making the task
    /// unstartable from the UI.
    func abandonPendingCreate() {
        guard let pending = pendingCreate else { return }
        pendingCreate = nil
        guard let task = pending.task else { return }
        let restored = workTaskManager.updateFields(id: task.id) { updated in
            updated.status = task.priorStatus
            updated.worktree = task.priorWorktree
            updated.attempt = task.priorAttempt
        }
        if restored == nil {
            Ghostty.logger.error(
                "abandonPendingCreate: task \(task.id, privacy: .public) no longer exists; its start marker stands")
        }
    }

    /// Consumes the pending create for this branch: relocates the task's TASK.md into the now-live
    /// worktree and returns the command to run there, with `{{ task_path }}` resolved to the
    /// relocated file. A pending create carrying no task leaves the token verbatim — there is no
    /// path to name (D6).
    ///
    /// The path comes from the relocation reporting that it landed, never from the destination
    /// being where the file was *meant* to go: `relocateTaskToWorktree` refuses a worktree that
    /// already carries a `TASK.md`, which a branch can, since `.clearway` is committed. Naming the
    /// destination regardless would hand the agent a different task's brief.
    @discardableResult
    func completePendingCreate(branch: String, worktree: Worktree) -> SavedCommand? {
        guard let pending = pendingCreate, pending.branch == branch else { return nil }
        pendingCreate = nil

        var taskPath: String?
        if let task = pending.task, let path = worktree.path,
           workTaskManager.relocateTaskToWorktree(id: task.id, worktreePath: path) {
            taskPath = WorkTaskManager.taskMarkdownPath(inWorktree: path)
        }

        guard let command = pending.command else { return nil }
        return CommandPlaceholders.substituted(command, taskPath: taskPath)
    }

    /// Whether a successful create should clear the Tasks selection: the started task's file moves
    /// into the new worktree and so leaves the backlog, and a selection still naming it leaves the
    /// toolbar acting on a task that is no longer there. A hand-made create, or a create for some
    /// other task, leaves the selection alone.
    static func startedTaskIsSelected(
        _ pending: PendingCreate?, branch: String, selectedTaskId: UUID?
    ) -> Bool {
        guard let pending, let taskId = pending.task?.id else { return false }
        return pending.branch == branch && taskId == selectedTaskId
    }

    /// The command Plan would run for this task: `{{ task_path }}` resolved to wherever the task
    /// currently lives, which `filePath(for:)` already decides. Split out of `planTask` because
    /// that one needs a `ghostty_app_t` XCTest cannot produce.
    ///
    /// Only an `.agent` command means anything to a plan run: `TerminalManager.run` drops a
    /// terminal-kind one on its own `guard case .agent`, by which point `planTask` has claimed the
    /// task's launch slot and posted `taskTerminalOpened` — which flips the editor to preview over
    /// whatever surface the task terminal already held, while nothing runs. The kind check precedes
    /// `freshTask` because the refusal is a property of the command alone, and a caller that passed
    /// the wrong kind should be told so even when the task cannot resolve.
    func planCommand(for task: WorkTask, using command: SavedCommand) -> SavedCommand? {
        guard command.kind == .agent else {
            Ghostty.logger.error(
                "planCommand: command \(command.id, privacy: .public) is \(command.kind.rawValue, privacy: .public)-kind; only an agent command can plan a task")
            return nil
        }
        guard let current = workTaskManager.freshTask(id: task.id) else { return nil }
        return CommandPlaceholders.substituted(command, taskPath: workTaskManager.filePath(for: current))
    }

    /// Where a plan run's agent starts: the primary worktree, which is where a backlog task's file
    /// still lives. `projectPath` is the fallback rather than a second convention — the worktree
    /// list is empty until the first `git worktree list` returns, and a plan run before then must
    /// still land somewhere, not silently do nothing.
    static func planWorkingDirectory(worktrees: [Worktree], projectPath: String) -> String {
        worktrees.first(where: \.isMain)?.path ?? projectPath
    }

    func worktreeForTask(_ task: WorkTask) -> Worktree? {
        guard let branch = task.worktree else { return nil }
        return worktreeManager.worktrees.first(where: { $0.branch == branch })
    }
}
