import Combine
import XCTest
@testable import Clearway

/// Drives the monitor end to end through the forwarder Clearway installs: the real script, the real
/// `nc -U` transport, the real socket. Everything runs under a temp home, so nothing here can reach
/// the developer's `~/.clearway`, `~/.claude` or `~/.codex`.
@MainActor
final class AgentActivityMonitorTests: XCTestCase {

    private var home: String!
    private var paths: AgentHookPaths!
    private var monitor: AgentActivityMonitor!

    private let worktreeId = "/Users/x/my repo/.worktrees/a b"
    private let surfaceId = "8F1D4C0A-5B2E-4A77-9C31-6E0F2A8D1B44"

    override func setUp() async throws {
        try await super.setUp()
        home = try makeShortTempHome("hook-monitor")
        paths = AgentHookPaths(home: home)
        monitor = AgentActivityMonitor(home: home)
    }

    override func tearDown() async throws {
        monitor?.setEnabled(false)
        monitor = nil
        try? FileManager.default.removeItem(atPath: home)
        home = nil
        paths = nil
        try await super.tearDown()
    }

    // MARK: - The wire

    func testAForwardedEventLightsItsWorktreeAndAStopClearsIt() async throws {
        monitor.setEnabled(true)

        try fire(#"{"session_id": "s", "hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the worktree's phase") { self.monitor.worktreePhases[self.worktreeId] ?? .idle }

        try fire(#"{"session_id": "s", "hook_event_name": "Stop", "stop_reason": "end_turn"}"#)
        try await waitFor(.idle, describing: "the worktree's phase after Stop") { self.monitor.worktreePhases[self.worktreeId] ?? .idle }
    }

    /// The discriminating case for unlinking before `bind`: a process killed without closing leaves
    /// the socket's inode behind, and `bind` refuses an address that already exists. Without the
    /// unlink every launch after a crash listens on nothing, with no symptom but a dot that never
    /// lights again.
    func testAStaleSocketFileDoesNotStopTheListenerBinding() async throws {
        try FileManager.default.createDirectory(atPath: paths.clearwayDir, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: paths.socketPath))

        monitor.setEnabled(true)

        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the worktree's phase over a stale socket path") { self.monitor.worktreePhases[self.worktreeId] ?? .idle }
    }

    /// The discriminating case for reading to EOF rather than once: a `PreToolUse` carries the whole
    /// `tool_input`, and an Edit or a Write of a large file is far past one buffer. A truncated body
    /// is not valid JSON, so the event is silently dropped and the tab's tool label never appears.
    func testAPayloadLargerThanOneReadArrivesIntact() async throws {
        monitor.setEnabled(true)
        let bulk = String(repeating: "x", count: 64 * 1024)

        try fire(#"{"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "\#(bulk)"}}"#)

        try await waitFor("Bash", describing: "the lead's in-flight tool") { self.monitor.toolNames.bySurface[self.surfaceId] }
    }

    func testASubagentRosterIsPublishedForItsWorktree() async throws {
        monitor.setEnabled(true)

        try fire(#"{"hook_event_name": "SubagentStart", "agent_id": "a1", "agent_type": "Explore"}"#)

        try await waitFor(["Explore"], describing: "the worktree's subagent roster") {
            (self.monitor.worktreeSubagents[self.worktreeId] ?? []).compactMap(\.type)
        }
        XCTAssertEqual(monitor.worktreePhases[worktreeId], .working, "a live subagent is work even between the lead's turns")
    }

    /// `PreToolUse`/`PostToolUse` fire around every tool call, so the tool name changes far more
    /// often than anything the sidebar reads. Published off the monitor it invalidated every view
    /// observing any of the monitor's values, in every window — the whole tab strip included, whose
    /// chip-scoped `@ObservedObject` exists to prevent exactly that.
    func testAToolNameChangeDoesNotRepublishTheMonitor() async throws {
        monitor.setEnabled(true)
        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the worktree's phase") { self.monitor.worktreePhases[self.worktreeId] ?? .idle }

        let republished = expectation(description: "the monitor republished")
        republished.isInverted = true
        let subscription = monitor.objectWillChange.sink { _ in republished.fulfill() }
        defer { subscription.cancel() }

        try fire(#"{"hook_event_name": "PreToolUse", "tool_name": "Bash"}"#)

        try await waitFor("Bash", describing: "the lead's in-flight tool") { self.monitor.toolNames.bySurface[self.surfaceId] }
        await fulfillment(of: [republished], timeout: 0.1)
    }

    // MARK: - The toggle

    func testDisablingClosesTheSocketAndForgetsEverySurface() async throws {
        monitor.setEnabled(true)
        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the worktree's phase") { self.monitor.worktreePhases[self.worktreeId] ?? .idle }

        monitor.setEnabled(false)

        XCTAssertTrue(monitor.worktreePhases.isEmpty, "a disabled monitor publishes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socketPath), "the socket goes with the listener")
        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        XCTAssertTrue(monitor.worktreePhases.isEmpty, "the forwarder's socket guard makes a disabled Clearway a no-op")
    }

    func testEnablingInstallsTheForwarderAndIsIdempotent() {
        monitor.setEnabled(true)
        monitor.setEnabled(true)

        XCTAssertEqual(try? String(contentsOfFile: paths.scriptPath, encoding: .utf8), AgentHookScript.body)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketPath))
    }

    /// The toggle is driven from `ClearwayApp`'s `.onAppear`, which fires once per window, so
    /// latching on the listener alone is not enough: a bind that fails leaves it nil and every
    /// window opened after it rewrites both agents' settings files on the main actor. A directory
    /// standing where the socket goes is a bind that cannot succeed.
    func testASecondEnableDoesNotReachTheInstallerAfterABindThatFailed() throws {
        try FileManager.default.createDirectory(atPath: paths.socketPath, withIntermediateDirectories: true)

        monitor.setEnabled(true)
        try FileManager.default.removeItem(atPath: paths.scriptPath)

        monitor.setEnabled(true)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.scriptPath),
            "the second enable must run nothing, so the forwarder it already wrote stays gone"
        )
    }

    /// The same latch from the other side, and the case that costs every launch: with the toggle
    /// off, `.onAppear` hands the monitor `false` once per window, and an unguarded `stop()` runs a
    /// synchronous settings rewrite each time.
    func testDisablingAMonitorThatWasNeverEnabledReachesNoUninstaller() throws {
        let claudeDir = (home as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let path = (claudeDir as NSString).appendingPathComponent("settings.json")
        let installed = try JSONSerialization.data(
            withJSONObject: AgentHookSettings.install(into: [:]),
            options: [.prettyPrinted, .sortedKeys]
        )
        try installed.write(to: URL(fileURLWithPath: path))

        monitor.setEnabled(false)

        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path)),
            installed,
            "a monitor that never started has nothing to tear down"
        )
    }

    // MARK: - Helpers

    /// Runs the installed forwarder exactly as an agent does: the three identity variables in the
    /// environment, the hook JSON on stdin, nothing else inherited.
    private func fire(_ json: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: paths.scriptPath)
        process.environment = [
            AgentHookIdentity.surfaceIdKey: surfaceId,
            AgentHookIdentity.worktreeIdKey: worktreeId,
            AgentHookIdentity.socketKey: paths.socketPath,
        ]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(json.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "a hook must never fail: a non-zero exit can block the tool call")
    }
}
