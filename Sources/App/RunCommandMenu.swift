import SwiftUI

/// The worktree toolbar's Run dropdown: the project's saved commands, in saved order, run in the
/// selected worktree's main terminal.
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
            Image(systemName: "play")
        }
        .menuIndicator(.hidden)
        .help("Run a saved command")
        .disabled(savedCommandManager.commands.isEmpty || ghosttyApp.app == nil)
    }

    private func run(_ command: SavedCommand) {
        guard let app = ghosttyApp.app else { return }
        terminalManager.run(command, in: worktree, app: app)
    }
}
