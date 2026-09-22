import AppKit

/// Opens a realized toolbar menu button's dropdown from the keyboard.
///
/// SwiftUI offers no way to present a `Menu` programmatically, so ⌥⌘R has to reach the control
/// AppKit built — and which control that is depends on the state. A toolbar `Menu` carrying a
/// `primaryAction:` is realized as an `NSSegmentedControl` whose chevron half owns the `NSMenu`;
/// one without a `primaryAction:` is realized as an `NSPopUpButton` — the split-button note in
/// `CLAUDE.md`. Both paths are needed, because Run drops its `primaryAction:` on an empty command
/// list, which is the one state where its dropdown holds nothing but the "Add Command…" door.
///
/// Segment 0's label and the pop-up button's title are both the `Menu`'s own label, so the same
/// string separates the Run button from the Open In button either way — but only while the two
/// differ, and both are user text: a saved command named "Open in Fork" gives the Run button the
/// Open In button's label. So the walk collects every match and pops nothing unless exactly one
/// control answers, because popping either of two is the guess this helper exists not to make.
///
/// The control is **not** under the window's `contentView`: a toolbar item's view hangs off the
/// titlebar, `NSToolbarItemViewer` → `NSToolbarView` → `NSTitlebarView` → `NSTitlebarContainerView`
/// → `NSThemeFrame`, a sibling branch of `contentView`. So the search starts at each visible
/// `NSToolbarItem`'s `view`.
@MainActor
enum ToolbarSplitButtonMenu {
    /// Does nothing unless exactly one control answers to the label. Falling back to another
    /// control would open a dropdown the operator did not ask for. The log line is the only trace
    /// the press leaves — the key is claimed, so the shell never saw it either, and a walk that
    /// finds nothing is indistinguishable from a shortcut that was never declared.
    static func popUp(labelled label: String) {
        let items = NSApp.keyWindow?.toolbar?.visibleItems ?? []
        let found = items.compactMap(\.view).flatMap { matches(in: $0, labelled: label) }
        guard found.count == 1, let match = found.first else {
            Ghostty.logger.warning("\(found.count) toolbar controls are labelled \(label, privacy: .public), so no dropdown was popped.")
            return
        }
        switch match {
        case .chevron(let control):
            popUpChevronMenu(of: control)
        case .popUpButton(let button):
            // Its `NSMenu` is empty until SwiftUI's coordinator fills it on open, so there is
            // no menu to position by hand; `performClick` is what runs the coordinator.
            button.performClick(nil)
        }
    }

    /// The two shapes SwiftUI realizes a toolbar `Menu` as, depending on whether it carries a
    /// `primaryAction:`.
    private enum Match {
        case chevron(NSSegmentedControl)
        case popUpButton(NSPopUpButton)
    }

    /// The segment count is checked before either segment is read: `NSSegmentedControl` raises on
    /// an out-of-range index.
    private static func matches(in view: NSView, labelled label: String) -> [Match] {
        if let control = view as? NSSegmentedControl,
           control.segmentCount > 1,
           control.label(forSegment: 0) == label {
            return [.chevron(control)]
        }
        if let button = view as? NSPopUpButton, button.title == label {
            return [.popUpButton(button)]
        }
        return view.subviews.flatMap { matches(in: $0, labelled: label) }
    }

    private static func popUpChevronMenu(of control: NSSegmentedControl) {
        guard let menu = control.menu(forSegment: 1) else { return }
        // A nil item puts the menu's top-left content corner at this point, in the view's own
        // coordinates, so the control's bottom edge hangs the menu below the button rather than
        // over it. Tracking cancelled by Escape reports false and needs no handling.
        let bottomEdge = control.isFlipped ? control.bounds.maxY : control.bounds.minY
        menu.popUp(positioning: nil, at: NSPoint(x: control.bounds.minX, y: bottomEdge), in: control)
    }
}
