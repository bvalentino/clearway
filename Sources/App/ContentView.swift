import SwiftUI
import GhosttyKit

private let maxShortcuts = 9

private let wtpadLogo: [String] = [
    "  ___       _________              _________",
    "  __ |     / /__  __/_____________ ______  /",
    "  __ | /| / /__  /  ___  __ \\  __ `/  __  /",
    "  __ |/ |/ / _  /   __  /_/ / /_/ // /_/ / ",
    "  ____/|__/  /_/    _  .___/\\__,_/ \\__,_/  ",
    "                    /_/                      ",
]

/// Marker set as the terminal title when a hook command fails.
let hookFailedMarker = "__wtpad_hook_failed__"

/// Wraps a hook command for use as a Ghostty surface `command:` parameter.
/// Runs the hook through `/bin/sh`, then drops into the user's shell so
/// the terminal stays interactive for debugging.
private func hookShellCommand(_ cmd: String) -> String {
    var shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
    if !shell.hasPrefix("/") || shell.contains("'") || shell.contains(" ") {
        shell = "/bin/sh"
    }
    return "/bin/sh -c \(shellEscape("(" + cmd + "); s=$?; if [ $s -ne 0 ]; then printf '\\e]0;\(hookFailedMarker)\\a'; exec \(shell); fi; exit $s"))"
}

/// What the detail pane is showing.
enum DetailSelection: Hashable {
    case tasks
    case prompts
    case settings
    case worktree(Worktree)

    var worktree: Worktree? {
        if case .worktree(let wt) = self { return wt }
        return nil
    }
}

private enum SidePanelTab: String, CaseIterable {
    case task = "Task"
    case todos = "Todos"
    case notes = "Notes"
    case prompts = "Prompts"
}

/// Tracks the lifecycle of an after-create hook: blocking the main terminal,
/// running in background, or inactive.
private enum AfterCreateHookState {
    case none
    case blocking(InlineHook)
    case background(InlineHook)

