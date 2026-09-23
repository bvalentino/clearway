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

    func testNeitherFallsBackToTheBranchWithNoSubtitle() {
        let texts = WorktreeRow.rowTexts(
            for: makeWorktree(branch: "feature-x", path: "/tmp/feature-x"),
            name: nil,
            taskTitle: nil
        )
        XCTAssertEqual(texts.primaryText, "feature-x")
        XCTAssertNil(texts.subtitle)
    }

    func testADetachedWorktreeWithNeitherShowsDetached() {
        let texts = WorktreeRow.rowTexts(
            for: makeWorktree(branch: nil, path: "/tmp/loose", headStatus: .detached),
            name: nil,
            taskTitle: nil
        )
        XCTAssertEqual(texts.primaryText, "(detached)")
        XCTAssertNil(texts.subtitle)
    }

    func testMainShowsItsBranch() {
        let texts = WorktreeRow.rowTexts(
            for: makeWorktree(branch: "main", path: "/tmp/repo", isMain: true),
            name: nil,
            taskTitle: nil
        )
        XCTAssertEqual(texts.primaryText, "main")
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

/// Pins the trailing dot's precedence, lifted out of `SidebarView`'s `isOpen` gate and
/// `WorktreeRow`'s body for the same reason the row texts were: nothing in a SwiftUI body is
/// reachable from XCTest. `AgentActivityStoreTests` covers where the phase itself comes from.
final class WorktreeRowDotTests: XCTestCase {

    func testWaitingBeatsEverythingElse() {
        XCTAssertEqual(WorktreeRow.dot(phase: .waiting, hasNotification: true, isOpen: true), .waiting)
    }

    func testWorkingBeatsANotification() {
        XCTAssertEqual(WorktreeRow.dot(phase: .working, hasNotification: true, isOpen: true), .working)
    }

    func testAnIdleWorktreeShowsItsNotification() {
        XCTAssertEqual(WorktreeRow.dot(phase: .idle, hasNotification: true, isOpen: true), .notification)
    }

    func testAnIdleWorktreeWithNoNotificationCarriesNoDot() {
        XCTAssertNil(WorktreeRow.dot(phase: .idle, hasNotification: false, isOpen: true))
    }

    /// A closed worktree's surfaces are already retired, so whatever phase is still keyed to it is
    /// stale — the dot goes dark whether the phase says waiting or working.
    func testAClosedWorktreeCarriesNoPhaseDot() {
        XCTAssertNil(WorktreeRow.dot(phase: .working, hasNotification: false, isOpen: false))
        XCTAssertNil(WorktreeRow.dot(phase: .waiting, hasNotification: false, isOpen: false))
    }

    /// The gate is on the phase alone: a notification raised before the worktree closed is still
    /// unread, so closing must not take the blue dot with it.
    func testAClosedWorktreeStillShowsItsNotification() {
        XCTAssertEqual(WorktreeRow.dot(phase: .working, hasNotification: true, isOpen: false), .notification)
        XCTAssertEqual(WorktreeRow.dot(phase: .idle, hasNotification: true, isOpen: false), .notification)
    }
}
