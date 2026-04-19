import SwiftUI
import GhosttyKit
import Sparkle

/// Configure environment and call ghostty_init once at process startup.
/// Prefers the bundled resources dir (populated by the ghostty post-build
/// phase in project.yml); falls back to an installed Ghostty.app only when
/// the candidate passes the same sanity checks libghostty's runtime relies on.
private let ghosttyInitResult: Bool = {
    // Once resources_dir is set, libghostty derives TERMINFO from its parent
    // and unconditionally sets TERM=xterm-ghostty (ghostty/src/termio/Exec.zig).
    // Accepting a partially-populated candidate would leave ncurses apps
    // (vim, less, tmux) pointing at a missing terminfo entry, so require the
    // sentinels the runtime actually depends on before selecting one.
    func isValidResourcesDir(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let themes = (path as NSString).appendingPathComponent("themes")
        let shellIntegration = (path as NSString).appendingPathComponent("shell-integration")
        let terminfo = (parent as NSString)
            .appendingPathComponent("terminfo/78/xterm-ghostty")
        return access(themes, R_OK) == 0
            && access(shellIntegration, R_OK) == 0
            && access(terminfo, R_OK) == 0
    }

    if getenv("GHOSTTY_RESOURCES_DIR") == nil {
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true).path {
            candidates.append(bundled)
        }
        candidates.append("/Applications/Ghostty.app/Contents/Resources/ghostty")
        candidates.append(
            NSString(string: "~/Applications/Ghostty.app/Contents/Resources/ghostty")
                .expandingTildeInPath
        )
        if let path = candidates.first(where: isValidResourcesDir) {
            setenv("GHOSTTY_RESOURCES_DIR", path, 1)
        } else {
            Ghostty.logger.warning(
                "No valid Ghostty resources dir found; themes and shell integration will be unavailable"
            )
        }
    }

    return ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
}()

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Suppress AppKit's native window-tabbing menu items (Show Tab Bar,
        // Show All Tabs, Merge All Windows). We have our own terminal tab model.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // When the last window was closed, termination is triggered by
        // applicationShouldTerminateAfterLastWindowClosed — the window-level
        // close confirmation already handled prompting, so skip here.
        guard sender.windows.contains(where: \.isVisible),
              TerminalManager.needsConfirmQuit else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit Clearway?"
        alert.informativeText = "There are processes still running in your terminals."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        TerminalManager.closeAllManagers()
    }
}

/// Window delegate that confirms close when terminals have running processes.
@MainActor
final class CloseConfirmationDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard TerminalManager.needsConfirmQuit else { return true }

        let alert = NSAlert()
        alert.messageText = "Close terminal sessions?"
        alert.informativeText = "There are processes still running in your terminals."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: sender) { response in
            if response == .alertFirstButtonReturn {
                sender.close()
            }
        }
        return false
    }
}

