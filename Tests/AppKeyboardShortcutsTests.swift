import AppKit
import XCTest
@testable import Clearway

/// Pins `AppKeyboardShortcuts.claims`, the table a focused terminal surface consults before
/// encoding a key for the shell. `performKeyEquivalent`, which consumes it, is unreachable from
/// XCTest — reaching it needs a `SurfaceView` instance, and the initializer needs a real
/// `ghostty_app_t`.
final class AppKeyboardShortcutsTests: XCTestCase {

    private let leftBracket = AppKeyboardShortcuts.KeyCode.leftBracket
    private let rightBracket = AppKeyboardShortcuts.KeyCode.rightBracket

    /// `keyCode` is read only by the Cmd+Shift bracket clause, so the character-matched cases
    /// pass 0 rather than a key code the rule never looks at.
    private func claims(_ flags: NSEvent.ModifierFlags, _ chars: String?, _ keyCode: UInt16 = 0) -> Bool {
        AppKeyboardShortcuts.claims(flags: flags, chars: chars, keyCode: keyCode)
    }

    // MARK: - Cmd+J (the bottom-panel shortcut)

    func testCommandJIsClaimed() {
        XCTAssertTrue(claims([.command], "j"))
    }

    func testCommandJWithExtraModifiersIsNotClaimed() {
        XCTAssertFalse(claims([.command, .shift], "j"))
        XCTAssertFalse(claims([.command, .control], "j"))
        XCTAssertFalse(claims([.command, .option], "j"))
    }

    func testUnclaimedCommandComboIsNotClaimed() {
        XCTAssertFalse(claims([.command], "k"))
    }

    // MARK: - Pre-existing clauses (regression pins for the lift)

    func testCommandTIsClaimed() {
        XCTAssertTrue(claims([.command], "t"))
        XCTAssertFalse(claims([.command, .control], "t"))
    }

    func testCommandWIsClaimed() {
        XCTAssertTrue(claims([.command], "w"))
        XCTAssertFalse(claims([.command, .option], "w"))
    }

    func testCommandShiftBracketsAreClaimed() {
        XCTAssertTrue(claims([.command, .shift], "{", leftBracket))
        XCTAssertTrue(claims([.command, .shift], "}", rightBracket))
        XCTAssertFalse(claims([.command], "[", leftBracket), "unshifted Cmd+[ is not a claimed shortcut")
        XCTAssertFalse(claims([.command, .shift, .control], "{", leftBracket))
    }

    func testControlDigitIsClaimed() {
        XCTAssertTrue(claims([.control], "1"))
        XCTAssertTrue(claims([.control], "3"))
        XCTAssertFalse(claims([.control, .command], "1"), "Ctrl+digit requires no Command")
        XCTAssertFalse(claims([.control], "a"))
        XCTAssertFalse(claims([.command], "1"))
    }

    /// The claim stops at the last sidebar destination that exists. A claimed digit with no handler
    /// is taken from the shell and answered by nobody, so Ctrl+4…9 and Ctrl+0 stay the terminal's —
    /// they are real control codes there (Ctrl+6 is vim's `CTRL-^`).
    func testControlDigitBeyondTheSidebarDestinationsIsNotClaimed() {
        XCTAssertFalse(claims([.control], "0"))
        XCTAssertFalse(claims([.control], "4"))
        XCTAssertFalse(claims([.control], "6"))
        XCTAssertFalse(claims([.control], "9"))
    }

    // MARK: - Menu-bar commands (declared in ClearwayApp, subject to the same table)

    /// `charactersIgnoringModifiers` still applies Shift, so these arrive uppercased — matching on a
    /// bare `"t"` would leave New Shell Tab dead exactly as it was before it was claimed.
    func testShiftedMenuLettersAreClaimedDespiteArrivingUppercased() {
        XCTAssertTrue(claims([.command, .shift], "T"), "New Shell Tab")
        XCTAssertTrue(claims([.command, .shift], "N"), "New Group")
    }

    func testCommandNIsClaimed() {
        XCTAssertTrue(claims([.command], "n"), "New Window")
    }

    /// Both comma shortcuts match on key code: Shift turns "," into a layout-dependent glyph, the
    /// same reason the bracket clauses do. Cmd+, is the `Settings` scene's automatic shortcut, which
    /// reaches a focused surface as an ordinary menu key equivalent and so needs claiming like the rest.
    func testCommaShortcutsAreClaimed() {
        let comma = AppKeyboardShortcuts.KeyCode.comma
        XCTAssertTrue(claims([.command], ",", comma), "Settings")
        XCTAssertTrue(claims([.command, .shift], "<", comma), "Reload Configuration")
        XCTAssertFalse(claims([.command, .option], ",", comma))
    }

    func testUnclaimedCommandShiftComboIsNotClaimed() {
        XCTAssertFalse(claims([.command, .shift], "K"))
    }

    // MARK: - The View menu's panel toggles

    func testCommandBIsClaimed() {
        XCTAssertTrue(claims([.command], "b"), "toggle sidebar")
    }

    func testCommandOptionBIsClaimed() {
        XCTAssertTrue(claims([.command, .option], "b"), "toggle aside")
    }

    func testPanelToggleVariantsWithOtherModifiersAreNotClaimed() {
        XCTAssertFalse(claims([.command, .control], "b"))
        XCTAssertFalse(claims([.command, .shift], "B"))
        XCTAssertFalse(claims([.command, .shift, .option], "B"))
        XCTAssertFalse(claims([.command], "f"))
        XCTAssertFalse(claims([.command, .option], "f"))
    }

    // MARK: - Retired shortcuts

    /// Cmd+Ctrl+3 was the aside's shortcut before Cmd+Option+B replaced it. Cmd+Ctrl+2 was the
    /// secondary panel's before Cmd+J. Nothing declares either now, so claiming one would take a
    /// key from the shell and answer it with nothing.
    func testRetiredCommandControlDigitsAreNotClaimed() {
        XCTAssertFalse(claims([.command, .control], "3"))
        XCTAssertFalse(claims([.command, .control], "2"))
    }

    /// Replacing SwiftUI's `.sidebar` command group leaves macOS's own Enter/Exit Full Screen item
    /// standing, so the app declares no full-screen shortcut and must claim none — a claimed combo
    /// with no handler is taken from the shell and dropped.
    func testCommandControlFIsNotClaimed() {
        XCTAssertFalse(claims([.command, .control], "f"))
    }

    /// Unlike every other clause, Ctrl+digit tolerates a stray Shift or Option. Pins that shape
    /// against being folded into the `switch` below it as `case [.control]`, which every other
    /// assertion here would still pass while Ctrl+Shift+3 stopped reaching the sidebar.
    func testControlDigitToleratesStrayShiftOrOption() {
        XCTAssertTrue(claims([.control, .shift], "3"))
        XCTAssertTrue(claims([.control, .option], "3"))
    }

    func testNilCharactersAreNotClaimed() {
        XCTAssertFalse(claims([.command], nil))
    }
}
