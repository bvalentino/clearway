import AppKit

/// Escape a path for safe use in a shell command (single-quote wrapping for programmatic
/// command-building). For injecting text at the cursor in a live terminal, use `Ghostty.Shell.escape`.
func shellEscape(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Merge new text onto an existing launcher draft. Used by prompt/task/todo play buttons
/// so repeated clicks stack up rather than clobbering what's already there.
/// - Empty existing → new text becomes the draft.
/// - Existing ends with newline(s) → append new text directly (no extra separator).
/// - Otherwise insert a single newline between existing and new text.
func appendingToDraft(existing: String, _ text: String) -> String {
    guard !existing.isEmpty else { return text }
    if existing.last == "\n" { return existing + text }
    return existing + "\n" + text
}

/// A single tab in the main terminal panel.
struct TerminalTab {
    /// Launcher tabs hold no running process — they render the Prompt Launcher form.
    /// Surface tabs host a live `Ghostty.SurfaceView`.
    enum Kind {
        case launcher
        case surface(Ghostty.SurfaceView)
    }

    let id: UUID
    var kind: Kind

    /// The live surface for this tab, or nil if the tab is a launcher.
    var surface: Ghostty.SurfaceView? {
        if case .surface(let s) = kind { return s }
        return nil
    }

    var isLauncher: Bool {
        if case .launcher = kind { return true }
        return false
    }
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

    /// The surface of the currently active tab, or nil if none (or if it's a launcher).
    var activeSurface: Ghostty.SurfaceView? {
        activeTab?.surface
    }

    /// Whether there is an active tab (launcher or surface) that can receive
    /// `sendToActiveMainTab` — launcher tabs accept text as a draft prefill.
    var hasActiveTab: Bool { activeTab != nil }

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
