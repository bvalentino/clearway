import XCTest
@testable import Clearway

final class PortAttributionTests: XCTestCase {

    func testNestedWorktreesAttributeToTheLongestMatch() {
        let main = makeWorktree(branch: "main", path: "/r", isMain: true)
        let child = makeWorktree(branch: "feature", path: "/r/.worktrees/a")
        let listeners = [PortScanner.Listener(cwd: "/r/.worktrees/a", port: 8123)]

        let result = PortAttribution.attribute(listeners, to: [main, child])

        XCTAssertEqual(result, ["/r/.worktrees/a": [8123]])
    }

    /// The operator's rule: attribution runs over every tracked worktree, so a listener inside a
    /// worktree the sidebar hides belongs to that worktree and is simply not rendered — never to
    /// its visible parent.
    func testHiddenNestedWorktreeKeepsItsOwnPortsRatherThanItsParent() {
        let main = makeWorktree(branch: "main", path: "/r", isMain: true)
        let hiddenChild = makeWorktree(branch: nil, path: "/r/.worktrees/a", headStatus: .detached)
        let listeners = [PortScanner.Listener(cwd: "/r/.worktrees/a/src", port: 8123)]

        let result = PortAttribution.attribute(listeners, to: [main, hiddenChild])

        XCTAssertEqual(result["/r/.worktrees/a"], [8123])
        XCTAssertNil(result["/r"])
    }

    func testCwdEqualToAWorktreePathMatchesIt() {
        let worktree = makeWorktree(branch: "main", path: "/r", isMain: true)
        let listeners = [PortScanner.Listener(cwd: "/r", port: 3000)]

        let result = PortAttribution.attribute(listeners, to: [worktree])

        XCTAssertEqual(result, ["/r": [3000]])
    }

    func testSiblingSharingAPathPrefixIsNotMatched() {
        let worktree = makeWorktree(branch: "main", path: "/r/clearway", isMain: true)
        let listeners = [PortScanner.Listener(cwd: "/r/clearway-old", port: 8080)]

        let result = PortAttribution.attribute(listeners, to: [worktree])

        XCTAssertEqual(result, [:])
    }

    func testListenerOutsideEveryWorktreeIsDiscarded() {
        let worktree = makeWorktree(branch: "main", path: "/r", isMain: true)
        let listeners = [PortScanner.Listener(cwd: "/opt/homebrew/var/db/redis", port: 6379)]

        let result = PortAttribution.attribute(listeners, to: [worktree])

        XCTAssertEqual(result, [:])
    }

    func testIPv4AndIPv6BindsOfOnePortCollapse() {
        let worktree = makeWorktree(branch: "main", path: "/r", isMain: true)
        let listeners = [
            PortScanner.Listener(cwd: "/r", port: 5432),
            PortScanner.Listener(cwd: "/r", port: 5432)
        ]

        let result = PortAttribution.attribute(listeners, to: [worktree])

        XCTAssertEqual(result, ["/r": [5432]])
    }

    func testPortsUnderOneWorktreeComeBackAscending() {
        let worktree = makeWorktree(branch: "main", path: "/r", isMain: true)
        let listeners = [
            PortScanner.Listener(cwd: "/r", port: 9000),
            PortScanner.Listener(cwd: "/r/src", port: 3000),
            PortScanner.Listener(cwd: "/r", port: 8080)
        ]

        let result = PortAttribution.attribute(listeners, to: [worktree])

        XCTAssertEqual(result, ["/r": [3000, 8080, 9000]])
    }

    func testNoListenersReturnsNothing() {
        let worktree = makeWorktree(branch: "main", path: "/r", isMain: true)

        XCTAssertEqual(PortAttribution.attribute([], to: [worktree]), [:])
    }

    func testNoWorktreesReturnsNothing() {
        let listeners = [PortScanner.Listener(cwd: "/r", port: 3000)]

        XCTAssertEqual(PortAttribution.attribute(listeners, to: []), [:])
    }

    func testWorktreeWithoutAPathIsSkipped() {
        let pathless = makeWorktree(branch: "gone", path: nil)
        let listeners = [PortScanner.Listener(cwd: "/r", port: 3000)]

        XCTAssertEqual(PortAttribution.attribute(listeners, to: [pathless]), [:])
    }
}
