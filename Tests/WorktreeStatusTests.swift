import AppKit
import SwiftUI
import XCTest
@testable import Clearway

final class WorktreeStatusTests: XCTestCase {

    // MARK: - WorktreeStatus

    func testAllCasesAreInFixedSectionOrder() {
        XCTAssertEqual(WorktreeStatus.allCases, [.todo, .inProgress, .inReview, .done, .onHold])
    }

    func testRawValuesArePersistedSlugs() {
        XCTAssertEqual(WorktreeStatus.allCases.map(\.rawValue),
                       ["todo", "inProgress", "inReview", "done", "onHold"])
    }

    func testUnknownSlugDecodesToNil() {
        XCTAssertNil(WorktreeStatus(rawValue: "bogus"))
        XCTAssertNil(WorktreeStatus(rawValue: "in progress"))
        XCTAssertNil(WorktreeStatus(rawValue: "Todo"))
    }

    func testIdIsRawValue() {
        XCTAssertEqual(WorktreeStatus.allCases.map(\.id), WorktreeStatus.allCases.map(\.rawValue))
    }

    func testDisplayNames() {
        XCTAssertEqual(WorktreeStatus.allCases.map(\.displayName),
                       ["Todo", "In progress", "In review", "Done", "On hold"])
    }

    func testColorsAreSystemColors() {
        XCTAssertEqual(WorktreeStatus.allCases.map(\.color),
                       [.gray, .yellow, .green, .indigo, .gray])
    }

    func testSymbols() {
        XCTAssertEqual(WorktreeStatus.allCases.map(\.symbol),
                       ["circle", "circle.lefthalf.filled", "circle.inset.filled",
                        "checkmark.circle.fill", "pause.circle"])
    }

    func testSymbolsResolveOnBuildHost() {
        for status in WorktreeStatus.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil),
                            status.symbol)
        }
    }

    // MARK: - WorktreeGrouping

    func testGroupingAllCasesAndRawValues() {
        XCTAssertEqual(WorktreeGrouping.allCases, [.group, .status, .none])
        XCTAssertEqual(WorktreeGrouping.allCases.map(\.rawValue), ["group", "status", "none"])
    }

    func testGroupingUnknownSlugDecodesToNil() {
        XCTAssertNil(WorktreeGrouping(rawValue: "bogus"))
    }

    func testGroupingDisplayNamesAndIds() {
        XCTAssertEqual(WorktreeGrouping.allCases.map(\.displayName), ["Group", "Status", "None"])
        XCTAssertEqual(WorktreeGrouping.allCases.map(\.id), ["group", "status", "none"])
    }
}
