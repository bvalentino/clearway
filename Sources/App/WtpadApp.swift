import SwiftUI
import GhosttyKit

/// Call ghostty_init once at process startup, before any config/app is created.
private let ghosttyInitResult: Bool = {
    ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
}()

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct WtpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var ghosttyApp: Ghostty.App
    @StateObject private var projectList = ProjectListManager()

    init() {
        precondition(ghosttyInitResult, "ghostty_init failed")
        _ghosttyApp = StateObject(wrappedValue: Ghostty.App())
    }

    var body: some Scene {
        WindowGroup(for: String.self) { $projectPath in
            ProjectWindow(projectPath: $projectPath)
                .environmentObject(ghosttyApp)
                .environmentObject(projectList)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 700)
    }
}
