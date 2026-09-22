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
/// string separates the Run button from the Open In button either way.
///
/// The control is **not** under the window's `contentView`: a toolbar item's view hangs off the
/// titlebar, `NSToolbarItemViewer` → `NSToolbarView` → `NSTitlebarView` → `NSTitlebarContainerView`
/// → `NSThemeFrame`, a sibling branch of `contentView`. So the search starts at each visible
/// `NSToolbarItem`'s `view`.
@MainActor
enum ToolbarSplitButtonMenu {
    /// Does nothing when nothing matches. Falling back to another control would open a dropdown
    /// the operator did not ask for.
    static func popUp(labelled label: String) {
        guard let items = NSApp.keyWindow?.toolbar?.visibleItems else { return }
        for item in items {
            guard let view = item.view else { continue }
            if let control = segmentedControl(in: view, labelled: label) {
                popUpChevronMenu(of: control)
                return
            }
            if let button = popUpButton(in: view, titled: label) {
                // Its `NSMenu` is empty until SwiftUI's coordinator fills it on open, so there is
                // no menu to position by hand; `performClick` is what runs the coordinator.
                button.performClick(nil)
                return
            }
        }
    }

    private static func popUpChevronMenu(of control: NSSegmentedControl) {
        guard let menu = control.menu(forSegment: 1) else { return }
        // A nil item puts the menu's top-left content corner at this point, in the view's own
        // coordinates, so the control's bottom edge hangs the menu below the button rather than
        // over it. Tracking cancelled by Escape reports false and needs no handling.
        let bottomEdge = control.isFlipped ? control.bounds.maxY : control.bounds.minY
        menu.popUp(positioning: nil, at: NSPoint(x: control.bounds.minX, y: bottomEdge), in: control)
    }

    /// The segment count is checked before either segment is read: `NSSegmentedControl` raises on
    /// an out-of-range index.
    private static func segmentedControl(in view: NSView, labelled label: String) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl,
           control.segmentCount > 1,
           control.label(forSegment: 0) == label {
            return control
        }
        for subview in view.subviews {
            if let match = segmentedControl(in: subview, labelled: label) { return match }
        }
        return nil
    }

    private static func popUpButton(in view: NSView, titled title: String) -> NSPopUpButton? {
        if let button = view as? NSPopUpButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let match = popUpButton(in: subview, titled: title) { return match }
        }
        return nil
    }
}
