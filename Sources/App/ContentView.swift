import SwiftUI
import GhosttyKit

private let maxShortcuts = 9
private let listsColumnMinWidth: Double = 280
private let listsColumnDefaultWidth: Double = 340
private let listsColumnStorageKey = "ListsColumnIdealWidth"

/// What the detail pane is showing.
enum DetailSelection: Hashable {
    case planning
    case prompts
    case settings
    case worktree(Worktree)

    var worktree: Worktree? {
        if case .worktree(let wt) = self { return wt }
        return nil
    }
}

struct TabCloseRequest: Identifiable {
    let id = UUID()
    let worktreeId: String
    let tabId: UUID
    let title: String
}

// swiftlint:disable:next type_body_length
struct ContentView: View {
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var claudeTodoManager: ClaudeTodoManager
    @EnvironmentObject private var todoManager: TodoManager
    @EnvironmentObject private var notesManager: NotesManager
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator
    @EnvironmentObject private var claudeActivityMonitor: ClaudeActivityMonitor
    @State private var detailSelection: DetailSelection? = .planning
    @State private var sidebarSelection: DetailSelection? = .planning
    /// True during the synchronous tick of an arrow keyDown in the sidebar.
    @State private var sidebarArrowKeyInFlight = false
    @State private var sidebarKeyMonitor: Any?
    @State private var mainTerminalKeyMonitor: Any?
    @State private var becomeActiveObserver: Any?
    @State private var resignActiveObserver: Any?
    @State private var pendingRefresh: DispatchWorkItem?
    @State private var showCopiedFeedback = false
    @State private var showRemoveConfirmation = false
    @State private var ctrlHeld = false
    @State private var flagsMonitor: Any?
    @State private var taskWindowObservers: [Any] = []
    @State private var worktreeShortcutsDisabled = false
    @State private var hookSheet: HookSheet?
    @State private var afterCreateHookState: AfterCreateHookState = .none
    @State private var selectedTaskId: UUID?
    @State private var taskEditorMode: TaskEditorMode = .edit
    @State private var selectedPromptId: String?
    @State private var promptEditorMode: TaskEditorMode = .preview
    @State private var sidePanelTab: SidePanelTab = .todos
    @State private var showTrustConfirmation = false
    @State private var pendingTrustAction: (() -> Void)?
    @State private var tabCloseQueue: [TabCloseRequest] = []
    @State private var previousDetailSelection: DetailSelection?
    @State private var columnWidthTracker = ColumnWidthTracker()
    @State private var listsColumnIdealWidth: Double

    private var selectedWorktree: Worktree? { detailSelection?.worktree }

    /// Action exposed via `focusedSceneValue` so the File > New Tab menu item
    /// is enabled only when this window has an active worktree.
    private var newTabAction: (() -> Void)? {
        guard let wtId = selectedWorktree?.id else { return nil }
        return { [terminalManager, ghosttyApp] in
            guard let app = ghosttyApp.app else { return }
            terminalManager.newShellTab(for: wtId, app: app)
        }
    }

    private var sidebarSelectionBinding: Binding<DetailSelection?> {
        Binding(
            get: { sidebarSelection },
            set: { new in
                if sidebarSelection != new { sidebarSelection = new }
                // Arrow-key nav never commits — the user must press Enter to switch.
                if sidebarArrowKeyInFlight { return }
                if detailSelection != new { detailSelection = new }
            }
        )
    }

    init() {
        let defaults = UserDefaults.standard
        let stored: Double
        if defaults.object(forKey: listsColumnStorageKey) != nil {
            let raw = defaults.double(forKey: listsColumnStorageKey)
            stored = max(listsColumnMinWidth, raw)
        } else {
            stored = listsColumnDefaultWidth
        }
        _listsColumnIdealWidth = State(initialValue: stored)
    }

