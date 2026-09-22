import SwiftUI

/// The "Open in" menu, shared by the window toolbar and the sidebar's worktree context menu.
///
/// The path is a parameter rather than something the view resolves, so the sidebar can open a
/// right-clicked worktree that is not the current selection.
///
/// With `remembersLastUsed`, it is a split button: clicking the label opens the path in the last
/// app picked here, or in the first app in the list before anything has been picked, and clicking
/// the chevron opens the rest of the list — the primary app is omitted, since the label half
/// already opens it and names it — followed by the door to Settings, where the list is edited.
/// Only the toolbar asks for that; the sidebar's context menu stays a plain submenu and lists
/// every app.
///
/// Each variant titles itself, so no call site can label the split button with an app name that is
/// not the one its label half opens.
struct OpenInMenu: View {

    @EnvironmentObject private var settings: SettingsManager

    private let path: String
    private let remembersLastUsed: Bool

    init(path: String, remembersLastUsed: Bool = false) {
        self.path = path
        self.remembersLastUsed = remembersLastUsed
    }

    /// `primaryAction:` cannot be attached conditionally, so the menu is declared twice: the split
    /// button for the toolbar, the plain submenu the sidebar's context menu needs. The switch is on
    /// the entry point rather than on state, so neither declaration replaces the other at runtime.
    ///
    /// The split button's `.id` is its own dropdown's contents: a toolbar `Menu` carrying a
    /// `primaryAction` is realized as an `NSSegmentedControl` whose `NSMenu` is filled once, when
    /// the control is built, and never refilled — see the split button note in CLAUDE.md. Keying
    /// the view on what the dropdown draws rebuilds the control whenever that list changes, which
    /// is the only way an edit in Settings reaches it.
    @ViewBuilder var body: some View {
        if remembersLastUsed {
            Menu {
                toolbarItems
            } label: {
                Text(settings.openInButtonTitle)
            } primaryAction: {
                if let app = settings.primaryOpenInApp { open(app) }
            }
            .id(settings.menuOpenInApps)
        } else {
            Menu {
                items(settings.openInApps)
            } label: {
                Text("Open in")
            }
        }
    }

    /// The primary app is omitted — the label half already opens it. With a one-app list that
    /// leaves only the Settings door, which is why the door is unconditional: an empty menu is
    /// drawn by AppKit as a click that does nothing.
    @ViewBuilder private var toolbarItems: some View {
        let apps = settings.menuOpenInApps
        if !apps.isEmpty {
            items(apps)
            Divider()
        }
        EditOpenInAppsButton()
    }

    private func items(_ apps: [OpenInApp]) -> some View {
        ForEach(apps) { app in
            Button(app.label) { open(app) }
        }
    }

    /// The launch itself is `WorktreeOpenInActions.opener`, shared with the menu bar, so the failure
    /// alert is built in one place. Only the toolbar variant records the pick.
    private var open: (OpenInApp) -> Void {
        WorktreeOpenInActions.opener(path: path, recordingUseIn: remembersLastUsed ? settings : nil)
    }
}

/// The door to Settings, which is where the Open In list is edited, rendered by the toolbar
/// dropdown and the Worktree menu's Open in submenu alike. `SettingsLink` is macOS 14+ and the
/// deployment target is 13, so the older path sends AppKit's own Settings action. The Settings
/// scene is a single form, so there is no tab to select on arrival.
struct EditOpenInAppsButton: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text("Edit Apps…") }
        } else {
            Button("Edit Apps…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}
