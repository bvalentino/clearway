import XCTest
@testable import Clearway

/// Pins the group-name rule the New Group and Rename Group sheets enforce. Nothing in a SwiftUI
/// body is reachable from XCTest, which is why the rule is a pure static on `WorktreeGroup`.
final class WorktreeGroupTests: XCTestCase {

    func testAnUnusedNameIsAvailable() {
        XCTAssertTrue(WorktreeGroup.isNameAvailable("Backlog", in: []))
        XCTAssertTrue(WorktreeGroup.isNameAvailable("Backlog", in: ["Shipped"]))
    }

    func testAnEmptyOrWhitespaceOnlyNameIsRefused() {
        XCTAssertFalse(WorktreeGroup.isNameAvailable("", in: []))
        XCTAssertFalse(WorktreeGroup.isNameAvailable("   ", in: []))
        XCTAssertFalse(WorktreeGroup.isNameAvailable("\n\t", in: []))
    }

    func testAnExactDuplicateIsRefused() {
        XCTAssertFalse(WorktreeGroup.isNameAvailable("Backlog", in: ["Backlog"]))
    }

    func testTheNameIsTrimmedBeforeComparison() {
        XCTAssertFalse(WorktreeGroup.isNameAvailable(" Backlog ", in: ["Backlog"]))
    }

    func testComparisonIsCaseSensitive() {
        XCTAssertTrue(WorktreeGroup.isNameAvailable("backlog", in: ["Backlog"]))
    }

    func testAGroupMayKeepItsOwnNameWhileRenaming() {
        XCTAssertTrue(WorktreeGroup.isNameAvailable("Backlog", in: ["Backlog"], renaming: "Backlog"))
        XCTAssertTrue(WorktreeGroup.isNameAvailable(" Backlog ", in: ["Backlog"], renaming: "Backlog"))
    }

    func testARenameOntoAnotherGroupsNameIsRefused() {
        XCTAssertFalse(WorktreeGroup.isNameAvailable("Shipped", in: ["Backlog", "Shipped"], renaming: "Backlog"))
    }

    func testARenameToAnEmptyNameIsRefused() {
        XCTAssertFalse(WorktreeGroup.isNameAvailable("  ", in: ["Backlog"], renaming: "Backlog"))
    }
}
