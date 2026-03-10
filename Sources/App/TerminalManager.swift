import AppKit
import GhosttyKit

/// Escape a path for safe use in a shell command.
func shellEscape(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The three terminal panes for a worktree.
struct TerminalPane {
    var main: Ghostty.SurfaceView
    var secondary: Ghostty.SurfaceView
    var side: Ghostty.SurfaceView
}

/// Manages per-worktree terminal surfaces.
///
/// Each worktree gets three `Ghostty.SurfaceView` instances (main, secondary,
/// side) that persist for the lifetime of the session. Switching worktrees
/// shows/hides surfaces rather than creating new ones.
@MainActor
class TerminalManager: ObservableObject {
    /// All live instances, tracked via weak references for app-level queries.
    static let allInstances = NSHashTable<TerminalManager>.weakObjects()

    private var panes: [String: TerminalPane] = [:]
    private var app: ghostty_app_t?
    private var closeSurfaceObserver: Any?
    private var recentRestarts: [String: [Date]] = [:]
    @Published var activeSurfaceId: String?
    @Published private(set) var notifiedWorktrees: Set<String> = []
    /// Worktree IDs that have active terminal panes. Must stay in sync with
    /// `panes.keys` — all pane mutations should go through `removeSurface` or `closeWorktree`.
    @Published private(set) var openWorktreeIds: Set<String> = []
    private var notificationObserver: Any?

    /// Per-worktree panel visibility (defaults to true when absent).
    @Published private var sideVisible: [String: Bool] = [:]
    @Published private var secondaryVisible: [String: Bool] = [:]

    var activePane: TerminalPane? {
        guard let id = activeSurfaceId else { return nil }
        return panes[id]
    }

    init() {
        TerminalManager.allInstances.add(self)

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDesktopNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let surface = notification.object as? Ghostty.SurfaceView else { return }
            self.handleDesktopNotification(from: surface)
        }

        closeSurfaceObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyCloseSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let deadSurface = notification.object as? Ghostty.SurfaceView,
                  let processAlive = notification.userInfo?[GhosttyNotificationKey.processAlive] as? Bool,
                  !processAlive else { return }
            Task { @MainActor [weak self] in
                self?.replaceSurface(deadSurface)
            }
        }
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = closeSurfaceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Explicitly close all terminal surfaces, sending SIGHUP to their shells.
    ///
    /// Called during app termination to ensure graceful cleanup before the
    /// process exits. Removes the close-surface observer first to prevent
    /// the restart logic from firing during teardown.
    func closeAllSurfaces() {
        if let observer = closeSurfaceObserver {
            NotificationCenter.default.removeObserver(observer)
            closeSurfaceObserver = nil
        }
        for surface in allSurfaces {
            surface.closeSurface()
        }
    }

    private func handleDesktopNotification(from surface: Ghostty.SurfaceView) {
        guard let worktreeId = worktreeId(for: surface),
              worktreeId != activeSurfaceId,
              !notifiedWorktrees.contains(worktreeId) else { return }
        notifiedWorktrees.insert(worktreeId)
    }

    /// Find the worktree ID that owns the given surface.
    private func worktreeId(for surface: Ghostty.SurfaceView) -> String? {
        panes.first(where: { _, pane in
            pane.main === surface || pane.secondary === surface || pane.side === surface
        })?.key
    }

    func clearNotification(for worktreeId: String) {
        notifiedWorktrees.remove(worktreeId)
    }

    // MARK: - Panel Visibility

    func isSideVisible(for worktreeId: String?) -> Bool {
        guard let worktreeId else { return true }
        return sideVisible[worktreeId] ?? true
    }

    func isSecondaryVisible(for worktreeId: String?) -> Bool {
        guard let worktreeId else { return true }
        return secondaryVisible[worktreeId] ?? true
    }

    func toggleSide(for worktreeId: String?) {
        guard let worktreeId else { return }
        sideVisible[worktreeId] = !(sideVisible[worktreeId] ?? true)
    }

    func toggleSecondary(for worktreeId: String?) {
        guard let worktreeId else { return }
        secondaryVisible[worktreeId] = !(secondaryVisible[worktreeId] ?? true)
    }
    /// Get or create terminal panes for the given worktree.
    func pane(for worktree: Worktree, app: ghostty_app_t, projectPath: String?) -> TerminalPane {
        self.app = app

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
        if !openWorktreeIds.contains(key) {
            openWorktreeIds.insert(key)
        }

        // Run startup commands in terminals
        let command = UserDefaults.standard.string(forKey: SettingsKey.mainTerminalCommand) ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !command.isEmpty {
                main.sendCommand(command)
            }
            Self.launchWtpad(in: side)
        }

        return tp
    }

    /// Replace a dead surface with a fresh terminal in the same working directory.
    private func replaceSurface(_ deadSurface: Ghostty.SurfaceView) {
        guard let app else { return }

        for (key, pane) in panes {
            let slot: WritableKeyPath<TerminalPane, Ghostty.SurfaceView>

            if pane.main === deadSurface {
                slot = \.main
            } else if pane.secondary === deadSurface {
                slot = \.secondary
            } else if pane.side === deadSurface {
                slot = \.side
            } else {
                continue
            }

            // Rate-limit per pane: stop if 3+ restarts within the last 2 seconds.
            let now = Date()
            var timestamps = recentRestarts[key, default: []].filter { now.timeIntervalSince($0) < 2 }
            guard timestamps.count < 3 else {
                Ghostty.logger.warning("Terminal restart loop detected, stopping")
                return
            }
            timestamps.append(now)
            recentRestarts[key] = timestamps

            let dir = deadSurface.pwd ?? deadSurface.initialWorkingDirectory
            let newSurface = Ghostty.SurfaceView(app, workingDirectory: dir)
            objectWillChange.send()
            panes[key]![keyPath: slot] = newSurface

            if slot == \.side {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    Self.launchWtpad(in: newSurface)
                }
            }
            return
        }
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
        cleanupState(for: worktreeId)
    }

    /// Whether a worktree has any surface with a running foreground process.
    func worktreeNeedsConfirmClose(_ worktreeId: String) -> Bool {
        guard let pane = panes[worktreeId] else { return false }
        return pane.main.needsConfirmQuit || pane.secondary.needsConfirmQuit || pane.side.needsConfirmQuit
    }

    /// Close a worktree's terminals without deleting the worktree itself.
    ///
    /// Removes the pane entry first so the close-surface observer doesn't
    /// try to restart the dying shells, then sends SIGHUP via `closeSurface()`.
    func closeWorktree(_ worktreeId: String) {
        guard let pane = panes.removeValue(forKey: worktreeId) else { return }
        cleanupState(for: worktreeId)
        pane.main.closeSurface()
        pane.secondary.closeSurface()
        pane.side.closeSurface()
    }

    private func cleanupState(for worktreeId: String) {
        openWorktreeIds.remove(worktreeId)
        notifiedWorktrees.remove(worktreeId)
        recentRestarts.removeValue(forKey: worktreeId)
        sideVisible.removeValue(forKey: worktreeId)
        secondaryVisible.removeValue(forKey: worktreeId)
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

    /// Whether any surface across all managers has a running foreground process.
    static var needsConfirmQuit: Bool {
        allInstances.allObjects.flatMap(\.allSurfaces).contains(where: \.needsConfirmQuit)
    }

    /// Close all surfaces across every live manager.
    static func closeAllManagers() {
        for manager in allInstances.allObjects {
            manager.closeAllSurfaces()
        }
    }

    /// All surfaces across all worktrees.
    var allSurfaces: [Ghostty.SurfaceView] {
        panes.values.flatMap { [$0.main, $0.secondary, $0.side] }
    }

    /// Send the wtpad command to a side terminal surface.
    static func launchWtpad(in surface: Ghostty.SurfaceView) {
        guard WtpadBinary.isInPATH else { return }
        surface.sendCommand("wtpad")
    }
}
