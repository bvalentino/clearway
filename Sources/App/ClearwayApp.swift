import SwiftUI
import GhosttyKit
import Sparkle

/// Configure environment and call ghostty_init once at process startup,
/// before any config/app is created.
private let ghosttyInitResult: Bool = {
    // Set GHOSTTY_RESOURCES_DIR before ghostty_init so libghostty can find
    // themes, shaders, etc. from the installed Ghostty.app bundle.
    if getenv("GHOSTTY_RESOURCES_DIR") == nil {
        let candidates = [
            "/Applications/Ghostty.app/Contents/Resources/ghostty",
            NSString(string: "~/Applications/Ghostty.app/Contents/Resources/ghostty")
                .expandingTildeInPath,
        ]
        for path in candidates {
            if access(path, R_OK) == 0 {
                setenv("GHOSTTY_RESOURCES_DIR", path, 1)
                break
            }
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
    @StateObject private var settings = SettingsManager()
    @AppStorage("showFrontmatter") private var showFrontmatter: Bool = false
    private let updaterController: SPUStandardUpdaterController

    init() {
        precondition(ghosttyInitResult, "ghostty_init failed")
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
                .environmentObject(settings)
                .preferredColorScheme(.dark)
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
                Button("New Window") {
                    showProjectSelector()
                }
                .keyboardShortcut("n", modifiers: .command)
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
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 500, height: 500)
        .windowStyle(.titleBar)

        WindowGroup(for: WorkTaskIdentifier.self) { $identifier in
            if let identifier {
                WorkTaskWindow(identifier: identifier)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 600, height: 450)
        .windowStyle(.titleBar)

        WindowGroup(for: PromptIdentifier.self) { $identifier in
            if let identifier {
                PromptWindow(identifier: identifier)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 600, height: 450)
        .windowStyle(.titleBar)

        Settings {
            SettingsView(settings: settings)
                .preferredColorScheme(.dark)
        }
    }

    private func showProjectSelector() {
        ProjectSelectorWindowController.shared.show(projectList: projectList) { [openWindow] path in
            openWindow(value: path)
        }
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
