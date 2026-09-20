import SwiftUI

/// The worktree toolbar's Run split button: clicking the label runs the last command used in this
/// project, clicking the chevron opens the project's saved commands in saved order. Both run in the
/// selected worktree's main terminal.
struct RunCommandMenu: View {
    @EnvironmentObject private var savedCommandManager: SavedCommandManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var ghosttyApp: Ghostty.App

    let worktree: Worktree

    var body: some View {
        menu
            .disabled(savedCommandManager.commands.isEmpty || ghosttyApp.app == nil)
    }

    /// `primaryAction:` cannot be attached conditionally, so the menu is declared twice and its
    /// content and label are shared between the two.
    @ViewBuilder private var menu: some View {
        if let lastCommand = savedCommandManager.lastRunCommand {
            Menu { items } label: { label } primaryAction: { run(lastCommand) }
        } else {
            Menu { items } label: { label }
        }
    }

    @ViewBuilder private var items: some View {
        ForEach(savedCommandManager.commands) { command in
            Button(command.name) { run(command) }
        }
    }

    private var label: some View { Text("Run") }

    private func run(_ command: SavedCommand) {
        savedCommandManager.recordLastRun(command)
        guard let app = ghosttyApp.app else { return }
        terminalManager.run(command, in: worktree, app: app)
    }
}
