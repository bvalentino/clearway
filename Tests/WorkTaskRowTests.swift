import XCTest
@testable import Clearway

/// Pins the task row's dot rule, a pure static beside its view for the same reason
/// `WorktreeRow.dot` is one: nothing in a SwiftUI body is reachable from XCTest.
/// `AgentActivityStoreTests` covers where the phase itself comes from.
final class WorkTaskRowDotTests: XCTestCase {

    func testAWaitingAgentCarriesTheWaitingDot() {
        XCTAssertEqual(WorkTaskRow.dot(phase: .waiting), .waiting)
    }

    func testAWorkingAgentCarriesTheWorkingDot() {
        XCTAssertEqual(WorkTaskRow.dot(phase: .working), .working)
    }

    func testAnIdleTaskCarriesNoDot() {
        XCTAssertNil(WorkTaskRow.dot(phase: .idle))
    }
}
