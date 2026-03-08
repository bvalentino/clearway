import SwiftUI
import GhosttyKit

/// Call ghostty_init once at process startup, before any config/app is created.
private let ghosttyInitResult: Bool = {
    ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
}()

@main
struct WtpadApp: App {
    @StateObject private var ghosttyApp: Ghostty.App
    @StateObject private var worktreeManager = WorktreeManager()
    @StateObject private var terminalManager = TerminalManager()

    init() {
        precondition(ghosttyInitResult, "ghostty_init failed")
        _ghosttyApp = StateObject(wrappedValue: Ghostty.App())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ghosttyApp)
                .environmentObject(worktreeManager)
                .environmentObject(terminalManager)
        }
        .defaultSize(width: 1100, height: 700)
    }
}
