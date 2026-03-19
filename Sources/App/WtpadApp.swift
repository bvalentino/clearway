import SwiftUI
import GhosttyKit

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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
struct WtpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var ghosttyApp: Ghostty.App
    @StateObject private var projectList = ProjectListManager()
    @StateObject private var settings = SettingsManager()

    init() {
        precondition(ghosttyInitResult, "ghostty_init failed")
        _ghosttyApp = StateObject(wrappedValue: Ghostty.App())
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
                Button("About wtpad") {
                    AboutWindowController.shared.show()
                }
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
