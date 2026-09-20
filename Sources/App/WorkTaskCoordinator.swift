import Foundation

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

    /// A worktree creation this coordinator is waiting on. `taskId` is optional because a
    /// hand-made worktree carries no task, and `command` is the agent command to run once the
    /// worktree is live.
    struct PendingCreate: Equatable {
        let taskId: UUID?
        let branch: String
        let command: SavedCommand?
    }

    var pendingCreate: PendingCreate?

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
    func confirmCreate(taskId: UUID?, branch: String, command: SavedCommand?) {
        if let taskId {
            workTaskManager.updateFields(id: taskId) { updated in
                if updated.status == WorkTask.ReservedStatus.canceled {
                    updated.attempt = (updated.attempt ?? 0) + 1
                }
                updated.status = WorkTask.ReservedStatus.inProgress
                updated.worktree = branch
            }
        }
        pendingCreate = PendingCreate(taskId: taskId, branch: branch, command: command)
    }

    /// Consumes the pending create for this branch: relocates the task's TASK.md into the now-live
    /// worktree and returns the command to run there, with `{{ task_path }}` resolved to the
    /// relocated file. A pending create carrying no task leaves the token verbatim — there is no
    /// path to name (D6).
    @discardableResult
    func completePendingCreate(branch: String, worktree: Worktree) -> SavedCommand? {
        guard let pending = pendingCreate, pending.branch == branch else { return nil }
        pendingCreate = nil

        var taskPath: String?
        if let taskId = pending.taskId,
           workTaskManager.tasks.contains(where: { $0.id == taskId }),
           let path = worktree.path {
            workTaskManager.relocateTaskToWorktree(id: taskId, worktreePath: path)
            taskPath = WorkTaskManager.taskMarkdownPath(inWorktree: path)
        }

        guard let command = pending.command else { return nil }
        return CommandPlaceholders.substituted(command, taskPath: taskPath)
    }

    /// The command Plan would run for this task: `{{ task_path }}` resolved to wherever the task
    /// currently lives, which `filePath(for:)` already decides. Split out of `planTask` because
    /// that one needs a `ghostty_app_t` XCTest cannot produce.
    func planCommand(for task: WorkTask, using command: SavedCommand) -> SavedCommand? {
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
