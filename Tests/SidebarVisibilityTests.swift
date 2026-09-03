import SwiftUI
import XCTest
@testable import Clearway

/// Pins the pure toggle decision behind Cmd+B. `NavigationSplitViewVisibility` is a struct whose
/// cases are static computed properties, so these compare with `==` — a `switch` would not compile.
final class SidebarVisibilityTests: XCTestCase {

    func testTogglingHidesAVisibleSidebar() {
        XCTAssertEqual(NavigationSplitViewVisibility.all.togglingSidebar, .doubleColumn)
    }

    func testTogglingShowsAHiddenSidebar() {
        XCTAssertEqual(NavigationSplitViewVisibility.doubleColumn.togglingSidebar, .all)
        XCTAssertEqual(NavigationSplitViewVisibility.detailOnly.togglingSidebar, .all)
    }

    func testSidebarIsVisible() {
        XCTAssertTrue(NavigationSplitViewVisibility.all.sidebarIsVisible)
        XCTAssertFalse(NavigationSplitViewVisibility.doubleColumn.sidebarIsVisible)
        XCTAssertFalse(NavigationSplitViewVisibility.detailOnly.sidebarIsVisible)
    }

    /// `.automatic` carries `kind: .doubleColumn` behind a private `isAutomatic` flag that its
    /// `==` ignores, so no `==`-based rule can tell the two apart. `ContentView` seeds `.all`
    /// precisely so `.automatic` never reaches the toggle; this pins the SDK behavior that makes
    /// the seed load-bearing rather than cosmetic.
    func testAutomaticIsIndistinguishableFromDoubleColumn() {
        XCTAssertEqual(NavigationSplitViewVisibility.automatic, .doubleColumn)
    }
}
