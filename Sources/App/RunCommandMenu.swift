import SwiftUI

/// The worktree toolbar's Run split button: clicking the label runs the project's primary command —
/// the last one used here, or the first in saved order before anything has been run — and clicking
/// the chevron opens the rest of the list plus the editor door. The label names that primary
/// command, so the click's effect is readable without opening anything. Both run in the selected
/// worktree's main terminal. An empty list leaves the button visible, disabled and reading "Run".
struct RunCommandMenu: View {
    @EnvironmentObject private var savedCommandManager: SavedCommandManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var ghosttyApp: Ghostty.App

    let worktree: Worktree

    @State private var showCommandEditor = false

    var body: some View {
        Menu {
            items
        } label: {
            Text(savedCommandManager.runButtonTitle)
        } primaryAction: {
            if let command = savedCommandManager.primaryCommand { run(command) }
        }
        .disabled(savedCommandManager.primaryCommand == nil || ghosttyApp.app == nil)
        // Outside `.disabled`, so the sheet's own controls never inherit a disabled environment.
        .sheet(isPresented: $showCommandEditor) {
            CommandEditorSheet(command: nil)
        }
    }

    /// The primary command is omitted — the label half already runs it. With a one-command list
    /// that leaves only the editor door, which is why it is unconditional: an empty menu is
    /// rendered by AppKit as nothing happening at all.
    @ViewBuilder private var items: some View {
        let commands = savedCommandManager.menuCommands
        if !commands.isEmpty {
            ForEach(commands) { command in
                Button(command.name) { run(command) }
            }
            Divider()
        }
        Button("Add Command…") { showCommandEditor = true }
    }

    private func run(_ command: SavedCommand) {
        savedCommandManager.recordLastRun(command)
        guard let app = ghosttyApp.app else { return }
        terminalManager.run(command, in: worktree, app: app)
    }
}
