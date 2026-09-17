import SwiftUI

/// The "Open in" menu, shared by the window toolbar and the sidebar's worktree context menu.
/// Generic over its label so each entry point can title it for its own surface.
///
/// The path is a parameter rather than something the view resolves, so the sidebar can open a
/// right-clicked worktree that is not the current selection.
struct OpenInMenu<Label: View>: View {

    @EnvironmentObject private var settings: SettingsManager

    private let path: String
    private let label: Label

    init(path: String, @ViewBuilder label: () -> Label) {
        self.path = path
        self.label = label()
    }

    var body: some View {
        Menu {
            ForEach(settings.openInApps) { app in
                Button(app.label) { open(app) }
            }
        } label: {
            label
        }
    }

    private func open(_ app: OpenInApp) {
        Task {
            let outcome = await OpenInAppLauncher.launch(command: app.command, path: path)
            guard case .failed(let message) = outcome else { return }
            presentFailure(app, detail: message)
        }
    }

    /// `NSAlert().runModal()` is the app's pattern for a fire-and-forget message
    /// (`ClearwayApp.swift:68, 90`); a `@Published` failure would have to be wired into both
    /// entry points' view trees for one message.
    private func presentFailure(_ app: OpenInApp, detail: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't open in \(app.label)"
        alert.informativeText = OpenInAppLauncher.failureMessage(command: app.command, detail: detail)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
