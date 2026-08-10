import XCTest
@testable import Clearway

/// Drives ``ShellPathResolver`` against fake shell scripts written to a scratch directory,
/// so the reported defect is reproduced without the affected machine and without Sparkle.
final class ShellPathResolverTests: XCTestCase {

    /// Long enough to absorb process spawn on a loaded machine, short enough to keep the
    /// suite fast. Only the production resolver uses the real 5-second limit.
    private let timeout: TimeInterval = 0.5

    private let marker = ShellPathResolver.outputMarker

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-path-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        try super.tearDownWithError()
    }

    // MARK: - The defect

    func testAShellThatPrintsABannerThenBlocksProducesNoPath() throws {
        let shell = try makeFakeShell("""
        echo "Waiting for approval in your browser…"
        sleep 3
        echo "\(marker)/usr/bin:/bin"
        """)

        XCTAssertEqual(ShellPathResolver(shell: shell, timeout: timeout).resolve(), .failed)
    }

    func testATimedOutInteractiveAttemptFallsThroughToTheLoginAttempt() throws {
        let shell = try makeFakeShell("""
        case "$1" in
          *i*) echo "Waiting for approval in your browser…"; sleep 3 ;;
          *) echo "\(marker)/usr/bin:/bin" ;;
        esac
        """)

        XCTAssertEqual(ShellPathResolver(shell: shell, timeout: timeout).resolve(), .degraded("/usr/bin:/bin"))
    }

    // MARK: - Refusal and fallback

    func testAnInteractiveValueThatIsNotAPathFallsThroughToTheLoginAttempt() throws {
        let shell = try makeFakeShell("""
        case "$1" in
          *i*) echo "Waiting for approval in your browser…" ;;
          *) echo "\(marker)/usr/bin:/bin" ;;
        esac
        """)

        XCTAssertEqual(ShellPathResolver(shell: shell, timeout: timeout).resolve(), .degraded("/usr/bin:/bin"))
    }

    func testANonZeroExitFallsThroughToTheLoginAttemptEvenWhenTheOutputLooksLikeAPath() throws {
        let shell = try makeFakeShell("""
        case "$1" in
          *i*) echo "\(marker)/opt/homebrew/bin:/usr/bin"; exit 1 ;;
          *) echo "\(marker)/usr/bin:/bin" ;;
        esac
        """)

        XCTAssertEqual(ShellPathResolver(shell: shell, timeout: timeout).resolve(), .degraded("/usr/bin:/bin"))
    }

    func testBothAttemptsFailingGivesFailed() throws {
        let shell = try makeFakeShell("exit 127")

        XCTAssertEqual(ShellPathResolver(shell: shell, timeout: timeout).resolve(), .failed)
    }

    func testAMissingShellGivesFailed() {
        let missing = scratch.appendingPathComponent("no-such-shell").path

        XCTAssertEqual(ShellPathResolver(shell: missing, timeout: timeout).resolve(), .failed)
    }

    // MARK: - The healthy path

    func testAHealthyShellGivesFullFromOneInteractiveAttempt() throws {
        let log = scratch.appendingPathComponent("invocations").path
        let shell = try makeFakeShell("""
        echo "$1" >> "\(log)"
        echo "\(marker)/opt/homebrew/bin:/usr/bin:/bin"
        """)

        let outcome = ShellPathResolver(shell: shell, timeout: timeout).resolve()

        XCTAssertEqual(outcome, .full("/opt/homebrew/bin:/usr/bin:/bin"))
        XCTAssertEqual(try invocations(at: log), ["-lic"], "A healthy shell must run exactly once")
    }

    func testExtraLinesAroundThePathDoNotBreakResolution() throws {
        let shell = try makeFakeShell("""
        echo "Welcome to your shell"
        echo "You have mail."
        echo "\(marker)/opt/homebrew/bin:/usr/bin:/bin"
        echo "background job done"
        """)

        XCTAssertEqual(
            ShellPathResolver(shell: shell, timeout: timeout).resolve(),
            .full("/opt/homebrew/bin:/usr/bin:/bin")
        )
    }

    /// A trailing line that is itself colon-separated and contains a real directory — a profile
    /// echoing an assignment, a tool reporting a path — must not be mistaken for the `PATH`. The
    /// marker is what makes this decidable: without it the last line wins and the user silently
    /// gets a near-empty `PATH` marked as fully resolved, so nothing ever retries.
    func testATrailingPathShapedLineIsNotMistakenForThePath() throws {
        let shell = try makeFakeShell("""
        echo "\(marker)/opt/homebrew/bin:/usr/bin:/bin"
        echo "PATH=/usr/bin:/bin"
        """)

        XCTAssertEqual(
            ShellPathResolver(shell: shell, timeout: timeout).resolve(),
            .full("/opt/homebrew/bin:/usr/bin:/bin")
        )
    }

    /// A profile that is merely chatty on stderr must not time out the attempt. Piping stderr without
    /// reading it fills the buffer and blocks the shell mid-write, so the attempt dies at the limit and
    /// the user lands on the baseline — the reported symptom, from a cause the marker and the timeout
    /// do not cover. The 256 KB below is several times any pipe buffer, and costs microseconds.
    func testAProfileThatFloodsStderrStillResolves() throws {
        let shell = try makeFakeShell("""
        line=0123456789
        line=$line$line$line$line$line$line$line$line
        line=$line$line$line$line$line$line$line$line
        written=0
        while [ $written -lt 400 ]; do
          echo "$line" >&2
          written=$((written + 1))
        done
        echo "\(marker)/opt/homebrew/bin:/usr/bin:/bin"
        """)

        XCTAssertEqual(
            ShellPathResolver(shell: shell, timeout: timeout).resolve(),
            .full("/opt/homebrew/bin:/usr/bin:/bin")
        )
    }

    /// stderr is captured, so that a failed attempt can say why in the log. Captured is not read:
    /// only stdout carries the answer, and a profile is free to write anything to stderr.
    func testAMarkedLineOnStderrIsNotAPath() throws {
        let shell = try makeFakeShell("""
        echo "\(marker)/opt/homebrew/bin:/usr/bin:/bin" >&2
        """)

        XCTAssertEqual(ShellPathResolver(shell: shell, timeout: timeout).resolve(), .failed)
    }

    /// Profile output alone, with the echo never reached, is not a `PATH` however path-shaped it is.
    func testOutputWithNoMarkedLineGivesFailed() throws {
        let shell = try makeFakeShell(#"echo "/opt/homebrew/bin:/usr/bin""#)

        XCTAssertEqual(ShellPathResolver(shell: shell, timeout: timeout).resolve(), .failed)
    }

    func testTheResolvedValueIsTheSanitizedOne() throws {
        let shell = try makeFakeShell("""
        echo "\(marker)/usr/bin::/bin:"
        """)

        XCTAssertEqual(ShellPathResolver(shell: shell, timeout: timeout).resolve(), .full("/usr/bin:/bin"))
    }

    // MARK: - Timing

    func testTheProductionTimeLimitIsFiveSecondsPerAttempt() {
        XCTAssertEqual(ShellPathResolver.attemptTimeout, 5)
    }

    func testATimedOutAttemptDoesNotWaitLongerThanTheLimit() throws {
        let shell = try makeFakeShell("sleep 3")

        let started = Date()
        _ = ShellPathResolver(shell: shell, timeout: timeout).resolve()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, timeout * 2 + 1.5, "Both attempts must be bounded by the limit")
    }

    // MARK: - Helpers

    private func makeFakeShell(_ body: String) throws -> String {
        let url = scratch.appendingPathComponent("shell-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func invocations(at path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
