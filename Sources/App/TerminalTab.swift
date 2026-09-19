import AppKit

/// Escape a path for safe use in a shell command (single-quote wrapping for programmatic
/// command-building). For injecting text at the cursor in a live terminal, use `Ghostty.Shell.escape`.
func shellEscape(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A single tab in the main terminal panel.
struct TerminalTab {
    let id: UUID
    let surface: Ghostty.SurfaceView
}

/// The collection of tabs shown in the main terminal panel for a worktree.
struct MainTerminal {
    var tabs: [TerminalTab]
    var activeId: UUID?

    /// The currently active tab, or nil if none.
    var activeTab: TerminalTab? {
        guard let activeId else { return nil }
        return tabs.first(where: { $0.id == activeId })
    }

    /// The surface of the currently active tab, or nil if there is no active tab.
    var activeSurface: Ghostty.SurfaceView? {
        activeTab?.surface
    }

    /// Whether any tab in this terminal holds the given surface.
    func contains(_ surface: Ghostty.SurfaceView) -> Bool {
        tabs.contains(where: { $0.surface === surface })
    }

    /// The index of the tab with the given id, or nil if not found.
    func index(of id: UUID) -> Int? {
        tabs.firstIndex(where: { $0.id == id })
    }
}

/// The terminal panes for a worktree.
struct TerminalPane {
    var main: MainTerminal
    var secondary: Ghostty.SurfaceView
}
