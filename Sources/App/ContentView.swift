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

struct ContentView: View {
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var settings: SettingsManager
    @State private var selectedWorktree: Worktree?
    @State private var becomeActiveObserver: Any?
    @State private var lastRefreshDate = Date.distantPast
    @State private var secondaryHeight: CGFloat = 120
    @State private var showCopiedFeedback = false
    @State private var showingCreateSheet = false
    @State private var showRemoveConfirmation = false
    @State private var ctrlHeld = false
    @State private var flagsMonitor: Any?
    @State private var worktreeShortcutsDisabled = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedWorktree: $selectedWorktree,
                showingCreateSheet: $showingCreateSheet,
                onSearchActiveChanged: { worktreeShortcutsDisabled = $0 }
            )
        } detail: {
            detailView
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateWorktreeSheet()
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
                if let branch = currentWorktree?.branch {
                    selectedWorktree = worktreeManager.worktrees.first(where: \.isMain)
                    worktreeManager.removeWorktree(branch: branch)
                }
            }
        } message: {
            Text("This will delete the worktree and its working directory.")
        }
        .navigationTitle(currentWorktree?.displayName ?? projectName)
        .navigationSubtitle(currentWorktree.flatMap { worktreeManager.subtitle(for: $0) } ?? "")
        .onChange(of: selectedWorktree) { newWorktree in
            guard let wt = newWorktree, let app = ghosttyApp.app else { return }
            terminalManager.activate(wt, app: app, projectPath: worktreeManager.projectPath)
            terminalManager.clearNotification(for: wt.id)
            focusPane(\.main)
            worktreeManager.watchTitle(forWorktreePath: wt.path)
        }
        .onChange(of: worktreeManager.lastCreatedBranch) { branch in
            guard let branch else { return }
            selectedWorktree = worktreeManager.worktrees.first(where: { $0.branch == branch })
            worktreeManager.lastCreatedBranch = nil
        }
        .onChange(of: worktreeManager.worktrees) { newWorktrees in
            terminalManager.pruneStale(keeping: Set(newWorktrees.map(\.id)))
            if let selected = selectedWorktree, !newWorktrees.contains(where: { $0.id == selected.id }) {
                selectedWorktree = newWorktrees.first(where: \.isMain)
            }
        }
        .background {
            // Cmd+N: switch worktrees
            if !worktreeShortcutsDisabled {
                ForEach(Array(worktreeManager.worktrees.prefix(maxShortcuts).enumerated()), id: \.element.id) { index, wt in
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
        }
    }

    // MARK: - Title

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
                            FocusableTerminal(
                                surfaceView: pane.side,
                                badge: "⌃3",
                                ctrlHeld: ctrlHeld,
                                showBorder: shouldShowFocusBorder
                            )
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
