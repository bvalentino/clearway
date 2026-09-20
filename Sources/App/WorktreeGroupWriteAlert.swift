import AppKit

/// What the user is told when a group gesture leaves the change half-applied on disk: a rename or
/// delete that abandoned its registry write because a member's `clearway.group` write failed, or a
/// `clearway.groupOrder` rewrite that failed partway and left the registry truncated.
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
    /// The member whose write was refused, or `nil` when the registry itself was: `clearway.groupOrder`
    /// is repo-level and names no worktree, so a path there could only be invented.
    let path: String?

    var messageText: String {
        "Couldn't save the group \"\(group)\""
    }

    /// Promises no revert. A multi-member rename where one write lands and another fails leaves the
    /// landed member naming a group the registry does not list, and it renders ungrouped on the next
    /// reload — which only runs when the worktree list changes.
    var informativeText: String {
        guard let path else {
            return "Clearway couldn't write the group list. The sidebar will show what git holds."
        }
        return "Clearway couldn't write the group for \(path). The sidebar will show what git holds."
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
