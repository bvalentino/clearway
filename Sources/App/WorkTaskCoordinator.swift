import Foundation
import GhosttyKit

/// Coordinates starting a task: resolving or creating its worktree and relocating its `TASK.md`
/// into it. Extracted from ContentView to keep the view focused on layout and navigation.
@MainActor
class WorkTaskCoordinator: ObservableObject {
    var pendingLaunch: (id: UUID, branch: String)?

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

    func startTask(_ task: WorkTask, app: ghostty_app_t) -> StartResult {
        // Content authority is disk/pool by id — never the UI-captured snapshot (pre-plan
        // title/body would otherwise clobber a completed Plan write on the bookkeeping save).
        guard let current = workTaskManager.freshTask(id: task.id) else { return .ignored }
        guard current.status == WorkTask.ReservedStatus.new
                || current.status == WorkTask.ReservedStatus.readyToStart
                || current.status == WorkTask.ReservedStatus.canceled else { return .ignored }

        // Starting a task creates (or focuses) its worktree. Clearway launches no agent of its own.
        // Branch-keyed lookup resolves the correct worktree even when HEAD is detached (e.g. mid-rebase).
        if let branch = current.worktree,
           let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) {
            return .reuse(wt)
        }
        // No live worktree yet → create it (reusing a prior branch link if present). `pendingLaunch`
        // is set so `completePendingLaunch` relocates TASK.md into the worktree.
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
        pendingLaunch = (id: current.id, branch: branch)
        return .createWorktree(branch)
    }

    /// If a task launch was pending for this branch, relocates its TASK.md into the now-live worktree.
    func completePendingLaunch(branch: String, worktree: Worktree) {
        guard let pending = pendingLaunch, pending.branch == branch,
              let task = workTaskManager.tasks.first(where: { $0.id == pending.id }) else { return }
        pendingLaunch = nil

        if let path = worktree.path {
            workTaskManager.relocateTaskToWorktree(id: task.id, worktreePath: path)
        }
    }

    func worktreeForTask(_ task: WorkTask) -> Worktree? {
        guard let branch = task.worktree else { return nil }
        return worktreeManager.worktrees.first(where: { $0.branch == branch })
    }
}

extension WorkTaskCoordinator {
    /// Creates a hidden shadow task for `branch` if none exists — no-op for task-initiated
    /// worktrees, whose exposed task already links the branch.
    func ensureShadowTask(forBranch branch: String) {
        guard workTaskManager.task(forWorktree: branch) == nil else { return }
        workTaskManager.createShadowTask(forBranch: branch)
    }
}
