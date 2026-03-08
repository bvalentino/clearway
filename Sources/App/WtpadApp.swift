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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard TerminalManager.needsConfirmQuit else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Close terminal sessions?"
        alert.informativeText = "There are processes still running in your terminals."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first!) { response in
            NSApp.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        TerminalManager.closeAllManagers()
    }
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

    var body: some Scene {
        WindowGroup(for: String.self) { $projectPath in
            ProjectWindow(projectPath: $projectPath)
                .environmentObject(ghosttyApp)
                .environmentObject(projectList)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 700)

        Settings {
            SettingsView(settings: settings)
                .preferredColorScheme(.dark)
        }
    }
}
