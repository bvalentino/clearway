import AppKit
import GhosttyKit

/// Escape a path for safe use in a shell command.
func shellEscape(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A single tab in the main terminal panel.
struct TerminalTab {
    let id: UUID
    var surface: Ghostty.SurfaceView
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

    /// The surface of the currently active tab, or nil if none.
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
    @Published private(set) var openWorktreeIds: [String] = []
    private var notificationObserver: Any?

    /// Per-worktree panel visibility (defaults to false when absent).
    @Published private var asideVisible: [String: Bool] = [:]
    @Published private var secondaryVisible: [String: Bool] = [:]
    /// Per-worktree secondary terminal panel height.
    @Published private var secondaryHeights: [String: CGFloat] = [:]

    // MARK: - Task Terminals

    /// Per-task terminal surfaces (one per task, keyed by task UUID).
    private var taskSurfaces: [UUID: Ghostty.SurfaceView] = [:]
    /// Task IDs that have an active terminal surface.
    @Published private(set) var openTaskIds: Set<UUID> = []
    /// Per-task terminal panel visibility.
    @Published private var taskTerminalVisible: [UUID: Bool] = [:]
    /// Per-task terminal panel height.
    @Published private var taskTerminalHeights: [UUID: CGFloat] = [:]

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
            MainActor.assumeIsolated {
                self.handleDesktopNotification(from: surface)
            }
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
        taskTerminalHeights.removeAll()
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
            pane.main.contains(surface) || pane.secondary === surface
        })?.key
    }

    func clearNotification(for worktreeId: String) {
        notifiedWorktrees.remove(worktreeId)
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

    /// Get or create terminal panes for the given worktree.
    func pane(for worktree: Worktree, app: ghostty_app_t, projectPath: String?) -> TerminalPane {
        self.app = app

        let key = worktree.id
        if let existing = panes[key] {
            return existing
        }

        let dir = worktree.path ?? projectPath
        let mainSurface = Ghostty.SurfaceView(app, workingDirectory: dir)
        let secondary = Ghostty.SurfaceView(app, workingDirectory: dir)

        let initialTab = TerminalTab(id: UUID(), surface: mainSurface)
        let main = MainTerminal(tabs: [initialTab], activeId: initialTab.id)
        let tp = TerminalPane(main: main, secondary: secondary)
        panes[key] = tp
        if !openWorktreeIds.contains(key) {
            openWorktreeIds.append(key)
        }

        if !worktree.isMain {
            asideVisible[key] = true
            secondaryVisible[key] = true
        }

        // Run startup command in main terminal
        let command = UserDefaults.standard.string(forKey: SettingsKey.mainTerminalCommand) ?? ""
        if !command.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                mainSurface.sendCommand(command)
            }
        }

        return tp
    }

    /// Surfaces that should not be auto-restarted when they exit.
    /// Set by WorkTaskCoordinator for agent command surfaces.
    var skipAutoRestart: ((Ghostty.SurfaceView) -> Bool)?

    /// Called when a main tab is closed via `closeMainTab`.
    /// `WorkTaskCoordinator` wires this on setup to clear per-surface bookkeeping.
    /// Use a direct callback (not NotificationCenter) so each window's coordinator
    /// can independently track its own surfaces.
    var onMainTabClosed: ((Ghostty.SurfaceView) -> Void)?

    // MARK: - Main Tab Management

    /// The surface of the currently active worktree's active main tab.
    ///
    /// Sole accessor for "the currently active main surface" — do not add overloads.
    var activeMainSurface: Ghostty.SurfaceView? {
        guard let id = activeSurfaceId else { return nil }
        return panes[id]?.main.activeSurface
    }

    /// The ordered list of main tabs for the given worktree (read-only view for UI).
    func mainTabs(for worktreeId: String) -> [TerminalTab] {
        panes[worktreeId]?.main.tabs ?? []
    }

    /// The active tab ID for the given worktree's main terminal.
    ///
    /// Needed because `MainTerminal` is a struct inside the private `panes` dict —
    /// UI code cannot reach it directly.
    func mainActiveTabId(for worktreeId: String) -> UUID? {
        panes[worktreeId]?.main.activeId
    }

    /// Append a new command tab to the given worktree's main terminal and activate it.
    ///
    /// Creates `Ghostty.SurfaceView(app, workingDirectory: worktree.path, command: command)`
    /// (pattern 2 — no login shell) and appends it as a new `TerminalTab`.
    /// If the pane doesn't exist yet it is created on-the-fly (mirrors `replaceMainSurface` fallback).
    @discardableResult
    func appendMainTab(for worktree: Worktree, app: ghostty_app_t, command: String) -> Ghostty.SurfaceView {
        let key = worktree.id
        let newSurface = Ghostty.SurfaceView(app, workingDirectory: worktree.path, command: command)
        let newTab = TerminalTab(id: UUID(), surface: newSurface)

        if panes[key] != nil {
            panes[key]!.main.tabs.append(newTab)
            panes[key]!.main.activeId = newTab.id
        } else {
            // Pane doesn't exist yet — create on-the-fly (mirrors replaceMainSurface fallback).
            self.app = app
            let dir = worktree.path
            let secondary = Ghostty.SurfaceView(app, workingDirectory: dir)
            let mainTerminal = MainTerminal(tabs: [newTab], activeId: newTab.id)
            panes[key] = TerminalPane(main: mainTerminal, secondary: secondary)
            if !openWorktreeIds.contains(key) {
                openWorktreeIds.append(key)
            }
            if !worktree.isMain {
                asideVisible[key] = true
                secondaryVisible[key] = true
            }
        }

        objectWillChange.send()
        transferFirstResponder(to: newSurface)
        return newSurface
    }

    /// Append a plain shell tab (no command) to the given worktree's main terminal and activate it.
    ///
    /// Uses `Ghostty.SurfaceView(app, workingDirectory:)` (pattern 1 — login shell).
    /// Working directory resolves as: active tab's `pwd` → active tab's `initialWorkingDirectory` →
    /// secondary surface's `initialWorkingDirectory` (worktree root). The secondary fallback
    /// ensures `+` in the zero-tab state opens at the worktree root rather than `$HOME`.
    /// Returns `nil` if the pane does not exist.
    @discardableResult
    func newShellTab(for worktreeId: String, app: ghostty_app_t) -> Ghostty.SurfaceView? {
        guard let pane = panes[worktreeId] else { return nil }
        let activeTab = pane.main.activeTab
        let dir = activeTab?.surface.pwd
            ?? activeTab?.surface.initialWorkingDirectory
            ?? pane.secondary.initialWorkingDirectory
        let newSurface = Ghostty.SurfaceView(app, workingDirectory: dir)
        let newTab = TerminalTab(id: UUID(), surface: newSurface)
        panes[worktreeId]!.main.tabs.append(newTab)
        panes[worktreeId]!.main.activeId = newTab.id
        objectWillChange.send()
        transferFirstResponder(to: newSurface)
        return newSurface
    }

    /// Dispatch a first-responder handoff so keyboard focus follows the newly
    /// active main-tab surface. Matches the pattern used by `activateMainTab` and
    /// the active-tab-closed path so the Cmd+W / Cmd+Shift+[/] monitors (gated
    /// on `firstResponder === activeMainSurface`) see the freshly active surface.
    private func transferFirstResponder(to surface: Ghostty.SurfaceView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            NSApp.keyWindow?.makeFirstResponder(surface)
        }
    }

    /// Close the main tab with the given id within the specified worktree.
    ///
    /// Strict ordering:
    /// 1. Capture the tab by id.
    /// 2. Remove it from `tabs`.
    /// 3. If it was active, activate the nearest neighbor (prev, then next, then nil).
    /// 4. Call `objectWillChange.send()`.
    /// 5. Invoke `onMainTabClosed` with the removed surface.
    /// 6. Call `surface.closeSurface()` — prevents the closeSurface observer from
    ///    seeing a closed surface that is still in `tabs`.
    /// 7. If the closed tab was active and another tab remains, transfer first responder
    ///    to the newly active surface. The Cmd+W / Cmd+Shift+[/] monitors are gated on
    ///    `firstResponder === activeMainSurface`, so without this handoff the shortcuts
    ///    silently stop working until the user clicks back into the terminal.
    func closeMainTab(id: UUID, in worktreeId: String) {
        guard let tabIndex = panes[worktreeId]?.main.tabs.firstIndex(where: { $0.id == id }) else { return }
        let removedTab = panes[worktreeId]!.main.tabs[tabIndex]

        panes[worktreeId]!.main.tabs.remove(at: tabIndex)

        let wasActive = panes[worktreeId]?.main.activeId == id
        var newActiveSurface: Ghostty.SurfaceView?
        if wasActive {
            let remaining = panes[worktreeId]!.main.tabs
            if !remaining.isEmpty {
                // Activate prev if any, else next (which is now at tabIndex after removal)
                let neighborIndex = tabIndex > 0 ? tabIndex - 1 : 0
                panes[worktreeId]!.main.activeId = remaining[neighborIndex].id
                newActiveSurface = remaining[neighborIndex].surface
            } else {
                panes[worktreeId]!.main.activeId = nil
            }
        }

        objectWillChange.send()
        onMainTabClosed?(removedTab.surface)
        removedTab.surface.closeSurface()

        if let newActiveSurface {
            transferFirstResponder(to: newActiveSurface)
        }
    }

    /// Activate the main tab with the given id within the specified worktree.
    ///
    /// Updates `activeId` and dispatches a first-responder transfer after a short delay
    /// so that keyboard focus (required for Cmd+W / Cmd+Shift+[/] monitors) follows
    /// the newly active tab immediately after the SwiftUI update commits.
    func activateMainTab(id: UUID, in worktreeId: String) {
        guard panes[worktreeId]?.main.index(of: id) != nil else { return }
        panes[worktreeId]!.main.activeId = id
        objectWillChange.send()

        if let newSurface = panes[worktreeId]?.main.activeSurface {
            transferFirstResponder(to: newSurface)
        }
    }

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
            taskTerminalHeights.removeValue(forKey: tid)
            return
        }

        for (key, pane) in panes {
            if let tab = pane.main.tabs.first(where: { $0.surface === deadSurface }) {
                // Match native terminal behavior: auto-close on clean exit
                // (Ctrl+D, `exit`), but keep the dead tab around on abnormal
                // exit so users can inspect crashes or error output.
                // Agent surfaces bail out earlier via skipAutoRestart.
                if deadSurface.childExitCode == 0 {
                    closeMainTab(id: tab.id, in: key)
                }
                return
            }

            guard pane.secondary === deadSurface else { continue }

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
            panes[key]!.secondary = newSurface
            // Secondary terminal: hide the panel instead of respawning visibly.
            secondaryVisible[key] = false
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

    /// Whether a worktree currently has a live pane. Main is always "open".
    func isOpen(_ worktree: Worktree) -> Bool {
        worktree.isMain || openWorktreeIds.contains(worktree.id)
    }

    /// Whether a worktree has any surface with a running foreground process.
    func worktreeNeedsConfirmClose(_ worktreeId: String) -> Bool {
        guard let pane = panes[worktreeId] else { return false }
        return pane.main.tabs.contains(where: { $0.surface.needsConfirmQuit })
            || pane.secondary.needsConfirmQuit
    }

    /// Close a worktree's terminals without deleting the worktree itself.
    ///
    /// Removes the pane entry first so the close-surface observer doesn't
    /// try to restart the dying shells, then sends SIGHUP via `closeSurface()`.
    func closeWorktree(_ worktreeId: String) {
        guard let pane = panes.removeValue(forKey: worktreeId) else { return }
        cleanupState(for: worktreeId)
        for tab in pane.main.tabs {
            onMainTabClosed?(tab.surface)
            tab.surface.closeSurface()
        }
        pane.secondary.closeSurface()
    }

    private func cleanupState(for worktreeId: String) {
        openWorktreeIds.removeAll(where: { $0 == worktreeId })
        notifiedWorktrees.remove(worktreeId)
        recentRestarts.removeValue(forKey: worktreeId)
        asideVisible.removeValue(forKey: worktreeId)
        secondaryVisible.removeValue(forKey: worktreeId)
        secondaryHeights.removeValue(forKey: worktreeId)
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

    /// The stored terminal panel height for a task, or the default.
    func taskTerminalHeight(for taskId: UUID) -> CGFloat {
        taskTerminalHeights[taskId] ?? 200
    }

    /// Store a task's terminal panel height.
    func setTaskTerminalHeight(_ height: CGFloat, for taskId: UUID) {
        guard taskTerminalHeights[taskId] != height else { return }
        taskTerminalHeights[taskId] = height
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
        taskTerminalHeights.removeValue(forKey: taskId)
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
        panes.values.flatMap { $0.main.tabs.map(\.surface) + [$0.secondary] } + taskSurfaces.values
    }

}
