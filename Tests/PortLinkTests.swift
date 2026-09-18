import XCTest
@testable import Clearway

final class PortLinkTests: XCTestCase {

    /// Port 3000 is the case that caught it: the tooltip read `http://localhost:3,000`.
    func testTheURLStringCarriesNoGroupingSeparator() {
        XCTAssertEqual(PortLink.urlString(3000), "http://localhost:3000")
    }

    func testTheLabelCarriesNoGroupingSeparator() {
        XCTAssertEqual(PortLink.label(3000), "3000")
    }

    func testTheURLParsesToTheSameText() {
        XCTAssertEqual(PortLink.url(3000)?.absoluteString, "http://localhost:3000")
    }

    func testEveryPortBoundRoundTrips() {
        XCTAssertEqual(PortLink.urlString(1), "http://localhost:1")
        XCTAssertEqual(PortLink.urlString(8080), "http://localhost:8080")
        XCTAssertEqual(PortLink.urlString(65535), "http://localhost:65535")
    }
}
