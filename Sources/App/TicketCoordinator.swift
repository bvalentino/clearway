import Foundation
import GhosttyKit

/// Coordinates the ticket launch workflow: creating worktrees, running hooks,
/// and launching Claude Code. Extracted from ContentView to keep the view
/// focused on layout and navigation.
@MainActor
class TicketCoordinator: ObservableObject {
    var pendingLaunch: (id: UUID, branch: String)?

    private let ticketManager: TicketManager
    private let terminalManager: TerminalManager
    private let worktreeManager: WorktreeManager

    init(ticketManager: TicketManager, terminalManager: TerminalManager, worktreeManager: WorktreeManager) {
        self.ticketManager = ticketManager
        self.terminalManager = terminalManager
        self.worktreeManager = worktreeManager
    }

    // MARK: - Actions

    enum StartResult {
        case ignored
        case reuse(Worktree)
        case createWorktree(String)
    }

    func startTicket(_ ticket: Ticket, app: ghostty_app_t) -> StartResult {
        guard ticket.status == .open else { return .ignored }

        if let branch = ticket.worktree,
           let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) {
            ticketManager.setStatus(ticket, to: .started)
            launchClaudeCode(for: ticket, in: wt, app: app)
            return .reuse(wt)
        } else {
            let existingBranches = Set(worktreeManager.worktrees.compactMap(\.branch))
            let branch = ticket.worktree ?? ticketManager.deriveBranchName(from: ticket.title, existingBranches: existingBranches)
            var updated = ticket
            updated.worktree = branch
            updated.status = .started
            ticketManager.updateTicket(updated)
            pendingLaunch = (id: updated.id, branch: branch)
            return .createWorktree(branch)
        }
    }

    /// If a ticket launch was pending for this branch, returns a closure that launches Claude Code.
    func completePendingLaunch(branch: String, worktree: Worktree, app: ghostty_app_t) -> (() -> Void)? {
        guard let pending = pendingLaunch, pending.branch == branch,
              let ticket = ticketManager.tickets.first(where: { $0.id == pending.id }) else { return nil }
        pendingLaunch = nil
        return { [weak self] in
            self?.launchClaudeCode(for: ticket, in: worktree, app: app)
        }
    }

    func worktreeForTicket(_ ticket: Ticket) -> Worktree? {
        guard let branch = ticket.worktree else { return nil }
        return worktreeManager.worktrees.first(where: { $0.branch == branch })
    }

    /// Called when a worktree is removed — resets matching ticket to open.
    func handleWorktreeRemoved(branch: String) {
        guard let ticket = ticketManager.ticket(forWorktree: branch) else { return }
        var updated = ticket
        updated.worktree = nil
        updated.status = .open
        ticketManager.updateTicket(updated)
    }

    // MARK: - Private

    private func launchClaudeCode(for ticket: Ticket, in worktree: Worktree, app: ghostty_app_t) {
        let ticketPath = ticketManager.filePath(for: ticket)
        // Pass path as $1 so it never participates in shell parsing
        let command = "/bin/sh -c " + shellEscape("awk '/^---$/{n++;next}n>=2' \"$1\" | claude") + " -- " + shellEscape(ticketPath)
        terminalManager.replaceMainSurface(for: worktree, app: app, command: command)
    }
}
