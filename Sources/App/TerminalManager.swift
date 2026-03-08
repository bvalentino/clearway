import AppKit
import GhosttyKit

/// Escape a path for safe use in a shell command.
func shellEscape(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The three terminal panes for a worktree.
struct TerminalPane {
    let main: Ghostty.SurfaceView
    let secondary: Ghostty.SurfaceView
    let side: Ghostty.SurfaceView
}

/// Manages per-worktree terminal surfaces.
///
/// Each worktree gets three `Ghostty.SurfaceView` instances (main, secondary,
/// side) that persist for the lifetime of the session. Switching worktrees
/// shows/hides surfaces rather than creating new ones.
@MainActor
class TerminalManager: ObservableObject {
    private var panes: [String: TerminalPane] = [:]
    @Published var activeSurfaceId: String?

    var activePane: TerminalPane? {
        guard let id = activeSurfaceId else { return nil }
        return panes[id]
    }

    /// Get or create terminal panes for the given worktree.
    func pane(for worktree: Worktree, app: ghostty_app_t, projectPath: String?) -> TerminalPane {
        let key = worktree.id
        if let existing = panes[key] {
            return existing
        }

        let dir = worktree.path ?? projectPath
        let main = Ghostty.SurfaceView(app, workingDirectory: dir)
        let secondary = Ghostty.SurfaceView(app, workingDirectory: dir)
        let side = Ghostty.SurfaceView(app, workingDirectory: dir)

        let tp = TerminalPane(main: main, secondary: secondary, side: side)
        panes[key] = tp

        // Run wtpad in the side terminal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            side.sendText("wtpad\n")
        }

        return tp
    }

    /// Switch to a worktree's terminal.
    @discardableResult
    func activate(_ worktree: Worktree, app: ghostty_app_t, projectPath: String?) -> TerminalPane {
        let tp = pane(for: worktree, app: app, projectPath: projectPath)
        activeSurfaceId = worktree.id
        return tp
    }

    /// Remove terminal surfaces when a worktree is deleted.
    func removeSurface(for worktreeId: String) {
        panes.removeValue(forKey: worktreeId)
        if activeSurfaceId == worktreeId {
            activeSurfaceId = nil
        }
    }

    /// Remove surfaces for worktrees that no longer exist.
    func pruneStale(keeping currentIds: Set<String>) {
        for key in panes.keys where !currentIds.contains(key) {
            removeSurface(for: key)
        }
    }

    /// All surfaces across all worktrees.
    var allSurfaces: [Ghostty.SurfaceView] {
        panes.values.flatMap { [$0.main, $0.secondary, $0.side] }
    }
}
