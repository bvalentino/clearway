import XCTest
@testable import Clearway

/// Pins the wording of the one user-visible group-write failure. `present()` is not covered: it
/// runs a modal.
final class WorktreeGroupWriteAlertTests: XCTestCase {

    private static let alert = WorktreeGroupWriteAlert(
        group: "Review",
        path: "/Users/dev/project/.worktrees/fix-crash"
    )

    private static let expectedMessageText = "Couldn't save the group \"Review\""

    private static let expectedInformativeText =
        "Clearway couldn't write the group for /Users/dev/project/.worktrees/fix-crash, "
        + "so the sidebar will go back to how it was."

    func testTitleNamesTheGroupInStraightQuotes() {
        XCTAssertEqual(Self.alert.messageText, Self.expectedMessageText)
    }

    func testBodyNamesTheWorktreePathAndTheRevert() {
        XCTAssertEqual(Self.alert.informativeText, Self.expectedInformativeText)
    }

    /// The manager raises this from its write chain, which is nonisolated, so the copy has to be
    /// readable there — only `present()` may require the main actor.
    func testCopyIsReadableOffTheMainActor() async {
        let alert = Self.alert
        let copy = await Task.detached { (alert.messageText, alert.informativeText) }.value
        XCTAssertEqual(copy.0, Self.expectedMessageText)
        XCTAssertEqual(copy.1, Self.expectedInformativeText)
    }
}
