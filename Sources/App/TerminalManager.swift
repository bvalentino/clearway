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
    func pane(for worktree: Worktree, app: ghostty_app_t) -> TerminalPane {
        let key = worktree.id
        if let existing = panes[key] {
            return existing
        }

        let main = Ghostty.SurfaceView(app)
        let secondary = Ghostty.SurfaceView(app)
        let side = Ghostty.SurfaceView(app)

        let tp = TerminalPane(main: main, secondary: secondary, side: side)
        panes[key] = tp

        // Send cd to the worktree path after a short delay to let the shell initialize
        if let path = worktree.path {
            let cdCommand = "cd \(shellEscape(path))\n"
            let sideCommand = "cd \(shellEscape(path)) && wtpad\n"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                for surface in [main, secondary] {
                    surface.sendText(cdCommand)
                }
                side.sendText(sideCommand)
            }
        }

        return tp
    }

    /// Switch to a worktree's terminal.
    @discardableResult
    func activate(_ worktree: Worktree, app: ghostty_app_t) -> TerminalPane {
        let tp = pane(for: worktree, app: app)
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
