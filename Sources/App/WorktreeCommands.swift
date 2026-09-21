import SwiftUI

/// The focused project window's Run action, published as a focused scene value so the menu bar can
/// reach per-window state. `nil` when no worktree is selected or Ghostty has no app handle.
///
/// `commands` is the whole saved list, not `menuCommands`: the toolbar's dropdown omits the primary
/// because its label half already runs it, and the menu bar has no label half.
struct WorktreeRunActions {
    let primary: SavedCommand?
    let title: String
    let commands: [SavedCommand]
    let run: (SavedCommand) -> Void
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
struct WorktreeOpenInActions {
    let primary: OpenInApp?
    let title: String
    let apps: [OpenInApp]
    let open: (OpenInApp) -> Void
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