    var inlineHook: InlineHook? {
        switch self {
        case .none: return nil
        case .blocking(let hook), .background(let hook): return hook
        }
    }
}

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
    @State private var detailSelection: DetailSelection? = .tasks
    @State private var becomeActiveObserver: Any?
    @State private var pendingRefresh: DispatchWorkItem?
    @State private var secondaryHeight: CGFloat = 120
    @State private var showCopiedFeedback = false
    @State private var showRemoveConfirmation = false
    @State private var ctrlHeld = false
    @State private var flagsMonitor: Any?
    @State private var taskWindowObservers: [Any] = []
    @State private var worktreeShortcutsDisabled = false
    @State private var hookSheet: HookSheet?
    @State private var afterCreateHookState: AfterCreateHookState = .none
    @State private var sidePanelTab: SidePanelTab = .todos
    @State private var showTrustConfirmation = false
    @State private var pendingTrustAction: (() -> Void)?

    private var selectedWorktree: Worktree? { detailSelection?.worktree }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                detailSelection: $detailSelection,
                onRemoveWorktree: { beginRemoveWorktree($0) },
                onSearchActiveChanged: { worktreeShortcutsDisabled = $0 }
            )
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
                    }
                    .help(secondaryVisible ? "Hide secondary terminal" : "Show secondary terminal")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(action: toggleAside) {
                        Image(systemName: "sidebar.trailing")
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
                // Delay so the confirmation dialog dismisses before the hook sheet presents
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    beginRemoveWorktree(wt)
                }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    pendingTrustAction?()
                    pendingTrustAction = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingTrustAction = nil
            }
        } message: {
            Text("This project's WORKFLOW.md configures hooks that will run shell commands. Review the file before approving.")
        }
        .onChange(of: workTaskCoordinator.pendingAfterRunHook?.id) { _ in
            guard let hook = workTaskCoordinator.pendingAfterRunHook,
                  let app = ghosttyApp.app else { return }
            workTaskCoordinator.pendingAfterRunHook = nil
            let surface = Ghostty.SurfaceView(app, workingDirectory: hook.worktreePath, command: hookShellCommand(hook.command))
            hookSheet = HookSheet(title: "After run", command: hook.command, surface: surface, onContinue: {})
        }
        .navigationTitle(currentWorktree?.displayName ?? projectName)
        .navigationSubtitle(currentWorktree.flatMap { worktreeManager.subtitle(for: $0) } ?? "")
        .onChange(of: detailSelection) { [old = detailSelection] new in
            if new?.worktree == nil && terminalManager.activeSurfaceId != nil {
                terminalManager.activeSurfaceId = nil
            }
            // Save the active tab for the worktree we're leaving
            if let oldId = old?.worktree?.id {
                terminalManager.setSidePanelTab(sidePanelTab.rawValue, for: oldId)
            }
            guard let wt = new?.worktree, let app = ghosttyApp.app, wt.id != old?.worktree?.id else { return }
            terminalManager.activate(wt, app: app, projectPath: worktreeManager.projectPath)
            if case .blocking(let inline) = afterCreateHookState, inline.worktreeId == wt.id {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    inline.hook.surface.window?.makeFirstResponder(inline.hook.surface)
                }
            } else {
                focusPane(\.main)
            }
            terminalManager.clearNotification(for: wt.id)
            worktreeManager.watchTitle(forWorktreePath: wt.path)
            claudeTodoManager.setWorktreePath(wt.path)
            todoManager.setWorktreePath(wt.path)
            notesManager.setWorktreePath(wt.path)

            worktreeManager.refreshPRForWorktree(wt.id)
            restoreSidePanelTab(for: wt)
        }
        .onChange(of: worktreeManager.lastCreatedBranch) { branch in
            guard let branch else { return }
            guard let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) else { return }
            worktreeManager.lastCreatedBranch = nil

            detailSelection = .worktree(wt)

            let launchClaude = ghosttyApp.app.flatMap { app in
                workTaskCoordinator.completePendingLaunch(branch: branch, worktree: wt, app: app)
            }

            // WORKFLOW.md after_create takes precedence over ProjectSettings
            let afterCreateCmd = workTaskCoordinator.workflowAfterCreateHook()
                ?? worktreeManager.hookCommand(\.afterCreate, forBranch: branch, worktreePath: wt.path ?? "")

            if let cmd = afterCreateCmd, let app = ghosttyApp.app {
                let surface = Ghostty.SurfaceView(app, workingDirectory: wt.path, command: hookShellCommand(cmd))
                var continued = false
                let onContinueOnce: () -> Void = {
                    guard !continued else { return }
                    continued = true
                    launchClaude?()
                }
                afterCreateHookState = .blocking(InlineHook(
                    worktreeId: wt.id,
                    hook: HookSheet(title: "After create", command: cmd, surface: surface, onContinue: onContinueOnce)
                ))
            } else {
                launchClaude?()
            }
        }
        .onChange(of: worktreeManager.worktrees) { newWorktrees in
            claudeActivityMonitor.updateWorktrees(newWorktrees)
            let currentIds = Set(newWorktrees.map(\.id))
            terminalManager.pruneStale(keeping: currentIds)
            worktreeManager.prunePRStatuses(keeping: currentIds)
            if let hookWt = afterCreateHookState.inlineHook?.worktreeId, !newWorktrees.contains(where: { $0.id == hookWt }) {
                afterCreateHookState = .none
            }
            guard let selected = selectedWorktree else { return }
            let refreshed = newWorktrees.first(where: { $0.id == selected.id })
            // Update selection to the refreshed instance so its hash matches
            // the List tag — otherwise the highlight is lost after refresh.
            if let refreshed, refreshed != selected {
                detailSelection = .worktree(refreshed)
            } else if refreshed == nil {
                selectFallback()
            }
        }
        .onChange(of: terminalManager.openWorktreeIds) { openIds in
            worktreeManager.refreshPRStatuses(openIds: openIds)
            guard let selected = selectedWorktree, !selected.isMain, !openIds.contains(selected.id) else { return }
            selectFallback()
        }
        .onChange(of: currentWorktreeHasTask) { hasTask in
            if !hasTask && sidePanelTab == .task {
                sidePanelTab = .todos
            }
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
            Button("") { focusPane(\.main) }
                .keyboardShortcut("1", modifiers: .control)
                .hidden()
            Button("") { showAndFocusPane(\.secondary, isVisible: secondaryVisible, toggle: toggleSecondaryTerminal) }
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
                    debouncedRefresh()
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
        }
        .onDisappear {
            pendingRefresh?.cancel()
            pendingRefresh = nil
            if let observer = becomeActiveObserver {
                NotificationCenter.default.removeObserver(observer)
                becomeActiveObserver = nil
            }
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
                flagsMonitor = nil
            }
            ctrlHeld = false
            worktreeManager.watchTitle(forWorktreePath: nil)
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

    private var sortedWorktrees: [Worktree] {
        Worktree.sorted(worktreeManager.worktrees, openIds: terminalManager.openWorktreeIds)
    }

    private var projectName: String {
        URL(fileURLWithPath: worktreeManager.projectPath).lastPathComponent
    }

    private var currentWorktree: Worktree? {
        guard let id = selectedWorktree?.id else { return nil }
        return worktreeManager.worktrees.first(where: { $0.id == id })
    }

    private var asideVisible: Bool {
        terminalManager.isAsideVisible(for: selectedWorktree?.id)
    }

    /// Whether the current worktree has a linked task.
    private var currentWorktreeHasTask: Bool {
        guard let branch = selectedWorktree?.branch else { return false }
        return workTaskManager.task(forWorktree: branch) != nil
    }

    /// Tabs available for the current worktree — hides Task when no task is linked.
    private var availableSidePanelTabs: [SidePanelTab] {
        if currentWorktreeHasTask {
            return SidePanelTab.allCases
        }
        return SidePanelTab.allCases.filter { $0 != .task }
    }

    private var secondaryVisible: Bool {
        terminalManager.isSecondaryVisible(for: selectedWorktree?.id)
    }

    private var shouldShowFocusBorder: Bool {
        settings.showFocusBorder && (asideVisible || secondaryVisible)
    }

    // MARK: - Pane Focus & Visibility

    private func focusPane(_ keyPath: KeyPath<TerminalPane, Ghostty.SurfaceView>, delay: Double = 0) {
        guard let pane = terminalManager.activePane else { return }
        let surface = pane[keyPath: keyPath]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            surface.window?.makeFirstResponder(surface)
        }
    }

    private func showAndFocusPane(_ keyPath: KeyPath<TerminalPane, Ghostty.SurfaceView>, isVisible: Bool, toggle: () -> Void) {
        if isVisible {
            focusPane(keyPath)
        } else {
            toggle()
            focusPane(keyPath, delay: 0.25)
        }
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
                  task.status == .started {
            sidePanelTab = .task
        } else if sidePanelTab == .task {
            sidePanelTab = .todos
        }
    }

    private func selectFallback() {
        if let main = worktreeManager.worktrees.first(where: \.isMain) {
            detailSelection = .worktree(main)
        } else {
            detailSelection = .tasks
        }
    }

    // MARK: - Refresh

    private func debouncedRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak worktreeManager, weak terminalManager] in
            guard let worktreeManager, let terminalManager else { return }
            worktreeManager.refresh(showLoading: false)
            // Delay PR refresh so it doesn't compete with the worktree UI update.
            // Don't clear the cache — the 60s TTL handles expiry naturally. This avoids
            // spawning a gh process for every open worktree on each focus event.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                worktreeManager.refreshPRStatuses(openIds: terminalManager.openWorktreeIds)
            }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Worktree Removal with Hook

    private func beginRemoveWorktree(_ worktree: Worktree) {
        guard let branch = worktree.branch, let worktreePath = worktree.path else { return }

        let doRemove = { [weak worktreeManager, weak workTaskCoordinator] in
            guard let worktreeManager else { return }
            self.selectFallback()
            workTaskCoordinator?.handleWorktreeRemoved(branch: branch)
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

    private func handleStartResult(_ result: WorkTaskCoordinator.StartResult, retryAction: (() -> Void)? = nil) {
        guard let app = ghosttyApp.app else { return }
        switch result {
        case .reuse(let wt):
            detailSelection = .worktree(wt)
        case .createWorktree(let branch):
            Task { await worktreeManager.createWorktree(branch: branch) }
        case .beforeRunHook(let hookCmd, let wt, let onSuccess):
            let surface = Ghostty.SurfaceView(app, workingDirectory: wt.path, command: hookShellCommand(hookCmd))
            hookSheet = HookSheet(title: "Before run", command: hookCmd, surface: surface, onContinue: {
                onSuccess()
                detailSelection = .worktree(wt)
            })
        case .needsTrust:
            pendingTrustAction = retryAction
            showTrustConfirmation = true
        case .ignored:
            break
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
        guard let surface = terminalManager.activePane?.main else { return }
        surface.sendCommand(prompt.content)
        surface.window?.makeFirstResponder(surface)
    }

    private func openTaskWorktree(_ task: WorkTask) {
        if let wt = workTaskCoordinator.worktreeForTask(task) {
            detailSelection = .worktree(wt)
        }
    }

    private func finishAfterCreateHook() {
        afterCreateHookState = .none
    }

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
            if let pane = terminalManager.activePane, detailSelection?.worktree != nil {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            FocusableTerminal(
                                surfaceView: pane.main,
                                badge: "⌃1",
                                ctrlHeld: ctrlHeld,
                                showBorder: shouldShowFocusBorder
                            )
                            .overlay {
                                if let inline = blockingHook {
                                    afterCreateBlockingOverlay(hook: inline.hook)
                                }
                            }

                            if let inline = afterCreateHookState.inlineHook, selectedWorktree?.id == inline.worktreeId {
                                Divider()
                                HookTerminalView(hook: inline.hook, onDismiss: finishAfterCreateHook, showHeader: false)
                                    .frame(height: secondaryHeight)
                            } else if secondaryVisible {
                                Divider()
                                    .padding(.vertical, 2)
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
                                                secondaryHeight = max(80, secondaryHeight - value.translation.height)
                                            }
                                    )

                                FocusableTerminal(
                                    surfaceView: pane.secondary,
                                    badge: "⌃2",
                                    ctrlHeld: ctrlHeld,
                                    showBorder: shouldShowFocusBorder
                                )
                                .frame(height: secondaryHeight)
                            }
                        }

                        if asideVisible {
                            Divider()
                            VStack(spacing: 0) {
                                Picker("", selection: $sidePanelTab) {
                                    ForEach(availableSidePanelTabs, id: \.self) { tab in
                                        Text(tab.rawValue).tag(tab)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)

                                Divider()

                                switch sidePanelTab {
                                case .task:
                                    if let branch = selectedWorktree?.branch {
                                        TaskAsideView(
                                            worktreeBranch: branch,
                                            projectPath: worktreeManager.projectPath,
                                            onContinue: { continueWorkTask($0) },
                                            onRestart: { startWorkTask($0) },
                                            onMarkDone: { workTaskManager.setStatus($0, to: .done) }
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
                        HStack(spacing: 0) {
                            Text(showCopiedFeedback ? "Copied!" : path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(showCopiedFeedback ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .animation(.easeInOut(duration: 0.15), value: showCopiedFeedback)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(path, forType: .string)
                                    showCopiedFeedback = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                        showCopiedFeedback = false
                                    }
                                }
                            Spacer()
                            if let pr = selectedWorktree.flatMap({ worktreeManager.worktreePRs[$0.id] }) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(pr.state.color)
                                        .frame(width: 6, height: 6)
                                    Text("#\(pr.number)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary)
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    Text(pr.title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let url = URL(string: pr.url), url.scheme == "https" {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                        .background(.bar)
                        .overlay(alignment: .top) {
                            Divider()
                        }
                    }
                }
            } else if detailSelection == .settings {
                ProjectSettingsView(projectPath: worktreeManager.projectPath)
            } else if detailSelection == .prompts {
                PromptsView()
            } else {
                WorkTaskListView(projectPath: worktreeManager.projectPath)
            }
        }
    }

    @ViewBuilder
    private func afterCreateBlockingOverlay(hook: HookSheet) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            VStack(spacing: 16) {
                Text("Running After Create Hook")
                    .font(.title3.bold())

                Text(hook.command)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Button("Run in Background") {
                    dismissAfterCreateOverlay()
                }
                .buttonStyle(.bordered)
            }
            .padding(32)
        }
    }
}

/// A terminal pane that observes its surface's focus state and draws a border when focused.
private struct FocusableTerminal: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let badge: String
    let ctrlHeld: Bool
    let showBorder: Bool

    var body: some View {
        TerminalSurface(surfaceView: surfaceView)
            .overlay(alignment: .topLeading) {
                Text(badge)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                    .allowsHitTesting(false)
                    .opacity(ctrlHeld ? 1 : 0)
            }
            .overlay {
                if showBorder && surfaceView.focused {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}
