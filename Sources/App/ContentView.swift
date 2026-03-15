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

private enum SidePanelTab: String, CaseIterable {
    case wtpad = "wtpad"
    case tasks = "Tasks"
    case notes = "Notes"
}

struct ContentView: View {
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var claudeTaskManager: ClaudeTaskManager
    @EnvironmentObject private var userTaskManager: UserTaskManager
    @EnvironmentObject private var notesManager: NotesManager
    @EnvironmentObject private var settings: SettingsManager
    @State private var selectedWorktree: Worktree?
    @State private var becomeActiveObserver: Any?
    @State private var lastRefreshDate = Date.distantPast
    @State private var secondaryHeight: CGFloat = 120
    @State private var showCopiedFeedback = false
    @State private var showRemoveConfirmation = false
    @State private var ctrlHeld = false
    @State private var flagsMonitor: Any?
    @State private var worktreeShortcutsDisabled = false
    @State private var hookSheet: HookSheet?
    @State private var sidePanelTab: SidePanelTab = .wtpad

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedWorktree: $selectedWorktree,
                onRemoveWorktree: { beginRemoveWorktree($0) },
                onSearchActiveChanged: { worktreeShortcutsDisabled = $0 }
            )
        } detail: {
            detailView
        }
        .sheet(item: $hookSheet) { hook in
            HookTerminalSheet(hook: hook, surface: hook.surface)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showRemoveConfirmation = true
                } label: {
                    Image(systemName: "archivebox")
                }
                .help("Remove worktree")
                .disabled(currentWorktree == nil || currentWorktree?.isMain == true || currentWorktree?.branch == nil)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleSecondaryTerminal) {
                    Image(systemName: "rectangle.bottomhalf.inset.filled")
                }
                .help(secondaryVisible ? "Hide secondary terminal" : "Show secondary terminal")
                .disabled(selectedWorktree == nil)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleSideTerminal) {
                    Image(systemName: "sidebar.trailing")
                }
                .help(sideVisible ? "Hide side terminal" : "Show side terminal")
                .disabled(selectedWorktree == nil)
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
            Text("This will delete the worktree and its working directory.")
        }
        .navigationTitle(currentWorktree?.displayName ?? projectName)
        .navigationSubtitle(currentWorktree.flatMap { worktreeManager.subtitle(for: $0) } ?? "")
        .onChange(of: selectedWorktree) { [oldId = selectedWorktree?.id] newWorktree in
            guard let wt = newWorktree, let app = ghosttyApp.app, wt.id != oldId else { return }
            terminalManager.activate(wt, app: app, projectPath: worktreeManager.projectPath)
            terminalManager.clearNotification(for: wt.id)
            focusPane(\.main)
            worktreeManager.watchTitle(forWorktreePath: wt.path)
            claudeTaskManager.setWorktreePath(wt.path)
            userTaskManager.setWorktreePath(wt.path)
            notesManager.setWorktreePath(wt.path)
        }
        .onChange(of: worktreeManager.lastCreatedBranch) { branch in
            guard let branch else { return }
            guard let wt = worktreeManager.worktrees.first(where: { $0.branch == branch }) else { return }
            worktreeManager.lastCreatedBranch = nil

            selectedWorktree = wt

            if let cmd = worktreeManager.hookCommand(\.afterCreate, forBranch: branch, worktreePath: wt.path ?? ""),
               let app = ghosttyApp.app {
                let surface = Ghostty.SurfaceView(app, workingDirectory: wt.path, command: hookShellCommand(cmd))
                hookSheet = HookSheet(title: "After create", command: cmd, surface: surface) {}
            }
        }
        .onChange(of: worktreeManager.worktrees) { newWorktrees in
            terminalManager.pruneStale(keeping: Set(newWorktrees.map(\.id)))
            guard let selected = selectedWorktree else { return }
            let refreshed = newWorktrees.first(where: { $0.id == selected.id })
            // Update selection to the refreshed instance so its hash matches
            // the List tag — otherwise the highlight is lost after refresh.
            if let refreshed, refreshed != selected {
                selectedWorktree = refreshed
            } else if refreshed == nil {
                selectedWorktree = newWorktrees.first(where: \.isMain)
            }
        }
        .onChange(of: terminalManager.openWorktreeIds) { openIds in
            guard let selected = selectedWorktree, !selected.isMain, !openIds.contains(selected.id) else { return }
            selectedWorktree = worktreeManager.worktrees.first(where: \.isMain)
        }
        .background {
            // Cmd+N: switch worktrees (sorted order matches sidebar)
            if !worktreeShortcutsDisabled {
                ForEach(Array(sortedWorktrees.prefix(maxShortcuts).enumerated()), id: \.element.id) { index, wt in
                    Button("") {
                        selectedWorktree = wt
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
            Button("") { showAndFocusPane(\.side, isVisible: sideVisible, toggle: toggleSideTerminal) }
                .keyboardShortcut("3", modifiers: .control)
                .hidden()

            // Cmd+Ctrl+N: toggle pane visibility
            Button("") { toggleSecondaryTerminal() }
                .keyboardShortcut("2", modifiers: [.command, .control])
                .hidden()
            Button("") { toggleSideTerminal() }
                .keyboardShortcut("3", modifiers: [.command, .control])
                .hidden()
        }
        .onAppear {
            claudeTaskManager.setWorktreePath(selectedWorktree?.path)
            userTaskManager.setWorktreePath(selectedWorktree?.path)
            notesManager.setWorktreePath(selectedWorktree?.path)
            if becomeActiveObserver == nil {
                becomeActiveObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [self] _ in
                    debouncedRefresh()
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
            claudeTaskManager.stopWatching()
            userTaskManager.stopWatching()
            notesManager.stopWatching()
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

    private var sideVisible: Bool {
        terminalManager.isSideVisible(for: selectedWorktree?.id)
    }

    private var secondaryVisible: Bool {
        terminalManager.isSecondaryVisible(for: selectedWorktree?.id)
    }

    private var shouldShowFocusBorder: Bool {
        settings.showFocusBorder && (sideVisible || secondaryVisible)
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

    private func toggleSideTerminal() {
        withAnimation(.easeInOut(duration: 0.2)) { terminalManager.toggleSide(for: selectedWorktree?.id) }
    }

    // MARK: - Refresh

    private func debouncedRefresh() {
        let now = Date()
        guard now.timeIntervalSince(lastRefreshDate) > 2 else { return }
        lastRefreshDate = now
        worktreeManager.refresh()
    }

    // MARK: - Worktree Removal with Hook

    private func beginRemoveWorktree(_ worktree: Worktree) {
        guard let branch = worktree.branch, let worktreePath = worktree.path else { return }

        if let cmd = worktreeManager.hookCommand(\.beforeRemove, forBranch: branch, worktreePath: worktreePath),
           let app = ghosttyApp.app {
            let surface = Ghostty.SurfaceView(app, workingDirectory: worktreePath, command: hookShellCommand(cmd))
            let doRemove = { [weak worktreeManager] in
                guard let worktreeManager else { return }
                selectedWorktree = worktreeManager.worktrees.first(where: \.isMain)
                worktreeManager.removeWorktree(branch: branch)
            }
            hookSheet = HookSheet(title: "Before remove", command: cmd, surface: surface, onContinue: doRemove, onForce: doRemove)
        } else {
            selectedWorktree = worktreeManager.worktrees.first(where: \.isMain)
            worktreeManager.removeWorktree(branch: branch)
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
            if let pane = terminalManager.activePane {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            FocusableTerminal(
                                surfaceView: pane.main,
                                badge: "⌃1",
                                ctrlHeld: ctrlHeld,
                                showBorder: shouldShowFocusBorder
                            )

                            if secondaryVisible {
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

                        if sideVisible {
                            Divider()
                            VStack(spacing: 0) {
                                Picker("", selection: $sidePanelTab) {
                                    ForEach(SidePanelTab.allCases, id: \.self) { tab in
                                        Text(tab.rawValue).tag(tab)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)

                                Divider()

                                switch sidePanelTab {
                                case .wtpad:
                                    if WtpadBinary.isInPATH {
                                        FocusableTerminal(
                                            surfaceView: pane.side,
                                            badge: "⌃3",
                                            ctrlHeld: ctrlHeld,
                                            showBorder: shouldShowFocusBorder
                                        )
                                    } else {
                                        WtpadInstallView {
                                            TerminalManager.launchWtpad(in: pane.side)
                                        }
                                    }
                                case .tasks:
                                    TasksPanelView()
                                case .notes:
                                    NotesView()
                                }
                            }
                            .frame(width: 380)
                        }
                    }

                    if let path = selectedWorktree?.path {
                        HStack {
                            Text(showCopiedFeedback ? "Copied!" : path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(showCopiedFeedback ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .animation(.easeInOut(duration: 0.15), value: showCopiedFeedback)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                        .background(.bar)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                            showCopiedFeedback = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                showCopiedFeedback = false
                            }
                        }
                        .overlay(alignment: .top) {
                            Divider()
                        }
                    }
                }
            } else {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(wtpadLogo, id: \.self) { line in
                            Text(line)
                        }
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    Text("Select a worktree")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
