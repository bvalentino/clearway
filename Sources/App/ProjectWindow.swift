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

/// Runs `perform` when the window hosting it closes.
///
/// The one door a per-window teardown can hang off: closing a project window sends nothing through
/// `closeWorktree` or `removeSurface`, and no window delegate of Clearway's own is free — the
/// hosting window's delegate slot already holds `CloseConfirmationDelegate`, installed a layer up
/// where the window's managers are out of reach.
struct WindowCloseHandler: NSViewRepresentable {
    let perform: @MainActor @Sendable () -> Void

    func makeNSView(context: Context) -> WindowCloseHandlerView {
        let view = WindowCloseHandlerView()
        view.perform = perform
        return view
    }

    func updateNSView(_ nsView: WindowCloseHandlerView, context: Context) {}
}

/// Observes `willCloseNotification` on whatever window it lands in, and stops observing when it
/// leaves one. Internal, not private, because it is the only testable half of the door: a bare
/// `NSWindow` reaches it, while everything it retires needs a `ghostty_app_t`.
///
/// The observation holds `perform` rather than the view, so the retirement still runs when the
/// close has already released the view hierarchy that owned it.
final class WindowCloseHandlerView: NSView {
    var perform: (@MainActor @Sendable () -> Void)?
    private var observation: NotificationObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let perform else {
            observation = nil
            return
        }
        observation = NotificationObservation(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in perform() }
        })
    }
}

/// Owns per-window `WorktreeManager` and `TerminalManager`, then renders `ContentView`.
struct ProjectContentView: View {
    let projectPath: String
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @EnvironmentObject private var settings: SettingsManager
    @StateObject private var worktreeManager: WorktreeManager
    @StateObject private var terminalManager: TerminalManager
    @StateObject private var groupManager: WorktreeGroupManager
    @StateObject private var todoManager = TodoManager()
    @StateObject private var workTaskManager: WorkTaskManager
    @StateObject private var workTaskCoordinator: WorkTaskCoordinator
    @StateObject private var promptManager: PromptManager
    @StateObject private var savedCommandManager: SavedCommandManager

    init(projectPath: String) {
        self.projectPath = projectPath
        let wm = WorktreeManager(projectPath: projectPath)
        let tm = TerminalManager()
        let taskMgr = WorkTaskManager(projectPath: projectPath)
        // Let the task manager route files to (and merge-load from) live worktrees without
        // depending on WorktreeManager. The closure reads the published list at call time.
        taskMgr.worktreeResolver = { [weak wm] in wm?.taskResolverPairs() ?? [] }
        let gm = WorktreeGroupManager(projectPath: projectPath)
        let promptsDir = UserDefaults.standard.string(forKey: SettingsKey.promptsDirectory) ?? SettingsManager.defaultPromptsDirectory
        _worktreeManager = StateObject(wrappedValue: wm)
        _terminalManager = StateObject(wrappedValue: tm)
        _groupManager = StateObject(wrappedValue: gm)
        _workTaskManager = StateObject(wrappedValue: taskMgr)
        _workTaskCoordinator = StateObject(wrappedValue: WorkTaskCoordinator(
            workTaskManager: taskMgr,
            terminalManager: tm,
            worktreeManager: wm
        ))
        _promptManager = StateObject(wrappedValue: PromptManager(directory: promptsDir))
        _savedCommandManager = StateObject(wrappedValue: SavedCommandManager(projectPath: projectPath))
    }

    var body: some View {
        ContentView()
            .environmentObject(worktreeManager)
            .environmentObject(terminalManager)
            .environmentObject(todoManager)
            .environmentObject(workTaskManager)
            .environmentObject(workTaskCoordinator)
            .environmentObject(promptManager)
            .environmentObject(groupManager)
            .environmentObject(savedCommandManager)
            .focusedSceneObject(groupManager)
            .task { await savedCommandManager.load() }
            .onAppear {
                promptManager.startWatching()
            }
            .onChange(of: settings.promptsDirectory) { newValue in
                promptManager.setDirectory(newValue)
            }
            .background(WindowCloseHandler { [terminalManager] in
                terminalManager.retireAllSurfaces()
            })
    }
}
