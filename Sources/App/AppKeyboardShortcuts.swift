import AppKit

/// The Cmd/Ctrl combos the app claims for itself. A focused terminal surface asks this before
/// encoding a key for the shell, and hands back anything claimed here so SwiftUI can act on it.
///
/// This list belongs to the app, not to the terminal wrapper: its counterparts are `ContentView`'s
/// `.keyboardShortcut` modifiers and its main-terminal `NSEvent` monitor. A shortcut declared there
/// and missing here is declared but unreachable whenever a terminal has focus, which is why the
/// two live in the same layer.
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
        // Ctrl+digit → sidebar destinations. Deliberately tolerates a stray Shift or Option.
        if flags.contains(.control) && !flags.contains(.command),
           let chars, chars.count == 1,
           let scalar = chars.unicodeScalars.first, scalar >= "0" && scalar <= "9" {
            return true
        }

        switch flags.intersection([.command, .shift, .control, .option]) {
        case [.command]:
            return chars == "t" || chars == "w" || chars == "j"  // new tab, close tab, bottom panel
        case [.command, .shift]:
            return keyCode == KeyCode.leftBracket || keyCode == KeyCode.rightBracket  // previous/next tab
        default:
            return false
        }
    }
}
