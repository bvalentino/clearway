import XCTest
@testable import Clearway

final class TaskTerminalLayoutTests: XCTestCase {

    func testDefaultIsHalfOfAvailable() {
        XCTAssertEqual(TaskTerminalLayout.height(stored: nil, available: 800), 400)
    }

    func testStoredWinsOverDefault() {
        XCTAssertEqual(TaskTerminalLayout.height(stored: 300, available: 800), 300)
    }

    func testStoredAboveCeilingIsClamped() {
        XCTAssertEqual(TaskTerminalLayout.height(stored: 900, available: 800), 680)
    }

    func testDefaultOnShortPaneIsFlooredAtMinimum() {
        XCTAssertEqual(TaskTerminalLayout.height(stored: nil, available: 150), 80)
    }

    func testRangeDoesNotInvertBelowTwoHundred() {
        for available: CGFloat in [150, 199] {
            XCTAssertEqual(TaskTerminalLayout.height(stored: 500, available: available), 80)
            XCTAssertEqual(TaskTerminalLayout.height(stored: 10, available: available), 80)
        }
    }

    func testDraggedHeightStartsFromCurrentAndClampsAtBothEnds() {
        XCTAssertEqual(TaskTerminalLayout.draggedHeight(from: 400, translation: 50, available: 800), 350)
        XCTAssertEqual(TaskTerminalLayout.draggedHeight(from: 400, translation: -50, available: 800), 450)
        XCTAssertEqual(TaskTerminalLayout.draggedHeight(from: 100, translation: 500, available: 800), 80)
        XCTAssertEqual(TaskTerminalLayout.draggedHeight(from: 600, translation: -500, available: 800), 680)
    }
}
