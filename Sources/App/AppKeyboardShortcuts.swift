import AppKit

/// The Cmd/Ctrl combos the app claims for itself. A focused terminal surface asks this before
/// encoding a key for the shell, and hands back anything claimed here so SwiftUI can act on it.
///
/// This list belongs to the app, not to the terminal wrapper: its counterparts are `ContentView`'s
/// `.keyboardShortcut` modifiers and its main-terminal `NSEvent` monitor, and `ClearwayApp`'s menu
/// commands — the view hierarchy is offered a key equivalent before the main menu, so a menu item's
/// shortcut needs an entry here too (Cmd+T is one). A shortcut declared at any of those sites and
/// missing here is declared but unreachable whenever a terminal has focus.
enum AppKeyboardShortcuts {

    /// macOS virtual key codes for keys whose character depends on the keyboard layout, shared with
    /// the monitor that consumes them so the claim and its handler can't drift apart.
    enum KeyCode {
        static let leftBracket: UInt16 = 0x21
        static let rightBracket: UInt16 = 0x1E
    }

    /// Whether the app claims this key event. Pure, so the whole table is testable without a live
    /// Ghostty surface.
    ///
    /// The letters match on `chars` because SwiftUI matches their `.keyboardShortcut` the same way;
    /// the brackets match on `keyCode` because their consumer is a keyCode-matched `NSEvent`
    /// monitor and the shifted character varies by layout.
    static func claims(flags: NSEvent.ModifierFlags, chars: String?, keyCode: UInt16) -> Bool {
        // Ctrl+1…3 → sidebar destinations. Deliberately tolerates a stray Shift or Option. The range
        // stops at the last destination that exists: claiming a digit no handler answers would take
        // it from the shell and do nothing with it.
        if flags.contains(.control) && !flags.contains(.command),
           let chars, chars.count == 1,
           let scalar = chars.unicodeScalars.first, scalar >= "1" && scalar <= "3" {
            return true
        }

        switch flags.intersection([.command, .shift, .control, .option]) {
        case [.command]:
            return chars == "t" || chars == "w" || chars == "j"  // new tab, close tab, bottom panel
        case [.command, .shift]:
            return keyCode == KeyCode.leftBracket || keyCode == KeyCode.rightBracket  // previous/next tab
        case [.command, .control]:
            return chars == "3"  // toggle aside
        default:
            return false
        }
    }
}
