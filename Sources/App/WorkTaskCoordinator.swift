import Foundation
import GhosttyKit

/// Coordinates the task launch workflow: creating worktrees, running hooks,
/// and launching Claude Code. Extracted from ContentView to keep the view
/// focused on layout and navigation.
@MainActor
class WorkTaskCoordinator: ObservableObject {
    var pendingLaunch: (id: UUID, branch: String)?

    private let workTaskManager: WorkTaskManager
    private let terminalManager: TerminalManager
    private let worktreeManager: WorktreeManager

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
        guard task.status == .open else { return .ignored }

        if let branch = task.worktree,
           let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) {
            workTaskManager.setStatus(task, to: .started)
            launchClaudeCode(for: task, in: wt, app: app)
            return .reuse(wt)
        } else {
            let existingBranches = Set(worktreeManager.worktrees.compactMap(\.branch))
            let branch = task.worktree ?? workTaskManager.deriveBranchName(from: task.title, existingBranches: existingBranches)
            var updated = task
            updated.worktree = branch
            updated.status = .started
            workTaskManager.updateTask(updated)
            pendingLaunch = (id: updated.id, branch: branch)
            return .createWorktree(branch)
        }
    }

    /// If a task launch was pending for this branch, returns a closure that launches Claude Code.
    func completePendingLaunch(branch: String, worktree: Worktree, app: ghostty_app_t) -> (() -> Void)? {
        guard let pending = pendingLaunch, pending.branch == branch,
              let task = workTaskManager.tasks.first(where: { $0.id == pending.id }) else { return nil }
        pendingLaunch = nil
        return { [weak self] in
            self?.launchClaudeCode(for: task, in: worktree, app: app)
        }
    }

    func worktreeForTask(_ task: WorkTask) -> Worktree? {
        guard let branch = task.worktree else { return nil }
        return worktreeManager.worktrees.first(where: { $0.branch == branch })
    }

    /// Called when a worktree is removed — resets matching task to open.
    func handleWorktreeRemoved(branch: String) {
        guard let task = workTaskManager.task(forWorktree: branch) else { return }
        var updated = task
        updated.worktree = nil
        updated.status = .open
        workTaskManager.updateTask(updated)
    }

    // MARK: - Private

    private func launchClaudeCode(for task: WorkTask, in worktree: Worktree, app: ghostty_app_t) {
        let taskPath = workTaskManager.filePath(for: task)
        // Pass path as $1 so it never participates in shell parsing
        let command = "/bin/sh -c " + shellEscape("awk '/^---$/{n++;next}n>=2' \"$1\" | claude") + " -- " + shellEscape(taskPath)
        terminalManager.replaceMainSurface(for: worktree, app: app, command: command)
    }
}
