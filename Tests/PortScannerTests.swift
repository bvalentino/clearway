import XCTest
@testable import Clearway

final class PortScannerTests: XCTestCase {

    /// `PortMonitor` republishes on `!=`, so the scan's order has to depend on nothing but the set
    /// of listeners. It reads the live machine, so this is vacuous with fewer than two listeners.
    func testTheScanIsOrderedByDirectoryThenPort() {
        let scanned = PortScanner.scan()
        XCTAssertEqual(scanned, scanned.sorted { ($0.cwd, $0.port) < ($1.cwd, $1.port) })
    }
}
