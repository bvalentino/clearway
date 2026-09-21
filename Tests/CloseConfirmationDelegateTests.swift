import AppKit
import XCTest
@testable import Clearway

/// The close prompt's gate. The rule it asks is injected, so the delegate is reachable from here
/// while a real busy terminal needs a `ghostty_app_t`. The alert itself stays uncovered beyond its
/// copy: it runs a sheet.
@MainActor
final class CloseConfirmationDelegateTests: XCTestCase {

    private func discard(_ window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.close()
    }

    func testAQuietWindowClosesWithoutAsking() {
        let window = makeWindow()
        defer { discard(window) }
        let delegate = CloseConfirmationDelegate(needsConfirm: { false })

        XCTAssertTrue(delegate.windowShouldClose(window))
        XCTAssertNil(window.attachedSheet)
    }

    /// The regression: a busy window used to veto every window's close, because the delegate read
    /// the process-wide aggregate rather than its own window's terminals.
    func testEachWindowAnswersForItsOwnTerminals() {
        let busyWindow = makeWindow()
        let quietWindow = makeWindow()
        defer {
            discard(busyWindow)
            discard(quietWindow)
        }
        let busy = CloseConfirmationDelegate(needsConfirm: { true })
        let quiet = CloseConfirmationDelegate(needsConfirm: { false })

        XCTAssertFalse(busy.windowShouldClose(busyWindow))
        XCTAssertTrue(quiet.windowShouldClose(quietWindow))
    }

    func testTheRuleIsAskedOnEveryCloseRatherThanCachedAtInit() {
        let window = makeWindow()
        defer { discard(window) }
        var busy = false
        let delegate = CloseConfirmationDelegate(needsConfirm: { busy })

        XCTAssertTrue(delegate.windowShouldClose(window))
        busy = true
        XCTAssertFalse(delegate.windowShouldClose(window))
    }

    /// The body names this window, unlike the process-wide Cmd+Q alert it sits beside.
    func testTheCopyNamesThisWindowsTerminals() {
        XCTAssertEqual(CloseConfirmationDelegate.messageText, "Close terminal sessions?")
        XCTAssertEqual(
            CloseConfirmationDelegate.informativeText,
            "There are processes still running in this window's terminals."
        )
    }
}
