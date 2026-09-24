import AppKit

extension TerminalManager {
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
