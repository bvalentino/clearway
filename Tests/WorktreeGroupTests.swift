import XCTest
@testable import Clearway

/// Pins the group-name rule the New Group and Rename Group sheets enforce. Nothing in a SwiftUI
/// body is reachable from XCTest, which is why the rule is a pure static on `WorktreeGroup`.
final class WorktreeGroupTests: XCTestCase {

    func testAnUnusedNameIsAvailable() {
        XCTAssertEqual(WorktreeGroup.available("Backlog", in: []), "Backlog")
        XCTAssertEqual(WorktreeGroup.available("Backlog", in: ["Shipped"]), "Backlog")
    }

    func testAnEmptyOrWhitespaceOnlyNameIsRefused() {
        XCTAssertNil(WorktreeGroup.available("", in: []))
        XCTAssertNil(WorktreeGroup.available("   ", in: []))
        XCTAssertNil(WorktreeGroup.available("\n\t", in: []))
    }

    func testAnExactDuplicateIsRefused() {
        XCTAssertNil(WorktreeGroup.available("Backlog", in: ["Backlog"]))
    }

    func testTheNameIsTrimmedBeforeComparison() {
        XCTAssertNil(WorktreeGroup.available(" Backlog ", in: ["Backlog"]))
    }

    func testTheTrimmedNameIsWhatIsStored() {
        XCTAssertEqual(WorktreeGroup.available("  Backlog  ", in: []), "Backlog")
    }

    func testComparisonIsCaseSensitive() {
        XCTAssertEqual(WorktreeGroup.available("backlog", in: ["Backlog"]), "backlog")
    }

    func testAGroupMayKeepItsOwnNameWhileRenaming() {
        XCTAssertEqual(WorktreeGroup.available("Backlog", in: ["Backlog"], renaming: "Backlog"), "Backlog")
        XCTAssertEqual(WorktreeGroup.available(" Backlog ", in: ["Backlog"], renaming: "Backlog"), "Backlog")
    }

    func testARenameOntoAnotherGroupsNameIsRefused() {
        XCTAssertNil(WorktreeGroup.available("Shipped", in: ["Backlog", "Shipped"], renaming: "Backlog"))
    }

    func testARenameToAnEmptyNameIsRefused() {
        XCTAssertNil(WorktreeGroup.available("  ", in: ["Backlog"], renaming: "Backlog"))
    }
}
