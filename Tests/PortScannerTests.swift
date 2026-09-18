import Darwin
import XCTest
@testable import Clearway

final class PortScannerTests: XCTestCase {

    func testListenersAreOrderedByDirectoryThenPort() {
        let listeners = [
            PortScanner.Listener(cwd: "/b", port: 80),
            PortScanner.Listener(cwd: "/a", port: 90),
            PortScanner.Listener(cwd: "/a", port: 80)
        ]

        XCTAssertEqual(PortScanner.ordered(listeners), [
            PortScanner.Listener(cwd: "/a", port: 80),
            PortScanner.Listener(cwd: "/a", port: 90),
            PortScanner.Listener(cwd: "/b", port: 80)
        ])
    }

    /// Every `libproc` failure in `scan()` collapses to an empty result, which is what a machine
    /// with no servers running looks like too. Opening a listener this process owns is the one
    /// input the test controls, so a scanner that has stopped working goes red instead of green.
    func testTheScanFindsAListeningSocketThisProcessOwns() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(descriptor < 0, "socket() failed: \(errno)")
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        try XCTSkipIf(bound != 0, "bind() failed: \(errno)")
        try XCTSkipIf(listen(descriptor, 1) != 0, "listen() failed: \(errno)")

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        let port = UInt16(bigEndian: assigned.sin_port)

        let expected = PortScanner.Listener(cwd: FileManager.default.currentDirectoryPath, port: port)
        XCTAssertTrue(PortScanner.scan().contains(expected), "the scan missed this process's own listener")
    }
}
