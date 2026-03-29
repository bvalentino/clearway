import AppKit
import GhosttyKit

/// Escape a path for safe use in a shell command.
func shellEscape(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The terminal panes for a worktree.
struct TerminalPane {
    var main: Ghostty.SurfaceView
    var secondary: Ghostty.SurfaceView
}

/// Manages per-worktree terminal surfaces.
///
/// Each worktree gets two `Ghostty.SurfaceView` instances (main, secondary)
/// that persist for the lifetime of the session. Switching worktrees
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
    @Published private var asideVisible: [String: Bool] = [:]
    @Published private var secondaryVisible: [String: Bool] = [:]

    // MARK: - Task Terminals

    /// Per-task terminal surfaces (one per task, keyed by task UUID).
    private var taskSurfaces: [UUID: Ghostty.SurfaceView] = [:]
    /// Task IDs that have an active terminal surface.
    @Published private(set) var openTaskIds: Set<UUID> = []
    /// Per-task terminal panel visibility.
    @Published private var taskTerminalVisible: [UUID: Bool] = [:]

    /// Per-worktree active side panel tab (stored as raw string to avoid coupling to view enum).
    private var sidePanelTabs: [String: String] = [:]

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
        taskSurfaces.removeAll()
        openTaskIds.removeAll()
        taskTerminalVisible.removeAll()
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
            pane.main === surface || pane.secondary === surface
        })?.key
    }

    func clearNotification(for worktreeId: String) {
        notifiedWorktrees.remove(worktreeId)
    }

    // MARK: - Panel Visibility

    func isAsideVisible(for worktreeId: String?) -> Bool {
        guard let worktreeId else { return true }
        return asideVisible[worktreeId] ?? true
    }

    func isSecondaryVisible(for worktreeId: String?) -> Bool {
        guard let worktreeId else { return true }
        return secondaryVisible[worktreeId] ?? true
    }

    func toggleAside(for worktreeId: String?) {
        guard let worktreeId else { return }
        asideVisible[worktreeId] = !(asideVisible[worktreeId] ?? true)
    }

    func toggleSecondary(for worktreeId: String?) {
        guard let worktreeId else { return }
        secondaryVisible[worktreeId] = !(secondaryVisible[worktreeId] ?? true)
    }

    // MARK: - Side Panel Tab

    func sidePanelTab(for worktreeId: String) -> String? {
        sidePanelTabs[worktreeId]
    }

    func setSidePanelTab(_ tab: String, for worktreeId: String) {
        guard sidePanelTabs[worktreeId] != tab else { return }
        sidePanelTabs[worktreeId] = tab
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

        let tp = TerminalPane(main: main, secondary: secondary)
        panes[key] = tp
        if !openWorktreeIds.contains(key) {
            openWorktreeIds.insert(key)
        }

        // Run startup command in main terminal
        let command = UserDefaults.standard.string(forKey: SettingsKey.mainTerminalCommand) ?? ""
        if !command.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                main.sendCommand(command)
            }
        }

        return tp
    }

    /// Replace the main surface for a worktree with one running the given command.
    /// Used to launch Claude Code in a task's worktree.
    /// Returns the new surface.
    @discardableResult
    func replaceMainSurface(for worktree: Worktree, app: ghostty_app_t, command: String) -> Ghostty.SurfaceView {
        let key = worktree.id
        let newSurface = Ghostty.SurfaceView(app, workingDirectory: worktree.path, command: command)
        if var pane = panes.removeValue(forKey: key) {
            let oldSurface = pane.main
            pane.main = newSurface
            panes[key] = pane
            objectWillChange.send()
            // Close after re-inserting so the closeSurface observer can't match the old surface
            oldSurface.closeSurface()
        } else {
            // Pane doesn't exist yet (e.g. activate() hasn't fired due to SwiftUI batching).
            // Create the pane now so the surface isn't lost.
            self.app = app
            let dir = worktree.path
            let secondary = Ghostty.SurfaceView(app, workingDirectory: dir)
            panes[key] = TerminalPane(main: newSurface, secondary: secondary)
            if !openWorktreeIds.contains(key) {
                openWorktreeIds.insert(key)
            }
            objectWillChange.send()
        }
        return newSurface
    }

    /// Surfaces that should not be auto-restarted when they exit.
    /// Set by WorkTaskCoordinator for agent command surfaces.
    var skipAutoRestart: ((Ghostty.SurfaceView) -> Bool)?

    /// Replace a dead surface with a fresh terminal in the same working directory.
    private func replaceSurface(_ deadSurface: Ghostty.SurfaceView) {
        guard let app else { return }

        // Don't auto-restart agent surfaces
        if let skip = skipAutoRestart, skip(deadSurface) { return }

        // Task terminals: remove instead of restarting
        if let tid = taskId(for: deadSurface) {
            taskSurfaces.removeValue(forKey: tid)
            openTaskIds.remove(tid)
            taskTerminalVisible.removeValue(forKey: tid)
            return
        }

        for (key, pane) in panes {
            let slot: WritableKeyPath<TerminalPane, Ghostty.SurfaceView>

            if pane.main === deadSurface {
                slot = \.main
            } else if pane.secondary === deadSurface {
                slot = \.secondary
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
        return pane.main.needsConfirmQuit || pane.secondary.needsConfirmQuit
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
    }

    private func cleanupState(for worktreeId: String) {
        openWorktreeIds.remove(worktreeId)
        notifiedWorktrees.remove(worktreeId)
        recentRestarts.removeValue(forKey: worktreeId)
        asideVisible.removeValue(forKey: worktreeId)
        secondaryVisible.removeValue(forKey: worktreeId)
        sidePanelTabs.removeValue(forKey: worktreeId)
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

    // MARK: - Task Terminal Methods

    /// Look up an existing task terminal surface (read-only).
    func existingTaskSurface(for taskId: UUID) -> Ghostty.SurfaceView? {
        taskSurfaces[taskId]
    }

    /// Whether a task's terminal has a running foreground process.
    func taskHasActiveProcess(_ taskId: UUID) -> Bool {
        taskSurfaces[taskId]?.needsConfirmQuit ?? false
    }

    /// Get or create a terminal surface for a task.
    @discardableResult
    func taskSurface(for taskId: UUID, app: ghostty_app_t, projectPath: String?) -> Ghostty.SurfaceView {
        self.app = app
        if let existing = taskSurfaces[taskId] {
            return existing
        }
        let surface = Ghostty.SurfaceView(app, workingDirectory: projectPath)
        taskSurfaces[taskId] = surface
        if !openTaskIds.contains(taskId) {
            openTaskIds.insert(taskId)
        }
        return surface
    }

    /// Whether a task's terminal panel is visible.
    func isTaskTerminalVisible(for taskId: UUID) -> Bool {
        taskTerminalVisible[taskId] ?? false
    }

    /// Toggle a task's terminal panel visibility. Creates the surface on first show.
    func toggleTaskTerminal(for taskId: UUID, app: ghostty_app_t, projectPath: String?) {
        let isVisible = taskTerminalVisible[taskId] ?? false
        if !isVisible { taskSurface(for: taskId, app: app, projectPath: projectPath) }
        taskTerminalVisible[taskId] = !isVisible
    }

    /// Close a task's terminal surface. Removes entry first to prevent auto-restart.
    func closeTaskTerminal(_ taskId: UUID) {
        guard let surface = taskSurfaces.removeValue(forKey: taskId) else { return }
        openTaskIds.remove(taskId)
        taskTerminalVisible.removeValue(forKey: taskId)
        surface.closeSurface()
    }

    /// Open a task terminal that runs the given command directly (no login shell).
    /// Replaces any existing task surface for the same task.
    func openTaskTerminalWithCommand(for taskId: UUID, app: ghostty_app_t, projectPath: String?, command: String) {
        self.app = app
        // Close existing surface if any
        if let old = taskSurfaces.removeValue(forKey: taskId) {
            old.closeSurface()
        }
        let surface = Ghostty.SurfaceView(app, workingDirectory: projectPath, command: command)
        taskSurfaces[taskId] = surface
        openTaskIds.insert(taskId)
        taskTerminalVisible[taskId] = true
    }

    /// Find the task ID that owns the given surface.
    private func taskId(for surface: Ghostty.SurfaceView) -> UUID? {
        taskSurfaces.first(where: { $0.value === surface })?.key
    }

    /// All surfaces across all worktrees and tasks.
    var allSurfaces: [Ghostty.SurfaceView] {
        panes.values.flatMap { [$0.main, $0.secondary] } + taskSurfaces.values
    }

}
