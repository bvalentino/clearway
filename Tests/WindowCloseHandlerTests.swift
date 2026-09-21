import AppKit
import XCTest
@testable import Clearway

/// The window-close door `ProjectContentView` hangs its surface retirement off. What the door runs
/// needs a `ghostty_app_t` and is unreachable from here; the door itself needs only an `NSWindow`.
@MainActor
final class WindowCloseHandlerTests: XCTestCase {

    func testClosingTheHostingWindowRunsTheHandler() {
        let window = makeWindow()
        let view = WindowCloseHandlerView()
        let ran = expectation(description: "the window-close handler ran")
        view.perform = { ran.fulfill() }
        window.contentView?.addSubview(view)

        window.close()

        wait(for: [ran], timeout: 2)
    }

    /// The observation is scoped to the window the view is in, so a view that has left one is not
    /// still listening to it.
    func testAViewThatLeftItsWindowRunsNothingWhenThatWindowCloses() {
        let window = makeWindow()
        let view = WindowCloseHandlerView()
        let ran = expectation(description: "the window-close handler ran")
        ran.isInverted = true
        view.perform = { ran.fulfill() }
        window.contentView?.addSubview(view)

        view.removeFromSuperview()
        window.close()

        wait(for: [ran], timeout: 0.5)
    }
}
