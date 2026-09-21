import AppKit

/// Opens a realized toolbar split button's dropdown from the keyboard.
///
/// SwiftUI offers no way to present a `Menu` programmatically, so ⌥⌘R has to reach the control
/// AppKit built. A toolbar `Menu` carrying a `primaryAction:` is realized as an
/// `NSSegmentedControl` whose chevron half owns the `NSMenu` — the split-button note in
/// `CLAUDE.md`. Segment 0's label is what separates the Run button from the window's other
/// segmented controls: `CommandsView`'s filter picker and the Open In button.
@MainActor
enum ToolbarSplitButtonMenu {
    /// Does nothing when nothing matches. Falling back to another control would open a dropdown
    /// the operator did not ask for.
    static func popUp(labelled label: String) {
        guard let root = NSApp.keyWindow?.contentView,
              let control = segmentedControl(in: root, labelled: label),
              let menu = control.menu(forSegment: 1) else { return }
        // A nil item puts the menu's top-left content corner at this point, in the view's own
        // coordinates, so the control's bottom edge hangs the menu below the button rather than
        // over it. Tracking cancelled by Escape reports false and needs no handling.
        let bottomEdge = control.isFlipped ? control.bounds.maxY : control.bounds.minY
        menu.popUp(positioning: nil, at: NSPoint(x: control.bounds.minX, y: bottomEdge), in: control)
    }

    /// Depth first from the key window's content view. The segment count is checked before either
    /// segment is read: `NSSegmentedControl` raises on an out-of-range index.
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
}