    @ViewBuilder private var navigator: some View {
        NavigationSplitView {
            SidebarView(
                sidebarSelection: sidebarSelectionBinding,
                detailSelection: $detailSelection,
                onRemoveWorktree: { beginRemoveWorktree($0) },
                onSearchActiveChanged: { worktreeShortcutsDisabled = $0 }
            )
        } content: {
            contentColumn
        } detail: {
            detailView
        }
        .sheet(item: $hookSheet) { hook in
            HookTerminalSheet(hook: hook)
        }
        .toolbar {
            if selectedWorktree != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showRemoveConfirmation = true
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .help("Remove worktree")
                    .disabled(currentWorktree?.isMain == true || currentWorktree?.branch == nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: toggleSecondaryTerminal) {
                        Image(systemName: "rectangle.bottomhalf.inset.filled")
                            .opacity(secondaryVisible ? 1 : 0.5)
                    }
                    .help(secondaryVisible ? "Hide secondary terminal" : "Show secondary terminal")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: toggleAside) {
                        Image(systemName: "sidebar.trailing")
                            .opacity(asideVisible ? 1 : 0.5)
                    }
                    .help(asideVisible ? "Hide aside" : "Show aside")
                }
            }
        }
        .confirmationDialog(
            "Remove worktree \"\(currentWorktree?.displayName ?? "")\"?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let wt = currentWorktree else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { beginRemoveWorktree(wt) }
            }
        } message: {
            Text("This will delete the worktree and its working directory, including any uncommitted changes and untracked files.")
        }
        .confirmationDialog(
            "Trust WORKFLOW.md hooks?",
            isPresented: $showTrustConfirmation,
            titleVisibility: .visible
        ) {
            Button("Trust & Continue") {
                workTaskCoordinator.approveTrust()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pendingTrustAction?(); pendingTrustAction = nil }
            }
            Button("Cancel", role: .cancel) { pendingTrustAction = nil }
        } message: {
            Text("This project's WORKFLOW.md configures hooks that will run shell commands. Review the file before approving.")
        }
        .confirmationDialog(
            tabCloseDialogTitle,
            isPresented: tabCloseIsPresented,
            presenting: tabCloseQueue.first
        ) { request in
            Button("Close", role: .destructive) {
                terminalManager.closeMainTab(id: request.tabId, in: request.worktreeId)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("A process is still running. Closing will terminate it.")
        }
    }

    var body: some View {
        navigator
        .focusedSceneValue(\.newTabAction, newTabAction)
        .onChange(of: workTaskCoordinator.autoStartGeneration) { _ in
            guard let result = workTaskCoordinator.pendingAutoStart else { return }
            workTaskCoordinator.pendingAutoStart = nil
            handleStartResult(result, isAutoStart: true)
        }
        .navigationTitle(currentWorktree?.displayName ?? projectName)
        .onChange(of: detailSelection) { [old = detailSelection] new in
            previousDetailSelection = old
            if sidebarSelection != new { sidebarSelection = new }
            if old == .planning || old == .prompts {
                commitListsColumnWidth()
            }
            if new?.worktree == nil && terminalManager.activeSurfaceId != nil {
                terminalManager.activeSurfaceId = nil
            }
            // Save the active tab for the worktree we're leaving
            if let oldId = old?.worktree?.id {
                terminalManager.setSidePanelTab(sidePanelTab.rawValue, for: oldId)
            }
            // Clear selection when navigating away from list views
            if new != .prompts {
                selectedPromptId = nil
            }
            guard let wt = new?.worktree, let app = ghosttyApp.app, wt.id != old?.worktree?.id else { return }
            terminalManager.activate(wt, app: app, projectPath: worktreeManager.projectPath)
            if case .blocking(let inline) = afterCreateHookState, inline.worktreeId == wt.id {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    inline.hook.surface.window?.makeFirstResponder(inline.hook.surface)
                }
            } else if !sidebarArrowKeyInFlight {
                focusActiveMainTab()
            }
            terminalManager.clearNotification(for: wt.id)
            claudeTodoManager.setWorktreePath(wt.path)
            todoManager.setWorktreePath(wt.path)
            notesManager.setWorktreePath(wt.path)

            restoreSidePanelTab(for: wt)
        }
        .onChange(of: selectedTaskId) { newId in
            guard let newId,
                  let task = workTaskManager.tasks.first(where: { $0.id == newId }) else { return }
            taskEditorMode = (terminalManager.isTaskTerminalVisible(for: newId) || task.body.isEmpty) ? .edit : .preview
        }
        .onChange(of: worktreeManager.lastCreatedBranch) { branch in
            guard let branch else { return }
            guard let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) else { return }
            worktreeManager.lastCreatedBranch = nil

            let pending = ghosttyApp.app.flatMap { app in
                workTaskCoordinator.completePendingLaunch(branch: branch, worktree: wt, app: app)
            }
            let isAutoStart = pending?.isAutoStart ?? false

            // Only navigate for manual starts
            if !isAutoStart {
                detailSelection = .worktree(wt)
            }

            let projectHookCmd = worktreeManager.hookCommand(\.afterCreate, forBranch: branch, worktreePath: wt.path ?? "")
            let workflowHookCmd = workTaskCoordinator.workflowAfterCreateHook()
            let afterCreateCmd = ProjectHooks.chainCommands(projectHookCmd, workflowHookCmd)

            if !isAutoStart, let cmd = afterCreateCmd, let app = ghosttyApp.app {
                let surface = Ghostty.SurfaceView(app, workingDirectory: wt.path, command: hookShellCommand(cmd))
                var continued = false
                afterCreateHookState = .blocking(InlineHook(
                    worktreeId: wt.id,
                    hook: HookSheet(title: "After create", command: cmd, surface: surface, onContinue: {
                        guard !continued else { return }
                        continued = true
                        pending?.launch()
                    }, allowContinueOnFailure: true)
                ))
            } else {
                pending?.launch()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyChildExited)) { notification in
            guard let surface = notification.object as? Ghostty.SurfaceView,
                  let exitCode = notification.userInfo?[GhosttyNotificationKey.exitCode] as? UInt32,
                  let inline = afterCreateHookState.inlineHook,
                  inline.hook.surface === surface else { return }
            if exitCode == 0 { inline.hook.onContinue(); finishAfterCreateHook() } else { afterCreateHookState = .failed(inline) }
        }
        .onChange(of: worktreeManager.worktrees) { newWorktrees in
            claudeActivityMonitor.updateWorktrees(newWorktrees)
            let currentIds = Set(newWorktrees.map(\.id))
            terminalManager.pruneStale(keeping: currentIds)
            worktreeManager.prunePRStatuses(keeping: currentIds)
            tabCloseQueue.removeAll { req in !terminalManager.mainTabs(for: req.worktreeId).contains { $0.id == req.tabId } }
            if let hookWt = afterCreateHookState.inlineHook?.worktreeId, !newWorktrees.contains(where: { $0.id == hookWt }) {
                afterCreateHookState = .none
            }
            guard let selected = selectedWorktree else { return }
            let refreshed = newWorktrees.first(where: { $0.id == selected.id })
            // Update selection to the refreshed instance so its hash matches
            // the List tag — otherwise the highlight is lost after refresh.
            if let refreshed, refreshed != selected { detailSelection = .worktree(refreshed) } else if refreshed == nil { selectFallback() }
        }
        .onChange(of: terminalManager.openWorktreeIds) { openIds in
            guard let selected = selectedWorktree, !selected.isMain, !openIds.contains(selected.id) else { return }
            selectFallback()
        }
        .onChange(of: currentWorktreeHasTask) { hasTask in
            if !hasTask && sidePanelTab == .task { sidePanelTab = .todos }
        }
        .background {
            // Cmd+N: switch worktrees (sorted order matches sidebar)
            if !worktreeShortcutsDisabled {
                ForEach(Array(sortedWorktrees.prefix(maxShortcuts).enumerated()), id: \.element.id) { index, wt in
                    Button("") {
                        detailSelection = .worktree(wt)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .hidden()
                }
            }

            // Ctrl+N: focus terminal panes
            Button("") { focusActiveMainTab() }
                .keyboardShortcut("1", modifiers: .control)
                .hidden()
            Button("") { showAndFocusSecondary(isVisible: secondaryVisible, toggle: toggleSecondaryTerminal) }
                .keyboardShortcut("2", modifiers: .control)
                .hidden()

            // Cmd+Ctrl+N: toggle pane visibility
            Button("") { toggleSecondaryTerminal() }
                .keyboardShortcut("2", modifiers: [.command, .control])
                .hidden()
            Button("") { toggleAside() }
                .keyboardShortcut("3", modifiers: [.command, .control])
                .hidden()
        }
        .onAppear {
            claudeActivityMonitor.updateWorktrees(worktreeManager.worktrees)
            claudeTodoManager.setWorktreePath(selectedWorktree?.path)
            todoManager.setWorktreePath(selectedWorktree?.path)
            notesManager.setWorktreePath(selectedWorktree?.path)

            // onChange(of: detailSelection) doesn't fire for initial value on macOS 13
            if let wt = selectedWorktree {
                restoreSidePanelTab(for: wt)
            }
            if becomeActiveObserver == nil {
                becomeActiveObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    Task { @MainActor in
                        worktreeManager.cancelBackgroundRefresh()
                        debouncedRefresh()
                    }
                }
            }
            if resignActiveObserver == nil {
                resignActiveObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    Task { @MainActor in
                        worktreeManager.refreshInBackground(openWorktreeIds: terminalManager.openWorktreeIds)
                    }
                }
            }
            if taskWindowObservers.isEmpty {
                let actions: [(Notification.Name, (WorkTask) -> Void)] = [
                    (WorkTaskNotification.start, startWorkTask),
                    (WorkTaskNotification.continue, continueWorkTask),
                    (WorkTaskNotification.openWorktree, openTaskWorktree),
                ]
                let projectPath = worktreeManager.projectPath
                taskWindowObservers = actions.map { name, action in
                    NotificationCenter.default.addObserver(forName: name, object: projectPath, queue: .main) { [self] n in
                        handleTaskNotification(n, action: action)
                    }
                }
            }
            if flagsMonitor == nil {
                flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    let held = event.modifierFlags.contains(.control)
                    if held != ctrlHeld {
                        withAnimation(.easeInOut(duration: 0.1)) { ctrlHeld = held }
                    }
                    return event
                }
            }
            installSidebarKeyMonitor()
            installMainTerminalKeyMonitor()
        }
        .onDisappear {
            if detailSelection == .planning || detailSelection == .prompts {
                commitListsColumnWidth()
            }
            pendingRefresh?.cancel()
            pendingRefresh = nil
            worktreeManager.cancelBackgroundRefresh()
            if let o = becomeActiveObserver { NotificationCenter.default.removeObserver(o); becomeActiveObserver = nil }
            if let o = resignActiveObserver { NotificationCenter.default.removeObserver(o); resignActiveObserver = nil }
            if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
            removeSidebarKeyMonitor()
            removeMainTerminalKeyMonitor()
            ctrlHeld = false
            claudeTodoManager.stopWatching()
            todoManager.stopWatching()
            notesManager.stopWatching()
            for observer in taskWindowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            taskWindowObservers = []
        }
    }

    // MARK: - Title

    private var sortedWorktrees: [Worktree] { Worktree.sorted(worktreeManager.worktrees, openIds: terminalManager.openWorktreeIds) }

    private var projectName: String { URL(fileURLWithPath: worktreeManager.projectPath).lastPathComponent }

    private var currentWorktree: Worktree? {
        guard let id = selectedWorktree?.id else { return nil }
        return worktreeManager.worktrees.first(where: { $0.id == id })
    }

    private var asideVisible: Bool { terminalManager.isAsideVisible(for: selectedWorktree?.id) }

    /// Whether the current worktree has a linked task.
    private var currentWorktreeHasTask: Bool {
        guard let branch = selectedWorktree?.branch else { return false }
        return workTaskManager.task(forWorktree: branch) != nil
    }

    /// Tabs available for the current worktree — hides Task when no task is linked.
    private var availableSidePanelTabs: [SidePanelTab] {
        currentWorktreeHasTask ? SidePanelTab.allCases : SidePanelTab.allCases.filter { $0 != .task }
    }

    private var secondaryVisible: Bool { terminalManager.isSecondaryVisible(for: selectedWorktree?.id) }

    private var shouldShowFocusBorder: Bool { settings.showFocusBorder && ghosttyApp.appIsActive && (asideVisible || secondaryVisible) }

    private var tabCloseDialogTitle: String { tabCloseQueue.first.map { "Close tab \"\($0.title)\"?" } ?? "" }

    private var tabCloseIsPresented: Binding<Bool> {
        Binding(get: { !tabCloseQueue.isEmpty },
                set: { if !$0 && !tabCloseQueue.isEmpty { tabCloseQueue.removeFirst() } })
    }

    // MARK: - Sidebar Key Monitor

    private func installSidebarKeyMonitor() {
        guard sidebarKeyMonitor == nil else { return }
        sidebarKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let code = event.keyCode
            // Fast path: skip the firstResponder check for keys we don't care about.
            guard code == kVK_UpArrow || code == kVK_DownArrow
                    || code == kVK_Return || code == kVK_ANSI_KeypadEnter else {
                return event
            }
            guard NSApp.keyWindow?.firstResponder is NSTableView else { return event }
            if code == kVK_UpArrow || code == kVK_DownArrow {
                sidebarArrowKeyInFlight = true
                DispatchQueue.main.async { sidebarArrowKeyInFlight = false }
                return event
            }
            // Return / Keypad Enter: commit sidebarSelection so closed worktrees open + focus.
            if sidebarSelection != detailSelection {
                detailSelection = sidebarSelection
            } else {
                focusActiveMainTab()
            }
            return nil
        }
    }

    private func removeSidebarKeyMonitor() {
        guard let monitor = sidebarKeyMonitor else { return }
        NSEvent.removeMonitor(monitor)
        sidebarKeyMonitor = nil
    }

    // MARK: - Main Terminal Key Monitor

    private func installMainTerminalKeyMonitor() {
        // Guard prevents double-install: onAppear fires multiple times on macOS 13.
        // Cmd+W with focus in the secondary terminal falls through to AppKit (closes window) —
        // intentional: "close the focused thing." Monitor only matches activeMainSurface focus.
        guard mainTerminalKeyMonitor == nil else { return }
        mainTerminalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let code = event.keyCode
            guard flags == .command || flags == [.command, .shift] else { return event }
            guard NSApp.keyWindow?.firstResponder === terminalManager.activeMainSurface,
                  let worktreeId = terminalManager.activeSurfaceId else { return event }
            let tabs = terminalManager.mainTabs(for: worktreeId)
            guard !tabs.isEmpty else { return event }
            if flags == .command && code == 0x0D {
                // Cmd+W: close the active main tab
                guard let id = terminalManager.mainActiveTabId(for: worktreeId) else { return event }
                beginCloseTab(id: id, in: worktreeId); return nil
            }
            guard flags == [.command, .shift],
                  let activeId = terminalManager.mainActiveTabId(for: worktreeId),
                  let index = tabs.firstIndex(where: { $0.id == activeId }) else { return event }
            if code == 0x21 {
                // Cmd+Shift+[: cycle to previous tab (wrap-around)
                terminalManager.activateMainTab(id: tabs[(index - 1 + tabs.count) % tabs.count].id, in: worktreeId); return nil
            } else if code == 0x1E {
                // Cmd+Shift+]: cycle to next tab (wrap-around)
                terminalManager.activateMainTab(id: tabs[(index + 1) % tabs.count].id, in: worktreeId); return nil
            }
            return event
        }
    }

    private func removeMainTerminalKeyMonitor() {
        guard let monitor = mainTerminalKeyMonitor else { return }
        NSEvent.removeMonitor(monitor)
        mainTerminalKeyMonitor = nil
    }

    // MARK: - Pane Focus & Visibility

    private func focusActiveMainTab(delay: Double = 0) {
        guard let surface = terminalManager.activeMainSurface else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { surface.window?.makeFirstResponder(surface) }
    }

    private func focusSecondary(delay: Double = 0) {
        guard let surface = terminalManager.activePane?.secondary else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { surface.window?.makeFirstResponder(surface) }
    }

    private func showAndFocusSecondary(isVisible: Bool, toggle: () -> Void) {
        if isVisible { focusSecondary() } else { toggle(); focusSecondary(delay: 0.25) }
    }

    private func toggleSecondaryTerminal() {
        withAnimation(.easeInOut(duration: 0.2)) { terminalManager.toggleSecondary(for: selectedWorktree?.id) }
    }

    private func toggleAside() {
        withAnimation(.easeInOut(duration: 0.2)) { terminalManager.toggleAside(for: selectedWorktree?.id) }
    }

    /// Restore the stored side panel tab for a worktree, or auto-select on first visit.
    private func restoreSidePanelTab(for worktree: Worktree) {
        if let stored = terminalManager.sidePanelTab(for: worktree.id),
           let tab = SidePanelTab(rawValue: stored) {
            sidePanelTab = tab
        } else if let branch = worktree.branch,
                  let task = workTaskManager.task(forWorktree: branch),
                  task.status == .inProgress {
            sidePanelTab = .task
        } else if sidePanelTab == .task {
            sidePanelTab = .todos
        }
    }

    /// Persists the current lists-column width to both `@State` and `UserDefaults`.
    ///
    /// This must be called **only at commit points** — navigating away from Planning/Prompts,
    /// or `.onDisappear`. Do NOT call from `columnWidthReader` or any other live geometry
    /// callback. The `ideal:` parameter of `.navigationSplitViewColumnWidth` re-seeds the
    /// column to that value whenever the modifier is re-evaluated with a changed value, so
    /// a live write from a drag-in-progress would snap the user's column back mid-drag.
    /// See `ColumnWidthTracker` for the non-observing live capture that feeds this commit.
    private func commitListsColumnWidth() {
        let width = max(listsColumnMinWidth, Double(columnWidthTracker.width))
        listsColumnIdealWidth = width
        UserDefaults.standard.set(width, forKey: listsColumnStorageKey)
    }

    private func selectFallback() {
        // Restore the previous selection (e.g. Tasks/Prompts) when the current
        // worktree was only "selected" because a context menu right-click
        // changed the List selection.
        if let prev = previousDetailSelection {
            previousDetailSelection = nil
            if case .worktree(let prevWt) = prev,
               let fresh = worktreeManager.worktrees.first(where: { $0.id == prevWt.id }),
               fresh.isMain || terminalManager.openWorktreeIds.contains(fresh.id) {
                detailSelection = .worktree(fresh); return
            } else if case .worktree = prev {
                // Previous worktree is closed or no longer exists — fall through to default.
            } else { detailSelection = prev; return }
        }
        detailSelection = worktreeManager.worktrees.first(where: \.isMain).map { .worktree($0) } ?? .planning
    }

    // MARK: - Refresh

    private func debouncedRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak worktreeManager] in worktreeManager?.refresh(showLoading: false) }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Worktree Removal with Hook

    private func beginRemoveWorktree(_ worktree: Worktree) {
        guard let branch = worktree.branch, let worktreePath = worktree.path else { return }

        let isSelected = selectedWorktree?.id == worktree.id
        let doRemove = { [weak worktreeManager, weak workTaskCoordinator] in
            guard let worktreeManager else { return }
            if isSelected { self.selectFallback() }
            workTaskCoordinator?.handleWorktreeRemoved(branch: branch)
            // Close surfaces before triggering the worktree removal. This sends SIGHUP
            // immediately and ensures deinit is a no-op when SwiftUI tears down the views.
            // closeWorktree removes the pane from the dict first so the restart observer
            // can't match and reopen it.
            self.terminalManager.closeWorktree(worktree.id)
            worktreeManager.removeWorktree(branch: branch)
        }

        if let cmd = worktreeManager.hookCommand(\.beforeRemove, forBranch: branch, worktreePath: worktreePath),
           let app = ghosttyApp.app {
            let surface = Ghostty.SurfaceView(app, workingDirectory: worktreePath, command: hookShellCommand(cmd))
            hookSheet = HookSheet(title: "Before remove", command: cmd, surface: surface, onContinue: doRemove, onForce: doRemove)
        } else {
            doRemove()
        }
    }

    // MARK: - Task Actions

    private func startWorkTask(_ task: WorkTask) {
        guard let app = ghosttyApp.app else { return }
        handleStartResult(workTaskCoordinator.startTask(task, app: app)) { startWorkTask(task) }
    }

    private func continueWorkTask(_ task: WorkTask) {
        guard let app = ghosttyApp.app else { return }
        handleStartResult(workTaskCoordinator.continueTask(task, app: app)) { continueWorkTask(task) }
    }

    private func handleStartResult(_ result: WorkTaskCoordinator.StartResult, isAutoStart: Bool = false, retryAction: (() -> Void)? = nil) {
        guard let app = ghosttyApp.app else { return }
        switch result {
        case .reuse(let wt):
            selectedTaskId = nil; if !isAutoStart { detailSelection = .worktree(wt) }
        case .createWorktree(let branch):
            selectedTaskId = nil; Task { await worktreeManager.createWorktree(branch: branch) }
        case .beforeRunHook(let hookCmd, let wt, let onSuccess):
            selectedTaskId = nil
            let surface = Ghostty.SurfaceView(app, workingDirectory: wt.path, command: hookShellCommand(hookCmd))
            hookSheet = HookSheet(title: "Before run", command: hookCmd, surface: surface, onContinue: {
                onSuccess(); if !isAutoStart { self.detailSelection = .worktree(wt) }
            })
        case .needsTrust:
            if isAutoStart {
                workTaskCoordinator.isAutoProcessing = false
                pendingTrustAction = { [weak workTaskCoordinator] in workTaskCoordinator?.isAutoProcessing = true }
            } else { pendingTrustAction = retryAction }
            showTrustConfirmation = true
        case .ignored: break
        }
    }

    private func handleTaskNotification(_ notification: Notification, action: (WorkTask) -> Void) {
        // Prefer task data from userInfo (sent by the task window's manager) to avoid
        // race conditions where our own manager hasn't reloaded from disk yet.
        if let task = notification.userInfo?[WorkTaskNotification.taskKey] as? WorkTask {
            action(task)
        } else if let taskId = notification.object as? UUID,
                  let task = workTaskManager.tasks.first(where: { $0.id == taskId }) {
            action(task)
        }
    }

    private func sendPromptToTerminal(_ prompt: Prompt) {
        guard let surface = terminalManager.activeMainSurface else { return }
        surface.sendPaste(prompt.content)
        surface.window?.makeFirstResponder(surface)
    }

    private func openTaskWorktree(_ task: WorkTask) {
        if let wt = workTaskCoordinator.worktreeForTask(task) { detailSelection = .worktree(wt) }
    }

    private func finishAfterCreateHook() { afterCreateHookState = .none }

    private func dismissAfterCreateOverlay() {
        guard case .blocking(let inline) = afterCreateHookState else { return }
        afterCreateHookState = .background(inline)
        inline.hook.onContinue()
    }

    private var blockingHook: InlineHook? {
        guard case .blocking(let inline) = afterCreateHookState,
              selectedWorktree?.id == inline.worktreeId else { return nil }
        return inline
    }

    // MARK: - Content Column (middle)

    @ViewBuilder
    private var contentColumn: some View {
        if detailSelection == .planning {
            WorkTaskListView(
                projectPath: worktreeManager.projectPath,
                selection: $selectedTaskId,
                editorMode: $taskEditorMode
            )
            .background(columnWidthReader)
            .navigationSplitViewColumnWidth(min: listsColumnMinWidth, ideal: listsColumnIdealWidth)
        } else if detailSelection == .prompts {
            PromptListView(
                selection: $selectedPromptId,
                editorMode: $promptEditorMode
            )
            .background(columnWidthReader)
            .navigationSplitViewColumnWidth(min: listsColumnMinWidth, ideal: listsColumnIdealWidth)
        } else {
            Color.clear
                .navigationSplitViewColumnWidth(0)
        }
    }

    private var columnWidthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear {
                    if geo.size.width >= listsColumnMinWidth { columnWidthTracker.width = geo.size.width }
                }
                .onChange(of: geo.size.width) { newValue in
                    guard newValue >= listsColumnMinWidth else { return }
                    columnWidthTracker.width = newValue
                    // Mirror to UserDefaults so new windows inherit mid-drag state. Plain
                    // UserDefaults writes aren't observed, so this won't re-seed `ideal:`.
                    UserDefaults.standard.set(Double(newValue), forKey: listsColumnStorageKey)
                }
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch ghosttyApp.readiness {
        case .loading:
            ProgressView("Loading terminal...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text("Failed to initialize terminal")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            if let pane = terminalManager.activePane,
               let worktreeId = terminalManager.activeSurfaceId,
               detailSelection?.worktree != nil {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            MainTerminalTabStrip(worktreeId: worktreeId, onCloseTab: beginCloseTab)
                            Group {
                                if pane.main.tabs.isEmpty {
                                    VStack(spacing: 12) {
                                        Image(systemName: "terminal")
                                            .font(.system(size: 28))
                                            .foregroundStyle(.tertiary)
                                        Text("⌘T for a new tab")
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else if let activeSurface = pane.main.activeSurface {
                                    FocusableTerminal(
                                        surfaceView: activeSurface,
                                        badge: "⌃1",
                                        ctrlHeld: ctrlHeld,
                                        showBorder: shouldShowFocusBorder
                                    )
                                }
                            }
                            .overlay {
                                if let inline = blockingHook {
                                    afterCreateBlockingOverlay(hook: inline.hook)
                                }
                            }

                            if let inline = afterCreateHookState.inlineHook, selectedWorktree?.id == inline.worktreeId {
                                Divider()
                                HookTerminalView(hook: inline.hook, onDismiss: finishAfterCreateHook, showHeader: afterCreateHookState.isFailed)
                                    .frame(height: terminalManager.secondaryHeight(for: selectedWorktree?.id))
                            } else if secondaryVisible {
                                VStack(spacing: 0) {
                                    Divider()
                                    Capsule()
                                        .fill(.tertiary)
                                        .frame(width: 36, height: 5)
                                        .padding(.vertical, 3)
                                }
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering {
                                        NSCursor.resizeUpDown.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            let newHeight = max(80, terminalManager.secondaryHeight(for: selectedWorktree?.id) - value.translation.height)
                                            terminalManager.setSecondaryHeight(newHeight, for: selectedWorktree?.id)
                                        }
                                )

                                FocusableTerminal(
                                    surfaceView: pane.secondary,
                                    badge: "⌃2",
                                    ctrlHeld: ctrlHeld,
                                    showBorder: shouldShowFocusBorder
                                )
                                .frame(height: terminalManager.secondaryHeight(for: selectedWorktree?.id))
                            }
                        }

                        if asideVisible {
                            Divider()
                            VStack(spacing: 0) {
                                sidePanelTabStrip

                                switch sidePanelTab {
                                case .task:
                                    if let branch = selectedWorktree?.branch {
                                        TaskAsideView(
                                            worktreeBranch: branch,
                                            projectPath: worktreeManager.projectPath,
                                            onRequestTrust: { retry in
                                                pendingTrustAction = retry
                                                showTrustConfirmation = true
                                            }
                                        )
                                    }
                                case .todos:
                                    TodosPanelView()
                                case .notes:
                                    NotesView()
                                case .prompts:
                                    PromptsView(onSendToTerminal: { prompt in
                                        sendPromptToTerminal(prompt)
                                    })
                                }
                            }
                            .frame(width: 380)
                        }
                    }

                    if let path = selectedWorktree?.path {
                        WorktreeStatusBar(
                            path: path,
                            worktree: currentWorktree,
                            showCopiedFeedback: $showCopiedFeedback
                        )
                    }
                }
            } else if detailSelection == .settings {
                ProjectSettingsView(projectPath: worktreeManager.projectPath)
            } else if detailSelection == .prompts {
                if let promptId = selectedPromptId {
                    PromptDetailView(promptId: promptId, editorMode: $promptEditorMode).id(promptId)
                } else {
                    detailPlaceholder("Select a prompt")
                }
            } else if detailSelection == .planning {
                if let taskId = selectedTaskId {
                    TaskDetailView(taskId: taskId, editorMode: $taskEditorMode).id(taskId)
                } else {
                    detailPlaceholder("Select a task")
                }
            }
        }
    }

    private func beginCloseTab(id: UUID, in worktreeId: String) {
        guard let surface = terminalManager.mainTabs(for: worktreeId).first(where: { $0.id == id })?.surface else { return }
        if surface.needsConfirmQuit {
            let title = surface.title.isEmpty ? "Terminal" : surface.title
            tabCloseQueue.append(TabCloseRequest(worktreeId: worktreeId, tabId: id, title: title))
        } else {
            terminalManager.closeMainTab(id: id, in: worktreeId)
        }
    }

    @ViewBuilder private func detailPlaceholder(_ text: String) -> some View {
        Text(text).font(.title3).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Side Panel Tab Strip

    @ViewBuilder
    private var sidePanelTabStrip: some View {
        if #available(macOS 26.0, *) {
            HStack(spacing: 2) {
                ForEach(availableSidePanelTabs, id: \.self) { tab in
                    sidePanelTabButton(for: tab)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Side panel tab")
            .padding(4)
            .glassEffect(in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
        } else {
            Picker(selection: $sidePanelTab) {
                ForEach(availableSidePanelTabs, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            } label: {
                Text("Side panel tab")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func sidePanelTabButton(for tab: SidePanelTab) -> some View {
        let isSelected = sidePanelTab == tab
        Button {
            sidePanelTab = tab
        } label: {
            Text(tab.rawValue)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background {
                    if isSelected {
                        Capsule().fill(Color.accentColor)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func afterCreateBlockingOverlay(hook: HookSheet) -> some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 16) {
                Text("Running After Create Hook").font(.title3.bold())
                Text(hook.command)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Button("Run in Background") { dismissAfterCreateOverlay() }.buttonStyle(.bordered)
            }
            .padding(32)
        }
    }
}
