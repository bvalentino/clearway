import XCTest
@testable import Clearway

/// Pins the wording of the user-visible group-write failures. `present()` is not covered: it
/// runs a modal.
final class WorktreeGroupWriteAlertTests: XCTestCase {

    private static let alert = WorktreeGroupWriteAlert(
        group: "Review",
        path: "/Users/dev/project/.worktrees/fix-crash"
    )

    private static let registryAlert = WorktreeGroupWriteAlert(group: "Review", path: nil)

    private static let expectedMessageText = "Couldn't save the group \"Review\""

    private static let expectedInformativeText =
        "Clearway couldn't write the group for /Users/dev/project/.worktrees/fix-crash. "
        + "The sidebar will show what git holds."

    private static let expectedRegistryInformativeText =
        "Clearway couldn't write the group list. The sidebar will show what git holds."

    func testTitleNamesTheGroupInStraightQuotes() {
        XCTAssertEqual(Self.alert.messageText, Self.expectedMessageText)
    }

    /// No revert is promised: a rename whose other member write landed leaves that member naming a
    /// group the registry does not list, and it renders ungrouped rather than as it was.
    func testBodyNamesTheWorktreePathAndWhatTheSidebarWillShow() {
        XCTAssertEqual(Self.alert.informativeText, Self.expectedInformativeText)
    }

    /// `clearway.groupOrder` is repo-level, so the registry's own failure names no worktree.
    func testBodyWithoutAPathNamesTheGroupList() {
        XCTAssertEqual(Self.registryAlert.messageText, Self.expectedMessageText)
        XCTAssertEqual(Self.registryAlert.informativeText, Self.expectedRegistryInformativeText)
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
