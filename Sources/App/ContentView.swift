import SwiftUI
import GhosttyKit

struct ContentView: View {
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @State private var selectedWorktree: Worktree?
    @State private var becomeActiveObserver: Any?
    @State private var lastRefreshDate = Date.distantPast
    @State private var showSideTerminal = true
    @State private var showSecondaryTerminal = true
    @State private var secondaryHeight: CGFloat = 120
    @State private var showCopiedFeedback = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedWorktree: $selectedWorktree,
                onRunCommand: runCommandInTerminal
            )
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSecondaryTerminal.toggle()
                    }
                } label: {
                    Image(systemName: "rectangle.bottomhalf.inset.filled")
                }
                .help(showSecondaryTerminal ? "Hide secondary terminal" : "Show secondary terminal")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSideTerminal.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help(showSideTerminal ? "Hide side terminal" : "Show side terminal")
            }
        }
        .navigationTitle(currentWorktree?.displayName ?? "wtpad")
        .navigationSubtitle(currentWorktree?.commit.message ?? "")
        .onChange(of: selectedWorktree) { newWorktree in
            guard let wt = newWorktree, let app = ghosttyApp.app else { return }
            let pane = terminalManager.activate(wt, app: app)
            DispatchQueue.main.async {
                pane.main.window?.makeFirstResponder(pane.main)
            }
        }
        .onChange(of: worktreeManager.activeProjectPath) { _ in
            selectedWorktree = nil
        }
        .onChange(of: worktreeManager.worktrees) { newWorktrees in
            terminalManager.pruneStale(keeping: Set(newWorktrees.map(\.id)))
            if selectedWorktree == nil || !newWorktrees.contains(where: { $0.id == selectedWorktree?.id }) {
                selectedWorktree = newWorktrees.first(where: \.isCurrent)
                    ?? newWorktrees.first(where: \.isMain)
            }
        }
        .onAppear {
            if selectedWorktree == nil {
                selectedWorktree = worktreeManager.worktrees.first(where: \.isCurrent)
                    ?? worktreeManager.worktrees.first(where: \.isMain)
            }

            becomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [self] _ in
                debouncedRefresh()
            }
        }
        .onDisappear {
            if let observer = becomeActiveObserver {
                NotificationCenter.default.removeObserver(observer)
                becomeActiveObserver = nil
            }
        }
    }

    // MARK: - Title

    private var currentWorktree: Worktree? {
        guard let id = selectedWorktree?.id else { return nil }
        return worktreeManager.worktrees.first(where: { $0.id == id })
    }

    // MARK: - Command Execution

    private func runCommandInTerminal(command: String, worktree: Worktree) {
        guard let app = ghosttyApp.app else { return }
        let pane = terminalManager.activate(worktree, app: app)
        selectedWorktree = worktree
        let cmd = command + "\n"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pane.main.sendText(cmd)
        }
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
                            TerminalSurface(surfaceView: pane.main)

                            if showSecondaryTerminal {
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

                                TerminalSurface(surfaceView: pane.secondary)
                                    .frame(height: secondaryHeight)
                            }
                        }

                        if showSideTerminal {
                            Divider()
                            TerminalSurface(surfaceView: pane.side)
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
            } else if worktreeManager.worktrees.isEmpty && worktreeManager.activeProjectPath == nil {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Add a project to get started")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a worktree")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
