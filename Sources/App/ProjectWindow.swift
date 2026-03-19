import SwiftUI

/// Per-window wrapper that resolves the project path and owns per-window state.
///
/// On launch the binding starts as `nil`; we resolve it from the last active
/// project. If no projects exist, the welcome view is shown.
struct ProjectWindow: View {
    @Binding var projectPath: String?
    @EnvironmentObject private var projectList: ProjectListManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .onChange(of: projectList.projectPaths) { paths in
                guard let path = projectPath, !paths.contains(path) else { return }
                if paths.isEmpty {
                    projectPath = nil
                } else {
                    dismiss()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let path = projectPath {
            ProjectContentView(projectPath: path)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WindowHider { window in
                    ProjectSelectorWindowController.shared.show(projectList: projectList) { [openWindow] path in
                        openWindow(value: path)
                    }
                    window?.close()
                })
        }
    }
}

/// Hides the hosting window immediately when added, then calls back.
private struct WindowHider: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowHiderView {
        let view = WindowHiderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowHiderView, context: Context) {}
}

private class WindowHiderView: NSView {
    var onWindow: ((NSWindow?) -> Void)?
    private var didFire = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !didFire else { return }
        didFire = true
        window.setFrame(.zero, display: false)
        window.orderOut(nil)
        onWindow?(window)
    }
}

/// Owns per-window `WorktreeManager` and `TerminalManager`, then renders `ContentView`.
struct ProjectContentView: View {
    let projectPath: String
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @StateObject private var worktreeManager: WorktreeManager
    @StateObject private var terminalManager: TerminalManager
    @StateObject private var claudeTodoManager = ClaudeTodoManager()
    @StateObject private var todoManager = TodoManager()
    @StateObject private var notesManager = NotesManager()
    @StateObject private var workTaskManager: WorkTaskManager
    @StateObject private var workTaskCoordinator: WorkTaskCoordinator

    init(projectPath: String) {
        self.projectPath = projectPath
        let wm = WorktreeManager(projectPath: projectPath)
        let tm = TerminalManager()
        let taskMgr = WorkTaskManager(projectPath: projectPath)
        _worktreeManager = StateObject(wrappedValue: wm)
        _terminalManager = StateObject(wrappedValue: tm)
        _workTaskManager = StateObject(wrappedValue: taskMgr)
        _workTaskCoordinator = StateObject(wrappedValue: WorkTaskCoordinator(
            workTaskManager: taskMgr,
            terminalManager: tm,
            worktreeManager: wm
        ))
    }

    var body: some View {
        ContentView()
            .environmentObject(worktreeManager)
            .environmentObject(terminalManager)
            .environmentObject(claudeTodoManager)
            .environmentObject(todoManager)
            .environmentObject(notesManager)
            .environmentObject(workTaskManager)
            .environmentObject(workTaskCoordinator)
            .onAppear {
                // Wire up agent surface check so TerminalManager skips auto-restart for agent surfaces
                terminalManager.skipAutoRestart = { [weak workTaskCoordinator] surface in
                    workTaskCoordinator?.isAgentSurface(surface) ?? false
                }
                // Start watching WORKFLOW.md for live config reload
                workTaskCoordinator.startWatching()
            }
    }
}
