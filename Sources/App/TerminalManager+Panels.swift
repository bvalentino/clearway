import AppKit
import GhosttyKit

extension TerminalManager {
    // MARK: - Secondary Hook Run

    /// Run a post-create hook inside the worktree's persistent secondary login shell,
    /// forcing the secondary panel visible.
    ///
    /// Reuses `pane.secondary` (never discarded or respawned) instead of a throwaway
    /// surface, so the hook's output survives to a live, usable prompt. The command is
    /// fed via `sendPaste` — it echoes on the prompt line, an accepted cosmetic tradeoff,
    /// and preserves multi-line hooks (a single `sendCommand` would drop everything after
    /// the first newline). The send is deferred a tick to clear the cold-pane login-shell
    /// startup race (mirrors `HookTerminalView.onAppear`).
    func runHookInSecondary(for worktree: Worktree, app: ghostty_app_t, command: String, projectPath: String?) {
        let pane = pane(for: worktree, app: app, projectPath: projectPath)
        secondaryVisible[worktree.id] = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pane.secondary.sendPaste(command)
        }
    }

    // MARK: - Panel Visibility

    func isAsideVisible(for worktreeId: String?) -> Bool {
        guard let worktreeId else { return false }
        return asideVisible[worktreeId] ?? false
    }

    func isSecondaryVisible(for worktreeId: String?) -> Bool {
        guard let worktreeId else { return false }
        return secondaryVisible[worktreeId] ?? false
    }

    func toggleAside(for worktreeId: String?) {
        guard let worktreeId else { return }
        asideVisible[worktreeId] = !(asideVisible[worktreeId] ?? false)
    }

    func toggleSecondary(for worktreeId: String?) {
        guard let worktreeId else { return }
        secondaryVisible[worktreeId] = !(secondaryVisible[worktreeId] ?? false)
    }

    func secondaryHeight(for worktreeId: String?) -> CGFloat {
        guard let worktreeId else { return 120 }
        return secondaryHeights[worktreeId] ?? 120
    }

    func setSecondaryHeight(_ height: CGFloat, for worktreeId: String?) {
        guard let worktreeId else { return }
        guard secondaryHeights[worktreeId] != height else { return }
        secondaryHeights[worktreeId] = height
    }

    // MARK: - Side Panel Tab

    func sidePanelTab(for worktreeId: String) -> String? {
        sidePanelTabs[worktreeId]
    }

    func setSidePanelTab(_ tab: String, for worktreeId: String) {
        guard sidePanelTabs[worktreeId] != tab else { return }
        sidePanelTabs[worktreeId] = tab
    }
}
