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
    private var initialTabIds: [String: UUID] = [:]
    /// The active `ghostty_app_t` handle captured on first surface creation.
    /// Non-private so the task-terminal extension (a separate file) can cache the handle
    /// when it creates surfaces outside the main-pane flow.
    var ghosttyApp: ghostty_app_t?
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
        ghosttyApp = app

        let key = worktree.id
        if let existing = panes[key] {
            return existing
        }

        let dir = worktree.path ?? projectPath
        let secondary = Ghostty.SurfaceView(app, workingDirectory: dir)

        // Main tab starts as a launcher; no Ghostty surface until the user submits
        // a prompt or clicks "Open terminal" (or `launchAgentTab` replaces it).
        let initialTab = TerminalTab(id: UUID(), kind: .launcher)
        initialTabIds[key] = initialTab.id
        let main = MainTerminal(tabs: [initialTab], activeId: initialTab.id)
        let tp = TerminalPane(main: main, secondary: secondary)
        panes[key] = tp
        if !openWorktreeIds.contains(key) {
            openWorktreeIds.append(key)
        }

        setInitialPanelVisibility(for: key, worktree: worktree)

        // No main command configured → skip the launcher screen entirely.
        if mainCommandProvider() == nil {
            promoteLauncher(tabId: initialTab.id, in: key, app: app, mode: .loginShell)
        }

        return panes[key] ?? tp
    }

    /// Surfaces that should not be auto-restarted when they exit.
    /// Set by WorkTaskCoordinator for agent command surfaces.
    var skipAutoRestart: ((Ghostty.SurfaceView) -> Bool)?

    /// Provides the user's configured main terminal command (nil when unset).
    /// When it returns nil, new main tabs open a login shell directly instead of
    /// showing the prompt launcher. Wired from `ContentView` to `SettingsManager`.
    var mainCommandProvider: () -> String? = { nil }

    /// "Open secondary terminal on start" preference. Consulted only at pane
    /// creation so manual `Cmd+\` toggles afterwards are preserved.
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

    /// Returns the initial tab's UUID for `worktreeId` only if that tab is still present
    /// in the pane's tab list; removes the stale entry and returns nil otherwise.
    private func activeInitialTabId(for worktreeId: String) -> UUID? {
        guard let id = initialTabIds[worktreeId] else { return nil }
        if panes[worktreeId]?.main.tabs.contains(where: { $0.id == id }) == true {
            return id
        }
        initialTabIds.removeValue(forKey: worktreeId)
        return nil
    }

    /// Append a new command tab to the given worktree's main terminal and activate it.
    ///
    /// Creates `Ghostty.SurfaceView(app, workingDirectory: worktree.path ?? projectPath, command: command)`
    /// (pattern 2 — no login shell) and appends it as a new `TerminalTab`.
    /// If the pane doesn't exist yet it is created on-the-fly (mirrors `replaceMainSurface` fallback).
    /// `projectPath` is used as a fallback working directory when `worktree.path` is nil.
    @discardableResult
    func appendMainTab(for worktree: Worktree, app: ghostty_app_t, command: String, projectPath: String? = nil) -> Ghostty.SurfaceView {
        let key = worktree.id
        let newSurface = Ghostty.SurfaceView(app, workingDirectory: worktree.path ?? projectPath, command: command)
        let newTab = TerminalTab(id: UUID(), kind: .surface(newSurface))

        if panes[key] != nil {
            panes[key]!.main.tabs.append(newTab)
            panes[key]!.main.activeId = newTab.id
        } else {
            // Pane doesn't exist yet — create on-the-fly (mirrors replaceMainSurface fallback).
            ghosttyApp = app
            let dir = worktree.path ?? projectPath
            let secondary = Ghostty.SurfaceView(app, workingDirectory: dir)
            let mainTerminal = MainTerminal(tabs: [newTab], activeId: newTab.id)
            panes[key] = TerminalPane(main: mainTerminal, secondary: secondary)
            if !openWorktreeIds.contains(key) {
                openWorktreeIds.append(key)
            }
            setInitialPanelVisibility(for: key, worktree: worktree)
        }

        objectWillChange.send()
        transferFirstResponder(to: newSurface)
        return newSurface
    }

    /// Launch an agent command as the worktree's main tab, replacing the auto-created
    /// initial tab only when the pane is still pristine. Restores pre-#142 behavior
    /// where the agent surface IS the main terminal on a fresh task launch, without
    /// disturbing any tabs the user has opened on retry/continue flows.
    ///
    /// Composes `closeMainTab` + `appendMainTab` — SwiftUI coalesces the two
    /// `objectWillChange.send()` signals within a single runloop tick, so there is no
    /// intermediate empty-tab flash. Duplicating the removal/append logic inline would
    /// fragment the ordering guarantees that `closeMainTab` already enforces (remove
    /// from `tabs` → fire `onMainTabClosed` → `closeSurface()`).
    ///
    /// Scenarios handled by this composition:
    /// - Pane does not exist → `activeInitialTabId` returns nil → `appendMainTab`'s
    ///   own fallback creates the pane with the agent as the only main tab.
    /// - Pane has exactly one tab and it is the tracked live initial tab → close it,
    ///   then append the agent. This is the fresh-launch path.
    /// - Pane has extra user-opened tabs, or the tracked initial is gone → plain
    ///   append. Required to preserve user work: SIGHUPing the initial tab when the
    ///   user has opened a Cmd+T alongside it would terminate a live shell / CLI
    ///   session they expect to keep.
    @discardableResult
    func launchAgentTab(for worktree: Worktree, app: ghostty_app_t, command: String) -> Ghostty.SurfaceView {
        let key = worktree.id
        if let initialId = activeInitialTabId(for: key),
           panes[key]?.main.tabs.count == 1 {
            closeMainTab(id: initialId, in: key)
        }
        return appendMainTab(for: worktree, app: app, command: command)
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
        let dir = activeTab?.surface?.pwd
            ?? activeTab?.surface?.initialWorkingDirectory
            ?? pane.secondary.initialWorkingDirectory
        let newSurface = Ghostty.SurfaceView(app, workingDirectory: dir)
        let newTab = TerminalTab(id: UUID(), kind: .surface(newSurface))
        panes[worktreeId]!.main.tabs.append(newTab)
        panes[worktreeId]!.main.activeId = newTab.id
        objectWillChange.send()
        transferFirstResponder(to: newSurface)
        return newSurface
    }

    /// Append a new launcher tab (no process) to the given worktree's main terminal and activate it.
    ///
    /// Creates the pane on-the-fly when it doesn't exist yet (mirrors `appendMainTab`'s
    /// fallback). Returns the new tab's id so callers can later promote it.
    @discardableResult
    func appendLauncherTab(for worktree: Worktree, app: ghostty_app_t, projectPath: String? = nil) -> UUID {
        let key = worktree.id
        let newTab = TerminalTab(id: UUID(), kind: .launcher)

        if panes[key] != nil {
            panes[key]!.main.tabs.append(newTab)
            panes[key]!.main.activeId = newTab.id
        } else {
            ghosttyApp = app
            let dir = worktree.path ?? projectPath
            let secondary = Ghostty.SurfaceView(app, workingDirectory: dir)
            let mainTerminal = MainTerminal(tabs: [newTab], activeId: newTab.id)
            panes[key] = TerminalPane(main: mainTerminal, secondary: secondary)
            if !openWorktreeIds.contains(key) {
                openWorktreeIds.append(key)
            }
            setInitialPanelVisibility(for: key, worktree: worktree)
        }

        objectWillChange.send()

        // No main command configured → promote immediately to a login shell.
        if mainCommandProvider() == nil {
            promoteLauncher(tabId: newTab.id, in: key, app: app, mode: .loginShell)
        }

        return newTab.id
    }

    /// Append a new tab that immediately runs a login shell (no launcher screen).
    ///
    /// Convenience wrapper: `appendLauncherTab` + `promoteLauncher(mode: .loginShell)`.
    /// Used by the Cmd+Shift+T shortcut.
    @discardableResult
    func appendShellTab(for worktree: Worktree, app: ghostty_app_t, projectPath: String? = nil) -> UUID {
        let id = appendLauncherTab(for: worktree, app: app, projectPath: projectPath)
        promoteLauncher(tabId: id, in: worktree.id, app: app, mode: .loginShell)
        return id
    }

    /// How a launcher tab should be promoted: into a plain login shell or a prompt-driven
    /// agent command.
    enum LauncherPromotion {
        case loginShell
        case prompt(command: String, stdin: String)
    }

    /// Promote a `.launcher` tab to a `.surface` tab in-place, wiring a fresh Ghostty surface.
    ///
    /// Keeps the tab id and position so the tab strip and focus-routing needn't special-case
    /// the transition. `.loginShell` spawns pattern 1 (login shell); `.prompt` builds a
    /// `/bin/sh -c …` pipe that feeds the prompt into the agent command (same recipe as
    /// `WorkTaskCoordinator.runAgent`, inlined to avoid refactoring that hot path). No-op
    /// (returns nil) if the target tab isn't a launcher.
    @discardableResult
    func promoteLauncher(
        tabId: UUID,
        in worktreeId: String,
        app: ghostty_app_t,
        mode: LauncherPromotion
    ) -> Ghostty.SurfaceView? {
        guard let pane = panes[worktreeId],
              let tabIndex = pane.main.tabs.firstIndex(where: { $0.id == tabId }),
              pane.main.tabs[tabIndex].isLauncher else { return nil }

        let dir = pane.secondary.initialWorkingDirectory
        let newSurface: Ghostty.SurfaceView
        switch mode {
        case .loginShell:
            newSurface = Ghostty.SurfaceView(app, workingDirectory: dir)
        case let .prompt(command, stdin):
            let cmd = Self.buildPromptPipeCommand(agentCommand: command, prompt: stdin)
            newSurface = Ghostty.SurfaceView(app, workingDirectory: dir, command: cmd)
        }

        panes[worktreeId]!.main.tabs[tabIndex].kind = .surface(newSurface)
        panes[worktreeId]!.main.activeId = tabId
        launcherDrafts.removeValue(forKey: tabId)
        objectWillChange.send()
        transferFirstResponder(to: newSurface)
        return newSurface
    }

    /// Append a new main tab running `agentCommand` with `prompt` piped on stdin.
    ///
    /// Shared by the prompt launcher (via `promoteLauncher(.prompt)`) and auto-mode
    /// state-command dispatches. Builds the same `/bin/sh -c` pipe recipe used by
    /// `WorkTaskCoordinator.runAgent` so all agent-launch flows behave identically.
    @discardableResult
    func appendAgentTab(
        for worktree: Worktree,
        app: ghostty_app_t,
        agentCommand: String,
        prompt: String,
        projectPath: String? = nil
    ) -> Ghostty.SurfaceView {
        let command = Self.buildPromptPipeCommand(agentCommand: agentCommand, prompt: prompt)
        return appendMainTab(for: worktree, app: app, command: command, projectPath: projectPath)
    }

    /// Build the `/bin/sh -c` pipe command used by the prompt launcher and auto mode.
    /// Mirrors `WorkTaskCoordinator.runAgent`: export resolved login-shell PATH, then
    /// `cat $promptFile | $agentCmd` with positional args to avoid shell injection.
    /// The prompt file is removed after the agent consumes it so temp dir doesn't accumulate.
    static func buildPromptPipeCommand(agentCommand: String, prompt: String) -> String {
        let tempDir = NSTemporaryDirectory()
        let launchId = UUID().uuidString
        let promptFile = (tempDir as NSString).appendingPathComponent("clearway-launcher-\(launchId).md")
        FileManager.default.createFile(atPath: promptFile, contents: prompt.data(using: .utf8), attributes: [.posixPermissions: 0o600])
        let recipe = "export PATH=\"$3\"; set -f; cat \"$2\" | $1; rc=$?; rm -f \"$2\"; exit $rc"
        return "/bin/sh -c " + shellEscape(recipe) + " -- "
            + shellEscape(agentCommand) + " " + shellEscape(promptFile) + " " + shellEscape(ShellEnvironment.path)
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
        if let removedSurface = removedTab.surface {
            onMainTabClosed?(removedSurface)
            removedSurface.closeSurface()
        }

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
            guard let surface = tab.surface else { continue }
            onMainTabClosed?(surface)
            surface.closeSurface()
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
