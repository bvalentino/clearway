import AppKit

/// What the user is told when a group rename or delete abandons its registry write because a
/// member's `clearway.group` write failed, leaving the change half-applied on disk.
///
/// The copy is pure and the AppKit call is confined to `present()`, so `WorktreeGroupManager`
/// stays free of AppKit and the wording is pinned by tests — the split
/// `OpenInAppLauncher.failureMessage` makes against `OpenInMenu.presentFailure`.
///
/// The worktree is named by its full path: a member is identified by nothing else here, and the
/// manager's `names` map holds only worktrees the user has renamed, so a friendlier label would
/// be absent exactly when it is needed.
struct WorktreeGroupWriteAlert: Sendable, Equatable {

    let group: String
    let path: String

    var messageText: String {
        "Couldn't save the group \"\(group)\""
    }

    var informativeText: String {
        "Clearway couldn't write the group for \(path), so the sidebar will go back to how it was."
    }

    @MainActor
    func present() {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
