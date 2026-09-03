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
        XCTAssertFalse(claims([.command, .shift], "t"))
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

    func testNilCharactersAreNotClaimed() {
        XCTAssertFalse(claims([.command], nil))
    }
}
