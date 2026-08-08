import XCTest
@testable import Clearway

final class ShellPathStoreTests: XCTestCase {

    private let baseline = ShellPathValidation.baseline

    // MARK: - currentPath

    func testCurrentPathIsTheBaselineWhenNothingIsKnown() {
        let resolver = FakeResolver(outcomes: [.full("/opt/homebrew/bin")])

        XCTAssertEqual(ShellPathStore(resolve: { resolver.next() }).currentPath, baseline)
    }

    func testCurrentPathHasNoSideEffect() {
        let resolver = FakeResolver(outcomes: [.full("/opt/homebrew/bin")])
        let store = ShellPathStore(resolve: { resolver.next() })

        _ = store.currentPath
        _ = store.currentPath

        XCTAssertEqual(resolver.callCount, 0, "Reading the path must not start a resolution")
    }

    func testCurrentPathUnionsTheKnownValueWithTheBaseline() async {
        let resolver = FakeResolver(outcomes: [.full("/opt/homebrew/bin")])
        let store = ShellPathStore(resolve: { resolver.next() })

        _ = await store.awaitPath()

        XCTAssertEqual(store.currentPath, "/opt/homebrew/bin:\(baseline)")
    }

    // MARK: - The inherited environment

    /// An empty inherited `PATH` and a missing one are different cases — `??` catches nil but
    /// not the empty string — so the old fallback turned an empty inherited `PATH` into an empty
    /// `PATH` and a missing one into a literal. Nothing reads the inherited value now, which collapses
    /// both cases into one: no part of it may reach a consumer, whatever it holds.
    ///
    /// Asserted by reading the inherited value rather than by unsetting it. `setenv`/`unsetenv` are
    /// not safe against the `Process` spawns this suite and its test host make — and briefly removing
    /// `PATH` process-wide would trade a real flake for a weaker assertion than the one below, which
    /// names every component that leaked.
    func testNoPartOfTheInheritedPathReachesTheResolvedValue() async {
        let resolver = FakeResolver(outcomes: [.failed])
        let store = ShellPathStore(resolve: { resolver.next() })
        let baselineComponents = Set(baseline.split(separator: ":").map(String.init))
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)

        let resolved = await store.awaitPath()

