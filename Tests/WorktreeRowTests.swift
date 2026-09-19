import XCTest
@testable import Clearway

/// Pins the row-text precedence lifted out of `SidebarView`. Nothing in a SwiftUI body is
/// reachable from XCTest, which is why the rule is a pure static on `WorktreeRow`. The name
/// arrives already trimmed — `WorktreeGroupManager` owns that rule and is tested for it there.
final class WorktreeRowTextTests: XCTestCase {

    func testAStoredNameWinsOverATaskTitle() {
        let texts = WorktreeRow.rowTexts(
            for: makeWorktree(branch: "feature-x", path: "/tmp/feature-x"),
            name: "Login fix",
            taskTitle: "Retry the flaky login"
        )
        XCTAssertEqual(texts.primaryText, "Login fix")
        XCTAssertEqual(texts.subtitle, "feature-x")
    }

    func testTheTaskTitleFillsTheSlotWhenNoNameIsStored() {
        let texts = WorktreeRow.rowTexts(
            for: makeWorktree(branch: "feature-x", path: "/tmp/feature-x"),
            name: nil,
            taskTitle: "Retry the flaky login"
        )
        XCTAssertEqual(texts.primaryText, "Retry the flaky login")
        XCTAssertEqual(texts.subtitle, "feature-x")
    }

    func testANameWithNoTaskTitleStillWins() {
        let texts = WorktreeRow.rowTexts(
            for: makeWorktree(branch: "feature-x", path: "/tmp/feature-x"),
            name: "Login fix",
            taskTitle: nil
        )
        XCTAssertEqual(texts.primaryText, "Login fix")
        XCTAssertEqual(texts.subtitle, "feature-x")
    }

    func testNeitherLeavesBothNil() {
        let texts = WorktreeRow.rowTexts(
            for: makeWorktree(branch: "feature-x", path: "/tmp/feature-x"),
            name: nil,
            taskTitle: nil
        )
        XCTAssertNil(texts.primaryText)
        XCTAssertNil(texts.subtitle)
    }

    /// A detached worktree has no branch, so the subtitle is `displayName`'s fallback rather than
    /// the empty string that would make `WorktreeRow` collapse to one line.
    func testADetachedWorktreeSubtitlesWithItsDisplayName() {
        let texts = WorktreeRow.rowTexts(
            for: makeWorktree(branch: nil, path: "/tmp/loose", headStatus: .detached),
            name: "Loose ends",
            taskTitle: nil
        )
        XCTAssertEqual(texts.primaryText, "Loose ends")
        XCTAssertEqual(texts.subtitle, "(detached)")
    }
}
