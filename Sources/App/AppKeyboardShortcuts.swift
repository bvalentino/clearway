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
        static let comma: UInt16 = 0x2B
    }

    /// Whether the app claims this key event. Pure, so the whole table is testable without a live
    /// Ghostty surface.
    ///
    /// Letters match on `chars`, lowercased: SwiftUI matches their `.keyboardShortcut` against the
    /// character the key produces, so this follows a non-QWERTY layout the way a key code would not
    /// — but `charactersIgnoringModifiers` still applies Shift, so Cmd+Shift+T arrives as `"T"`.
    /// Punctuation matches on `keyCode` instead, because Shift turns it into a different glyph that
    /// varies by layout (`[` → `{`, `,` → `<`); the brackets additionally need it to agree with the
    /// keyCode-matched `NSEvent` monitor that consumes them.
    static func claims(flags: NSEvent.ModifierFlags, chars: String?, keyCode: UInt16) -> Bool {
        let letter = chars?.lowercased()

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
            // new tab, close tab, bottom panel, sidebar, new window, settings (the `Settings`
            // scene's automatic Cmd+, is a menu key equivalent like any other, so it needs
            // claiming too)
            return letter == "t" || letter == "w" || letter == "j" || letter == "b" || letter == "n"
                || keyCode == KeyCode.comma
        case [.command, .shift]:
            // previous/next tab, new shell tab, new group, reload configuration
            return keyCode == KeyCode.leftBracket || keyCode == KeyCode.rightBracket
                || letter == "t" || letter == "n" || keyCode == KeyCode.comma
        case [.command, .option]:
            return letter == "b"  // toggle aside
        default:
            return false
        }
    }
}
