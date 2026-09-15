import AppKit
import GhosttyKit

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
    /// The active `ghostty_app_t` handle captured on first surface creation.
    /// Non-private so the task-terminal extension (a separate file) can cache the handle
    /// when it creates surfaces outside the main-pane flow.
    var ghosttyApp: ghostty_app_t?
    private var closeSurfaceObserver: NotificationObservation?
    private var recentRestarts: [String: [Date]] = [:]
    @Published var activeSurfaceId: String?
    @Published private(set) var notifiedWorktrees: Set<String> = []
    /// Worktree IDs that have active terminal panes. Must stay in sync with
    /// `panes.keys` — all pane mutations should go through `removeSurface` or `closeWorktree`.
    @Published private(set) var openWorktreeIds: [String] = []
    private var notificationObserver: NotificationObservation?

    /// Per-worktree panel visibility (defaults to false when absent).
    /// Internal (not private) so the panel accessors in
    /// `TerminalManager+Panels.swift` — a cross-file extension — can reach them.
    @Published var asideVisible: [String: Bool] = [:]
    @Published var secondaryVisible: [String: Bool] = [:]
    /// Per-worktree secondary terminal panel height.
    @Published var secondaryHeights: [String: CGFloat] = [:]

    // MARK: - Task Terminal Storage
    //
    // Task-specific storage is `internal` (no modifier) rather than `private`
    // because the task-terminal methods live in `TerminalManager+TaskTerminals.swift`
    // — a same-module extension cannot reach `private` members across files.
    // Only the methods in that extension should mutate these.

    /// Per-task terminal surfaces (one per task, keyed by task UUID).
    var taskSurfaces: [UUID: Ghostty.SurfaceView] = [:]
    /// Task IDs that have an active terminal surface.
    @Published var openTaskIds: Set<UUID> = []
    /// Per-task terminal panel visibility.
    @Published var taskTerminalVisible: [UUID: Bool] = [:]
    /// Per-task terminal panel height.
    @Published var taskTerminalHeights: [UUID: CGFloat] = [:]
    /// Tasks whose terminal launch is in flight: the command is not built yet because the launch is
    /// awaiting the resolved PATH, so no surface exists and `taskTerminalVisible` still reads false.
    /// Without this claim a second press during that window starts a second agent for the task.
    var taskLaunchesInFlight: Set<UUID> = []

    /// Per-worktree active side panel tab (stored as raw string to avoid coupling to view enum).
    /// Internal so the panel accessors in `TerminalManager+Panels.swift` can reach it.
    var sidePanelTabs: [String: String] = [:]

    var activePane: TerminalPane? {
        guard let id = activeSurfaceId else { return nil }
        return panes[id]
    }

    init() {
        TerminalManager.allInstances.add(self)

        notificationObserver = NotificationObservation(NotificationCenter.default.addObserver(
            forName: .ghosttyDesktopNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let surface = notification.object as? Ghostty.SurfaceView else { return }
            Task { @MainActor in
                self?.handleDesktopNotification(from: surface)
            }
        })

        closeSurfaceObserver = NotificationObservation(NotificationCenter.default.addObserver(
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
        })
    }

    /// Explicitly close all terminal surfaces, sending SIGHUP to their shells.
    ///
    /// Called during app termination to ensure graceful cleanup before the
    /// process exits. Removes the close-surface observer first to prevent
    /// the restart logic from firing during teardown.
    func closeAllSurfaces() {
        closeSurfaceObserver = nil
        for surface in allSurfaces {
            surface.closeSurface()
        }
        taskSurfaces.removeAll()
        openTaskIds.removeAll()
        taskTerminalVisible.removeAll()
        taskTerminalHeights.removeAll()
        launcherDrafts.removeAll()
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

    /// Get or create terminal panes for the given worktree.
    func pane(for worktree: Worktree, app: ghostty_app_t, projectPath: String?) -> TerminalPane {
        ghosttyApp = app

        let key = worktree.id
        if let existing = panes[key] {
            return existing
        }

        let dir = worktree.path ?? projectPath
        let secondary = Ghostty.SurfaceView(app, workingDirectory: dir)

        // Main tab starts as a launcher; no Ghostty surface until the user submits
        // a prompt or clicks "Open terminal".
        let initialTab = TerminalTab(id: UUID(), kind: .launcher)
        let main = MainTerminal(tabs: [initialTab], activeId: initialTab.id)
        let tp = TerminalPane(main: main, secondary: secondary)
        panes[key] = tp
        if !openWorktreeIds.contains(key) {
            openWorktreeIds.append(key)
        }

        setInitialPanelVisibility(for: key, worktree: worktree)

        // No main command configured → skip the launcher screen entirely.
        if mainCommandProvider() == nil {
            promoteLauncher(tabId: initialTab.id, in: key, app: app)
        }

        return panes[key] ?? tp
    }

    /// Provides the user's configured main terminal command (nil when unset).
    /// When it returns nil, new main tabs open a login shell directly instead of
    /// showing the prompt launcher. Wired from `ContentView` to `SettingsManager`.
    var mainCommandProvider: () -> String? = { nil }

    /// "Open secondary terminal on start" preference. Consulted only at pane
    /// creation so manual Cmd+J toggles afterwards are preserved.
    var openSecondaryOnStartProvider: () -> Bool = { false }

    /// Initial panel visibility for a fresh pane. Aside is main-gated; secondary
    /// follows `openSecondaryOnStartProvider()` for every worktree.
    /// Internal (not private) so unit tests can drive it without spinning up a
    /// real `ghostty_app_t` to reach it via `pane(for:app:projectPath:)`.
    func setInitialPanelVisibility(for key: String, worktree: Worktree) {
        if !worktree.isMain {
            asideVisible[key] = true
        }
        secondaryVisible[key] = openSecondaryOnStartProvider()
    }

    // MARK: - Main Tab Management

    /// The surface of the currently active worktree's active main tab.
    ///
    /// Sole accessor for "the currently active main surface" — do not add overloads.
    var activeMainSurface: Ghostty.SurfaceView? {
        guard let id = activeSurfaceId else { return nil }
        return panes[id]?.main.activeSurface
    }

    var isActiveMainSurfaceFocused: Bool { activeMainSurface != nil && NSApp.keyWindow?.firstResponder === activeMainSurface }

    /// Whether `sendToActiveMainTab` has somewhere to dispatch (launcher or surface tab).
    /// Use this for UI gates instead of `activeMainSurface != nil`, which excludes launchers.
    var canSendToActiveMainTab: Bool {
        guard let id = activeSurfaceId else { return false }
        return panes[id]?.main.hasActiveTab ?? false
    }

    /// Per-launcher-tab draft text. Not `@Published`: keystroke writes from the
    /// NSTextView flow through the Binding's setter and the text view itself is
    /// the visible source of truth, so no SwiftUI invalidation is needed on
    /// type. External writes (`sendToActiveMainTab`) call `objectWillChange.send()`
    /// explicitly so the launcher view re-renders and pushes the new text in.
    var launcherDrafts: [UUID: String] = [:]

    /// One-shot signal: the id of a launcher tab that was *explicitly created* (Cmd+T)
    /// and should focus its prompt input on mount. Set in `appendLauncherTab`, read by
    /// `PromptLauncherView` via `ContentView`, and cleared once consumed. Plain selection
    /// of a worktree whose active tab is a launcher leaves this nil, so the launcher no
    /// longer steals focus on re-select. Not `@Published`: it is set alongside an
    /// `objectWillChange.send()` and clearing it must not trigger a re-render.
    var pendingFocusTabId: UUID?

    /// Send text to the active main tab. Launcher tabs append it to the draft
    /// (newline-separated), so repeated prompt/task/todo clicks stack instead of
    /// clobbering. Surface tabs forward to `sendCommand` (asCommand=true, appends
    /// newline) or `sendPaste`.
    func sendToActiveMainTab(_ text: String, asCommand: Bool) {
        guard let worktreeId = activeSurfaceId,
              let tab = panes[worktreeId]?.main.activeTab else { return }
        switch tab.kind {
        case .launcher:
            let merged = appendingToDraft(existing: launcherDrafts[tab.id] ?? "", text)
            guard launcherDrafts[tab.id] != merged else { return }
            objectWillChange.send()
            launcherDrafts[tab.id] = merged
        case .surface(let surface):
            if asCommand {
                surface.sendCommand(text)
            } else {
                surface.sendPaste(text)
            }
            transferFirstResponder(to: surface)
        }
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

    /// Append a new launcher tab (no process) to the given worktree's main terminal and activate it.
    ///
    /// Creates the pane on-the-fly when it doesn't exist yet. Returns the new tab's id
    /// so callers can later promote it.
    @discardableResult
    func appendLauncherTab(for worktree: Worktree, app: ghostty_app_t) -> UUID {
        let key = worktree.id
        let newTab = TerminalTab(id: UUID(), kind: .launcher)

        if panes[key] != nil {
            panes[key]!.main.tabs.append(newTab)
            panes[key]!.main.activeId = newTab.id
        } else {
            ghosttyApp = app
            let secondary = Ghostty.SurfaceView(app, workingDirectory: worktree.path)
            let mainTerminal = MainTerminal(tabs: [newTab], activeId: newTab.id)
            panes[key] = TerminalPane(main: mainTerminal, secondary: secondary)
            if !openWorktreeIds.contains(key) {
                openWorktreeIds.append(key)
            }
            setInitialPanelVisibility(for: key, worktree: worktree)
        }

        // No main command configured → promote immediately to a login shell (which
        // focuses via `promoteLauncher`). Otherwise the tab stays a launcher, so signal its
        // view to focus the prompt input — this is the explicit-creation (Cmd+T) path.
        // `pendingFocusTabId` isn't `@Published`, so it must be set *before* the
        // `objectWillChange.send()` below to be visible in the resulting render pass.
        if mainCommandProvider() == nil {
            promoteLauncher(tabId: newTab.id, in: key, app: app)
        } else {
            pendingFocusTabId = newTab.id
        }

        objectWillChange.send()

        return newTab.id
    }

    /// Append a new tab that immediately runs a login shell (no launcher screen).
    ///
    /// Convenience wrapper: `appendLauncherTab` + `promoteLauncher`.
    /// Used by the Cmd+Shift+T shortcut.
    @discardableResult
    func appendShellTab(for worktree: Worktree, app: ghostty_app_t) -> UUID {
        let id = appendLauncherTab(for: worktree, app: app)
        promoteLauncher(tabId: id, in: worktree.id, app: app)
        return id
    }

    /// Swaps a `.launcher` tab for a `.surface` tab in-place, running `command` — or a login
    /// shell when it is nil.
    ///
    /// Keeps the tab id and position so the tab strip and focus-routing needn't special-case
    /// the transition. No-op (returns nil) if the target tab isn't a launcher — which is also
    /// how `promoteLauncherToAgent` handles a tab the user closed while the PATH resolved.
    @discardableResult
    func promoteLauncher(
        tabId: UUID,
        in worktreeId: String,
        app: ghostty_app_t,
        command: String? = nil
    ) -> Ghostty.SurfaceView? {
        guard let pane = panes[worktreeId],
              let tabIndex = pane.main.tabs.firstIndex(where: { $0.id == tabId }),
              pane.main.tabs[tabIndex].isLauncher else { return nil }

        let newSurface = Ghostty.SurfaceView(
            app,
            workingDirectory: pane.secondary.initialWorkingDirectory,
            command: command
        )

        panes[worktreeId]!.main.tabs[tabIndex].kind = .surface(newSurface)
        panes[worktreeId]!.main.activeId = tabId
        launcherDrafts.removeValue(forKey: tabId)
        // Promotion focuses the new surface directly, so any pending launcher-focus
        // signal for this tab is now moot — drop it so it can't dangle (e.g. the
        // `appendShellTab` path sets it, then promotes here with no launcher to consume it).
        if pendingFocusTabId == tabId { pendingFocusTabId = nil }
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
    /// 5. Call `surface.closeSurface()` — prevents the closeSurface observer from
    ///    seeing a closed surface that is still in `tabs`.
    /// 6. If the closed tab was active and another tab remains, transfer first responder
    ///    to the newly active surface. The Cmd+W / Cmd+Shift+[/] monitors are gated on
    ///    `firstResponder === activeMainSurface`, so without this handoff the shortcuts
    ///    silently stop working until the user clicks back into the terminal.
    func closeMainTab(id: UUID, in worktreeId: String) {
        guard let tabIndex = panes[worktreeId]?.main.tabs.firstIndex(where: { $0.id == id }) else { return }
        let removedTab = panes[worktreeId]!.main.tabs[tabIndex]

        panes[worktreeId]!.main.tabs.remove(at: tabIndex)
        launcherDrafts.removeValue(forKey: id)

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
        removedTab.surface?.closeSurface()

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
        guard let app = ghosttyApp else { return }

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
        if let pane = panes[worktreeId] {
            for tab in pane.main.tabs { launcherDrafts.removeValue(forKey: tab.id) }
        }
        panes.removeValue(forKey: worktreeId)
        cleanupState(for: worktreeId)
    }

    /// Whether a worktree currently has a live pane.
    func isOpen(_ worktree: Worktree) -> Bool {
        worktree.isMain || openWorktreeIds.contains(worktree.id)
    }

    /// Whether a worktree has any surface with a running foreground process.
    func worktreeNeedsConfirmClose(_ worktreeId: String) -> Bool {
        guard let pane = panes[worktreeId] else { return false }
        return pane.main.tabs.contains(where: { $0.surface?.needsConfirmQuit == true })
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
            launcherDrafts.removeValue(forKey: tab.id)
            tab.surface?.closeSurface()
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

    /// All surfaces across all worktrees and tasks.
    var allSurfaces: [Ghostty.SurfaceView] {
        panes.values.flatMap { $0.main.tabs.compactMap(\.surface) + [$0.secondary] } + taskSurfaces.values
    }

}