/// Installs a `CloseConfirmationDelegate` on the hosting window.
struct CloseConfirmation: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let delegate = CloseConfirmationDelegate()
            // Keep delegate alive for the window's lifetime.
            objc_setAssociatedObject(window, "closeConfirmationDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            window.delegate = delegate
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@main
struct ClearwayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var ghosttyApp: Ghostty.App
    @StateObject private var projectList = ProjectListManager()
    @StateObject private var settings: SettingsManager
    @StateObject private var caffeine = CaffeineManager()
    @AppStorage("showFrontmatter") private var showFrontmatter: Bool = false
    private let updaterController: SPUStandardUpdaterController

    init() {
        precondition(ghosttyInitResult, "ghostty_init failed")
        // SettingsManager.init applies the stored color scheme to NSApp, so Ghostty.App
        // picks up the correct effective appearance when it reads it during its own init.
        _settings = StateObject(wrappedValue: SettingsManager())
        _ghosttyApp = StateObject(wrappedValue: Ghostty.App())
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(for: String.self) { $projectPath in
            ProjectWindow(projectPath: $projectPath)
                .background(CloseConfirmation())
                .environmentObject(ghosttyApp)
                .environmentObject(projectList)
                .environmentObject(caffeine)
                .clearwayChrome(settings)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Clearway") {
                    AboutWindowController.shared.show()
                }
                CheckForUpdatesView(updater: updaterController.updater)
                Divider()
                Button("Ghostty Settings\u{2026}") {
                    ghosttyApp.openConfigFile()
                }
                Button("Reload Configuration") {
                    ghosttyApp.reloadConfiguration()
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button {
                    showProjectSelector()
                } label: {
                    Label("New Window", systemImage: "macwindow.stack")
                }
                .keyboardShortcut("n", modifiers: .command)
                NewGroupCommand()
                NewTabMenuItem()
                NewShellTabMenuItem()
                NewTaskMenuItem()
            }
            CommandGroup(after: .sidebar) {
                Toggle(isOn: $showFrontmatter) {
                    Label("Show Frontmatter", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }

        WindowGroup(for: NoteIdentifier.self) { $identifier in
            if let identifier {
                NoteWindow(identifier: identifier)
                    .clearwayChrome(settings)
            }
        }
        .defaultSize(width: 500, height: 500)
        .windowStyle(.titleBar)

        WindowGroup(for: WorkTaskIdentifier.self) { $identifier in
            if let identifier {
                WorkTaskWindow(identifier: identifier)
                    .clearwayChrome(settings)
            }
        }
        .defaultSize(width: 600, height: 450)
        .windowStyle(.titleBar)

        WindowGroup(for: PromptIdentifier.self) { $identifier in
            if let identifier {
                PromptWindow(identifier: identifier)
                    .clearwayChrome(settings)
            }
        }
        .defaultSize(width: 600, height: 450)
        .windowStyle(.titleBar)

        Settings {
            SettingsView(settings: settings)
                .preferredColorScheme(settings.colorScheme.swiftUIColorScheme)
        }
    }

    private func showProjectSelector() {
        ProjectSelectorWindowController.shared.show(projectList: projectList) { [openWindow] path in
            openWindow(value: path)
        }
    }
}

extension View {
    /// Applies Clearway's shared window chrome: the user's color-scheme preference
    /// and the settings environment dependency.
    func clearwayChrome(_ settings: SettingsManager) -> some View {
        environmentObject(settings)
            .preferredColorScheme(settings.colorScheme.swiftUIColorScheme)
    }
}

/// Focused-value key for the active window's "new terminal tab" action.
/// Set by the worktree detail view when a worktree is selected; `nil` otherwise.
private struct NewTabActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newTabAction: (() -> Void)? {
        get { self[NewTabActionKey.self] }
        set { self[NewTabActionKey.self] = newValue }
    }
}

/// File menu item that creates a new terminal tab in the focused worktree,
/// disabled when no worktree is active.
private struct NewTabMenuItem: View {
    @FocusedValue(\.newTabAction) private var action

    var body: some View {
        Button("New Tab") { action?() }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(action == nil)
    }
}

/// Focused-value key for the active window's "new shell tab" action (Cmd+Shift+T).
private struct NewShellTabActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newShellTabAction: (() -> Void)? {
        get { self[NewShellTabActionKey.self] }
        set { self[NewShellTabActionKey.self] = newValue }
    }
}

/// File menu item that creates a new tab running a login shell directly,
/// bypassing the prompt launcher. Disabled when no worktree is active.
private struct NewShellTabMenuItem: View {
    @FocusedValue(\.newShellTabAction) private var action

    var body: some View {
        Button("New Shell Tab") { action?() }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(action == nil)
    }
}

/// Focused-value key for the active window's "new task" action.
/// Set by ContentView; `nil` when no project window is focused.
private struct NewTaskActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newTaskAction: (() -> Void)? {
        get { self[NewTaskActionKey.self] }
        set { self[NewTaskActionKey.self] = newValue }
    }
}

/// File menu item that creates a new backlog task in the focused project window,
/// disabled when no project window is active.
private struct NewTaskMenuItem: View {
    @FocusedValue(\.newTaskAction) private var action

    var body: some View {
        Button("New Task") { action?() }
            .disabled(action == nil)
    }
}

/// File menu item that opens the New Group sheet in the focused project window,
/// disabled when no project window is key.
private struct NewGroupCommand: View {
    @FocusedObject private var groupManager: WorktreeGroupManager?

    var body: some View {
        Button {
            // Scope the post to the focused window's manager so only that window's
            // sidebar presents the sheet — otherwise every mounted sidebar reacts.
            NotificationCenter.default.post(name: .clearwayNewGroup, object: groupManager)
        } label: {
            Label("New Group\u{2026}", systemImage: "folder.badge.plus")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(groupManager == nil)
    }
}

/// Menu item that drives Sparkle's "Check for Updates…" flow and
/// disables itself while an update check is already in progress.
private struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates\u{2026}") {
            updater.checkForUpdates()
        }
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

/// Observes `SPUUpdater.canCheckForUpdates` so the menu item reflects
/// Sparkle's internal "check already in progress" state.
@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private var observation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        observation = updater.observe(\.canCheckForUpdates, options: [.initial]) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }
}
