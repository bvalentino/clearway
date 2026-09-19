import Foundation

/// Coordinates starting a task: resolving or creating its worktree and relocating its `TASK.md`
/// into it. Extracted from ContentView to keep the view focused on layout and navigation.
@MainActor
class WorkTaskCoordinator: ObservableObject {

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
        case createWorktree(String)
    }

    func startTask(_ task: WorkTask) -> StartResult {
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
        // No live worktree yet → create it (reusing a prior branch link if present). `pendingCreate`
        // is set so `completePendingCreate` relocates TASK.md into the worktree.
        let existingBranches = Set(worktreeManager.worktrees.compactMap(\.branch))
        let branch = current.worktree
            ?? workTaskManager.deriveBranchName(from: current.title, existingBranches: existingBranches)
        let written = workTaskManager.updateFields(id: current.id) { updated in
            if updated.status == WorkTask.ReservedStatus.canceled {
                updated.attempt = (updated.attempt ?? 0) + 1
            }
            updated.status = WorkTask.ReservedStatus.inProgress
            updated.worktree = branch
        }
        guard written != nil else { return .ignored }
        pendingCreate = PendingCreate(taskId: current.id, branch: branch, command: nil)
        return .createWorktree(branch)
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

    func worktreeForTask(_ task: WorkTask) -> Worktree? {
        guard let branch = task.worktree else { return nil }
        return worktreeManager.worktrees.first(where: { $0.branch == branch })
    }
}
