import SwiftUI

/// The focused project window's Run action, published as a focused scene value so the menu bar can
/// reach per-window state. `nil` when no worktree is selected or Ghostty has no app handle.
///
/// `commands` is the whole saved list, not `menuCommands`: the toolbar's dropdown omits the primary
/// because its label half already runs it, and the menu bar has no label half.
struct WorktreeRunActions {
    let primary: SavedCommand?
    let commands: [SavedCommand]
    let run: (SavedCommand) -> Void
    /// Opens the toolbar Run button's own dropdown, so ⌥⌘R shows the operator the list they would
    /// have clicked to rather than a second menu that could drift from it.
    let popRunMenu: () -> Void
    let addCommand: () -> Void
}

extension WorktreeRunActions {
    /// Running a saved command, written once for the toolbar's Run button and the menu bar alike.
    /// `recordLastRun` comes **before** the app-handle guard on purpose: what is remembered is the
    /// pick, not the successful launch, or a command that fails to start could never become the
    /// primary again.
    @MainActor
    static func runner(
        worktree: Worktree,
        savedCommandManager: SavedCommandManager,
        terminalManager: TerminalManager,
        ghosttyApp: Ghostty.App
    ) -> (SavedCommand) -> Void {
        { command in
            savedCommandManager.recordLastRun(command)
            guard let app = ghosttyApp.app else { return }
            terminalManager.run(command, in: worktree, app: app)
        }
    }
}

/// The focused project window's Open In action, published as a focused scene value. `nil` when the
/// selection has no path or the Open In list is empty.
///
/// `apps` is `settings.openInApps` whole, for the same reason `WorktreeRunActions.commands` is.
///
/// `primary` is not optional, where `WorktreeRunActions.primary` is: `SettingsManager.primaryOpenInApp`
/// resolves for every non-empty list and nils this whole value otherwise, so a row that exists has
/// an app to open. Run's can be nil behind a live value, which is why only its row greys on the
/// primary rather than on the value itself.
struct WorktreeOpenInActions {
    let primary: OpenInApp
    let apps: [OpenInApp]
    let open: (OpenInApp) -> Void
    let popOpenInMenu: () -> Void
}

extension WorktreeOpenInActions {
    /// Opening a path in one of the listed apps, written once for both toolbar entry points and the
    /// menu bar. A `nil` `settings` records nothing — the sidebar's context submenu neither reads
    /// nor writes the last-used app.
    @MainActor
    static func opener(path: String, recordingUseIn settings: SettingsManager?) -> (OpenInApp) -> Void {
        { app in
            settings?.recordOpenInUse(app)
            Task {
                let outcome = await OpenInAppLauncher.launch(command: app.command, path: path)
                guard case .failed(let message) = outcome else { return }
                presentFailure(app, detail: message)
            }
        }
    }

    /// `NSAlert().runModal()` is the app's pattern for a fire-and-forget message
    /// (`ClearwayApp.swift:68, 90`); a `@Published` failure would have to be wired into every entry
    /// point's view tree for one message.
    @MainActor
    private static func presentFailure(_ app: OpenInApp, detail: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't open in \(app.label)"
        alert.informativeText = OpenInAppLauncher.failureMessage(command: app.command, detail: detail)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct WorktreeRunActionsKey: FocusedValueKey {
    typealias Value = WorktreeRunActions
}

private struct WorktreeOpenInActionsKey: FocusedValueKey {
    typealias Value = WorktreeOpenInActions
}

extension FocusedValues {
    var worktreeRunActions: WorktreeRunActions? {
        get { self[WorktreeRunActionsKey.self] }
        set { self[WorktreeRunActionsKey.self] = newValue }
    }

    var worktreeOpenInActions: WorktreeOpenInActions? {
        get { self[WorktreeOpenInActionsKey.self] }
        set { self[WorktreeOpenInActionsKey.self] = newValue }
    }
}

/// Worktree ▸ Run <name>. An empty command list leaves the generic "Run" with nothing to run, so
/// the row greys.
struct RunPrimaryMenuItem: View {
    @FocusedValue(\.worktreeRunActions) private var actions: WorktreeRunActions?

    var body: some View {
        Button(title) {
            guard let actions, let command = actions.primary else { return }
            actions.run(command)
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(actions?.primary == nil)
    }

    /// The verb is the row's, not the primary command's: `SavedCommandManager.runButtonTitle` is
    /// the bare name, which is what the toolbar's label half wants and what a menu row cannot be.
    private var title: String {
        guard let command = actions?.primary else { return "Run" }
        return "Run \(command.name)"
    }
}

/// Worktree ▸ Run…, the row that carries ⌥⌘R. It exists because the Run submenu below it cannot:
/// AppKit's key-equivalent dispatch fires a menu item's action, and a SwiftUI `Menu` used as a
/// submenu row has none. It stays enabled on an empty command list, so the editor door the submenu
/// holds is still one keystroke away.
struct RunDropdownMenuItem: View {
    @FocusedValue(\.worktreeRunActions) private var actions: WorktreeRunActions?

    var body: some View {
        Button("Run…") { actions?.popRunMenu() }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(actions == nil)
    }
}

/// Worktree ▸ Run, listing every saved command rather than the toolbar dropdown's `menuCommands`:
/// there is no label half here running the primary, so omitting it would hide it. Picking one
/// records it as the primary, which retitles this menu and the toolbar together.
struct RunCommandsSubmenu: View {
    @FocusedValue(\.worktreeRunActions) private var actions: WorktreeRunActions?

    var body: some View {
        Menu("Run") {
            if let actions {
                if !actions.commands.isEmpty {
                    ForEach(actions.commands) { command in
                        Button(command.name) { actions.run(command) }
                    }
                    Divider()
                }
                Button("Add Command…") { actions.addCommand() }
            }
        }
        .disabled(actions == nil)
    }
}

/// Worktree ▸ Open in <app>. The focused value is already nil on an empty app list, so the title
/// never falls back to the bare word with a live row behind it.
struct OpenInPrimaryMenuItem: View {
    @FocusedValue(\.worktreeOpenInActions) private var actions: WorktreeOpenInActions?

    var body: some View {
        Button(title) {
            guard let actions else { return }
            actions.open(actions.primary)
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(actions == nil)
    }

    private var title: String {
        guard let actions else { return "Open in" }
        return "Open in \(actions.primary.label)"
    }
}

/// Worktree ▸ Open in…, the row that carries ⌥⌘O, for the same reason "Run…" carries ⌥⌘R: the
/// submenu below it has no action for AppKit's key-equivalent dispatch to fire. It greys with the
/// rows around it — an empty app list draws no toolbar button, so there is no dropdown to pop.
struct OpenInDropdownMenuItem: View {
    @FocusedValue(\.worktreeOpenInActions) private var actions: WorktreeOpenInActions?

    var body: some View {
        Button("Open in…") { actions?.popOpenInMenu() }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(actions == nil)
    }
}

/// Worktree ▸ Open in, listing every app for the same reason the Run submenu lists every command.
/// Disabled along with the row above it on an empty list, which puts the Settings door out of
/// reach from here — Settings is reachable from the app menu.
struct OpenInAppsSubmenu: View {
    @FocusedValue(\.worktreeOpenInActions) private var actions: WorktreeOpenInActions?

    var body: some View {
        Menu("Open in") {
            if let actions {
                if !actions.apps.isEmpty {
                    ForEach(actions.apps) { app in
                        Button(app.label) { actions.open(app) }
                    }
                    Divider()
                }
                EditOpenInAppsButton()
            }
        }
        .disabled(actions == nil)
    }
}
