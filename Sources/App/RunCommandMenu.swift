import SwiftUI

/// The worktree toolbar's Run split button: clicking the label runs the project's primary command —
/// the last one used here, or the first in saved order before anything has been run — and clicking
/// the chevron opens the full list in saved order. Both run in the selected worktree's main
/// terminal. An empty list leaves the button visible and disabled.
struct RunCommandMenu: View {
    @EnvironmentObject private var savedCommandManager: SavedCommandManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var ghosttyApp: Ghostty.App

    let worktree: Worktree

    var body: some View {
        Menu {
            ForEach(savedCommandManager.commands) { command in
                Button(command.name) { run(command) }
            }
        } label: {
            Text("Run")
        } primaryAction: {
            if let command = savedCommandManager.primaryCommand { run(command) }
        }
        .disabled(savedCommandManager.commands.isEmpty || ghosttyApp.app == nil)
    }

    private func run(_ command: SavedCommand) {
        savedCommandManager.recordLastRun(command)
        guard let app = ghosttyApp.app else { return }
        terminalManager.run(command, in: worktree, app: app)
    }
}