        XCTAssertEqual(resolved, baseline)
        let resolvedComponents = Set(resolved.split(separator: ":").map(String.init))
        for component in inherited where !baselineComponents.contains(component) {
            XCTAssertFalse(resolvedComponents.contains(component),
                           "\(component) came from the inherited PATH and must never reach a consumer")
        }
    }

    // MARK: - awaitPath

    func testAHealthyResolutionRunsOneShellAndStaysFull() async {
        let resolver = FakeResolver(outcomes: [.full("/opt/homebrew/bin")])
        let store = ShellPathStore(resolve: { resolver.next() })

        let first = await store.awaitPath()
        let second = await store.awaitPath()

        XCTAssertEqual(first, "/opt/homebrew/bin:\(baseline)")
        XCTAssertEqual(second, first)
        XCTAssertEqual(resolver.callCount, 1)
    }

    func testAFailedResolutionIsNotCached() async throws {
        let resolver = FakeResolver(outcomes: [.failed, .full("/opt/homebrew/bin")])
        let store = ShellPathStore(resolve: { resolver.next() })

        let afterFailure = await store.awaitPath()
        XCTAssertEqual(afterFailure, baseline)
        _ = await store.awaitPath()

        try await waitUntil { store.currentPath == "/opt/homebrew/bin:\(self.baseline)" }
        XCTAssertEqual(resolver.callCount, 2, "a failure must not stop a later launch from retrying")
    }

    /// Only the first caller of all may block on the shell. A failure is not cached, so it would
    /// otherwise leave every later launch awaiting a fresh two-attempt resolution — on the machine
    /// this exists for, where both attempts hit the limit, that is the resolver's whole budget of
    /// dead time added to every launch, forever.
    func testAFailedResolutionIsNotAwaitedASecondTime() async {
        let resolver = FakeResolver(outcomes: [.failed, .failed], delay: 0.3)
        let store = ShellPathStore(resolve: { resolver.next() })

        _ = await store.awaitPath()

        let started = Date()
        let second = await store.awaitPath()

        XCTAssertEqual(second, baseline)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "a retry must run behind the caller")
    }

    func testTwoConcurrentCallsStartOneResolution() async {
        let resolver = FakeResolver(outcomes: [.full("/opt/homebrew/bin")], delay: 0.2)
        let store = ShellPathStore(resolve: { resolver.next() })

        async let first = store.awaitPath()
        async let second = store.awaitPath()
        let results = await [first, second]

        XCTAssertEqual(results, ["/opt/homebrew/bin:\(baseline)", "/opt/homebrew/bin:\(baseline)"])
        XCTAssertEqual(resolver.callCount, 1, "The guard must cover the whole two-attempt sequence")
    }

    // MARK: - Degraded values

    func testADegradedValueIsReturnedWithoutWaiting() async {
        let resolver = FakeResolver(outcomes: [.degraded("/usr/local/bin"), .full("/opt/homebrew/bin")], delay: 0.3)
        let store = ShellPathStore(resolve: { resolver.next() })

        let first = await store.awaitPath()
        XCTAssertEqual(first, "/usr/local/bin:\(baseline)")

        let started = Date()
        let second = await store.awaitPath()

        XCTAssertEqual(second, "/usr/local/bin:\(baseline)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "A degraded value must never be awaited")
    }

    func testALaterInteractiveSuccessReplacesADegradedValue() async throws {
        let resolver = FakeResolver(outcomes: [.degraded("/usr/local/bin"), .full("/opt/homebrew/bin")])
        let store = ShellPathStore(resolve: { resolver.next() })

        let degraded = await store.awaitPath()
        XCTAssertEqual(degraded, "/usr/local/bin:\(baseline)")
        _ = await store.awaitPath()

        try await waitUntil { store.currentPath == "/opt/homebrew/bin:\(self.baseline)" }
        XCTAssertEqual(resolver.callCount, 2)
    }

    func testAFailedRefreshKeepsTheDegradedValue() async throws {
        let resolver = FakeResolver(outcomes: [.degraded("/usr/local/bin"), .failed])
        let store = ShellPathStore(resolve: { resolver.next() })

        _ = await store.awaitPath()
        _ = await store.awaitPath()

        try await waitUntil { resolver.callCount == 2 }
        XCTAssertEqual(store.currentPath, "/usr/local/bin:\(baseline)")
    }

    // MARK: - Eager start

    func testStartResolutionResolvesWithoutACaller() async throws {
        let resolver = FakeResolver(outcomes: [.full("/opt/homebrew/bin")])
        let store = ShellPathStore(resolve: { resolver.next() })

        store.startResolution()

        try await waitUntil { store.currentPath == "/opt/homebrew/bin:\(self.baseline)" }
        XCTAssertEqual(resolver.callCount, 1)
    }

    func testAnEagerResolutionIsJoinedRatherThanDuplicated() async {
        let resolver = FakeResolver(outcomes: [.full("/opt/homebrew/bin")], delay: 0.2)
        let store = ShellPathStore(resolve: { resolver.next() })

        store.startResolution()
        let path = await store.awaitPath()

        XCTAssertEqual(path, "/opt/homebrew/bin:\(baseline)")
        XCTAssertEqual(resolver.callCount, 1)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition not met within \(timeout)s", file: file, line: line)
    }
}

/// Stands in for the real shell resolution: hands out a scripted outcome per call and
/// counts the calls, so the tests can assert the single-flight guard and the retry rules.
private final class FakeResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [ShellPathResolver.Outcome]
    private let delay: TimeInterval
    private var calls = 0

    init(outcomes: [ShellPathResolver.Outcome], delay: TimeInterval = 0) {
        self.outcomes = outcomes
        self.delay = delay
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func next() -> ShellPathResolver.Outcome {
        let outcome: ShellPathResolver.Outcome = lock.withLock {
            calls += 1
            return outcomes.isEmpty ? .failed : outcomes.removeFirst()
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return outcome
    }
}
