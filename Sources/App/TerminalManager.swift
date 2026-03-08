import AppKit
import GhosttyKit

/// Escape a path for safe use in a shell command.
func shellEscape(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Manages per-worktree terminal surfaces.
///
/// Each worktree gets its own `Ghostty.SurfaceView` that persists for the
/// lifetime of the session. Switching worktrees shows/hides surfaces rather
/// than creating new ones.
@MainActor
class TerminalManager: ObservableObject {
    private var surfaces: [String: Ghostty.SurfaceView] = [:]
    @Published var activeSurfaceId: String?

    var activeSurface: Ghostty.SurfaceView? {
        guard let id = activeSurfaceId else { return nil }
        return surfaces[id]
    }

    /// Get or create a terminal surface for the given worktree.
    func surface(for worktree: Worktree, app: ghostty_app_t) -> Ghostty.SurfaceView {
        let key = worktree.id
        if let existing = surfaces[key] {
            return existing
        }

        let view = Ghostty.SurfaceView(app)
        surfaces[key] = view

        // Send cd to the worktree path after a short delay to let the shell initialize
        if let path = worktree.path {
            let command = "cd \(shellEscape(path)) && clear\n"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                view.sendText(command)
            }
        }

        return view
    }

    /// Switch to a worktree's terminal.
    func activate(_ worktree: Worktree, app: ghostty_app_t) -> Ghostty.SurfaceView {
        let view = surface(for: worktree, app: app)
        activeSurfaceId = worktree.id
        return view
    }

    /// Remove a terminal surface when a worktree is deleted.
    func removeSurface(for worktreeId: String) {
        surfaces.removeValue(forKey: worktreeId)
        if activeSurfaceId == worktreeId {
            activeSurfaceId = nil
        }
    }

    /// Remove surfaces for worktrees that no longer exist.
    func pruneStale(keeping currentIds: Set<String>) {
        for key in surfaces.keys where !currentIds.contains(key) {
            removeSurface(for: key)
        }
    }
}
