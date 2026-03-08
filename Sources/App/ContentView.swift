import SwiftUI
import GhosttyKit

struct ContentView: View {
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @State private var selectedWorktree: Worktree?
    @State private var becomeActiveObserver: Any?
    @State private var lastRefreshDate = Date.distantPast

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedWorktree: $selectedWorktree,
                onRunCommand: runCommandInTerminal
            )
        } detail: {
            detailView
        }
        .onChange(of: selectedWorktree) { newWorktree in
            guard let wt = newWorktree, let app = ghosttyApp.app else { return }
            let pane = terminalManager.activate(wt, app: app)
            DispatchQueue.main.async {
                pane.main.window?.makeFirstResponder(pane.main)
            }
        }
        .onChange(of: worktreeManager.worktrees) { newWorktrees in
            terminalManager.pruneStale(keeping: Set(newWorktrees.map(\.id)))
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
                    HSplitView {
                        VSplitView {
                            TerminalSurface(surfaceView: pane.main)
                            TerminalSurface(surfaceView: pane.secondary)
                                .frame(minHeight: 100)
                        }
                        .frame(minWidth: 300)

                        TerminalSurface(surfaceView: pane.side)
                            .frame(minWidth: 200)
                    }

                    if let path = selectedWorktree?.path {
                        HStack {
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                        .background(.bar)
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
