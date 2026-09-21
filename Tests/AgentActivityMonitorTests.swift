import Combine
import Darwin
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
    /// Holds a listener a case drove without a monitor, so it outlives the statement that built it
    /// and its `deinit` runs on teardown rather than wherever ARC chose.
    private var directListener: HookSocketListener?

    private let worktreePath = "/Users/x/my repo/.worktrees/a b"
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
        directListener = nil
        try? FileManager.default.removeItem(atPath: home)
        home = nil
        paths = nil
        try await super.tearDown()
    }

    // MARK: - The wire

    func testAForwardedEventLightsItsWorktreeAndAStopClearsIt() async throws {
        monitor.setEnabled(true)

        try fire(#"{"session_id": "s", "hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the worktree's phase") { self.monitor.worktreePhases[self.worktreePath] ?? .idle }

        try fire(#"{"session_id": "s", "hook_event_name": "Stop", "stop_reason": "end_turn"}"#)
        try await waitFor(.idle, describing: "the worktree's phase after Stop") { self.monitor.worktreePhases[self.worktreePath] ?? .idle }
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
        try await waitFor(.working, describing: "the worktree's phase over a stale socket path") { self.monitor.worktreePhases[self.worktreePath] ?? .idle }
    }

    /// The discriminating case for probing before the unlink: two Clearway builds on one machine —
    /// `build.sh`'s `Clearway (<worktree>).app` beside `ci.sh`'s `Clearway.app` — resolve the same
    /// fixed socket path. Unlinking it replaces the inode, and the live instance goes on reading a
    /// socket nothing can reach, with no dot change and no diagnostic on either side. The inode is
    /// what makes that observable: a file-exists check passes against a steal.
    func testAPathALiveInstanceAnswersOnIsLeftAlone() async throws {
        monitor.setEnabled(true)
        let inode = try socketInode()

        let second = AgentActivityMonitor(home: home)
        second.setEnabled(true)

        XCTAssertEqual(second.health, .socketOwnedByAnotherInstance, "the second instance must not take the socket")
        XCTAssertEqual(try socketInode(), inode, "an unlink would replace the inode the live instance is listening on")
        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the first monitor's worktree phase after a second instance started") {
            self.monitor.worktreePhases[self.worktreeId] ?? .idle
        }
    }

    /// The other half of the same rule, and why only a successful connect defends the path: an
    /// instance killed without closing leaves a socket inode that answers nothing. `connect` refuses
    /// it, so the unlink still runs and a crash costs no dot until the next reboot.
    func testASocketInodeLeftByADeadInstanceIsStillRebound() async throws {
        try makeClaudeSettingsDirectory()
        try FileManager.default.createDirectory(atPath: paths.clearwayDir, withIntermediateDirectories: true)
        try bindAndAbandon(paths.socketPath)

        monitor.setEnabled(true)

        XCTAssertEqual(monitor.health, .listening, "an inode nothing answers on is this instance's to take")
        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the worktree's phase over an abandoned socket inode") {
            self.monitor.worktreePhases[self.worktreeId] ?? .idle
        }
    }

    /// The discriminating case for the probe answering three ways rather than two: a mode that
    /// denies this process answers `EACCES`, which says nothing about who is there. Read as "nobody
    /// is there" it authorised the unlink, so a live owner whose socket this process cannot reach
    /// lost it and both instances reported that they were listening — the exact lie the probe
    /// exists to stop.
    func testAPathThisProcessMayNotReachIsLeftAloneAndReportedUnopenable() throws {
        try XCTSkipIf(getuid() == 0, "root reaches every mode, so no errno outside the three is reachable")
        try FileManager.default.createDirectory(atPath: paths.clearwayDir, withIntermediateDirectories: true)
        try bindAndAbandon(paths.socketPath)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: paths.socketPath)
        let inode = try socketInode()

        monitor.setEnabled(true)

        XCTAssertEqual(monitor.health, .socketUnopenable, "an errno the probe cannot account for is not an empty path")
        XCTAssertEqual(try socketInode(), inode, "and it authorises no unlink")
    }

    /// The discriminating case for dropping an empty read: a second instance's liveness probe
    /// connects and closes with nothing written, and a hang-up is not a message. Without the guard
    /// it reaches the callback, fails to parse, and every launch of a second Clearway writes a
    /// malformed-payload warning into the live instance's log — noise in the one channel this
    /// feature's failures are legible through.
    func testAConnectionThatWritesNothingNeverReachesTheCallback() async throws {
        try FileManager.default.createDirectory(atPath: paths.clearwayDir, withIntermediateDirectories: true)
        let delivered = DeliveredPayloads()
        guard case .listening(let opened) = HookSocketListener.start(
            socketPath: paths.socketPath,
            onPayload: { delivered.append($0) }
        ) else {
            return XCTFail("the listener must bind under a fresh temp home")
        }
        directListener = opened

        try connectToSocket(writing: nil)
        try connectToSocket(writing: Data(#"{"hook_event_name": "Stop"}"#.utf8))

        try await waitFor([#"{"hook_event_name": "Stop"}"#], describing: "the payloads that reached the callback") {
            delivered.all.map { String(data: $0, encoding: .utf8) ?? "" }
        }
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
            (self.monitor.worktreeSubagents[self.worktreePath] ?? []).compactMap(\.type)
        }
        XCTAssertEqual(monitor.worktreePhases[worktreePath], .working, "a live subagent is work even between the lead's turns")
    }

    /// `PreToolUse`/`PostToolUse` fire around every tool call, so the tool name changes far more
    /// often than anything the sidebar reads. Published off the monitor it invalidated every view
    /// observing any of the monitor's values, in every window — the whole tab strip included, whose
    /// chip-scoped `@ObservedObject` exists to prevent exactly that.
    func testAToolNameChangeDoesNotRepublishTheMonitor() async throws {
        monitor.setEnabled(true)
        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the worktree's phase") { self.monitor.worktreePhases[self.worktreePath] ?? .idle }

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
        try await waitFor(.working, describing: "the worktree's phase") { self.monitor.worktreePhases[self.worktreePath] ?? .idle }

        monitor.setEnabled(false)

        XCTAssertEqual(monitor.health, .off, "a disabled monitor owns no socket")
        XCTAssertTrue(monitor.worktreePhases.isEmpty, "a disabled monitor publishes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socketPath), "the socket goes with the listener")
        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        XCTAssertTrue(monitor.worktreePhases.isEmpty, "the forwarder's socket guard makes a disabled Clearway a no-op")
    }

    /// The same theft by a second door: a blocked instance never bound the path, so switching its
    /// toggle off must not take the socket the live instance is listening on. The inode is again
    /// what makes it observable — an unlink here leaves the first instance reading a descriptor
    /// nothing can reach, exactly the symptom the connect probe exists to prevent.
    func testDisablingAnInstanceThatNeverBoundLeavesTheLiveSocketAlone() async throws {
        monitor.setEnabled(true)
        let second = AgentActivityMonitor(home: home)
        second.setEnabled(true)
        XCTAssertEqual(second.health, .socketOwnedByAnotherInstance, "the fixture is only meaningful if the second instance was blocked")
        let inode = try socketInode()

        second.setEnabled(false)

        XCTAssertEqual(second.health, .off, "a blocked instance whose toggle went off is off, not somebody else's fault")
        XCTAssertEqual(try socketInode(), inode, "a blocked instance's stop() must not unlink a socket it never bound")
        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the first monitor's worktree phase after the second was disabled") {
            self.monitor.worktreePhases[self.worktreeId] ?? .idle
        }
    }

    /// The third door on the same theft, and the one a gate on "did this instance ever bind" cannot
    /// close: a path replaced underneath a running instance — by an older build with no probe, or
    /// through the window between this one's probe and its bind — must survive that instance's
    /// teardown. The unlink is scoped to the inode `bind` created, not to the name.
    func testATeardownLeavesAPathAnotherProcessHasSinceReboundAlone() throws {
        monitor.setEnabled(true)
        Darwin.unlink(paths.socketPath)
        try bindAndAbandon(paths.socketPath)
        let replacement = try socketInode()

        monitor.setEnabled(false)

        XCTAssertEqual(try socketInode(), replacement, "the teardown must not remove a socket this instance did not bind")
    }

    /// The only recovery from `.ownedByAnotherInstance`: nothing in the pipeline has a clock, so a
    /// blocked instance takes the socket when its toggle is cycled after the owner quits, and never
    /// on its own. The companion Settings task's retry affordance is exactly this sequence.
    func testABlockedInstanceTakesTheSocketOnceTheOwnerHasQuit() async throws {
        try makeClaudeSettingsDirectory()
        monitor.setEnabled(true)
        let second = AgentActivityMonitor(home: home)
        second.setEnabled(true)
        XCTAssertEqual(second.health, .socketOwnedByAnotherInstance, "the fixture is only meaningful if the second instance was blocked")

        monitor.setEnabled(false)
        second.setEnabled(false)
        second.setEnabled(true)

        XCTAssertEqual(second.health, .listening, "the owner has quit, so the path is the second instance's to take")
        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the second monitor's worktree phase after it took the socket") {
            second.worktreePhases[self.worktreeId] ?? .idle
        }
        second.setEnabled(false)
    }

    /// The install half of that same gate: an instance that never bound must not strip the hook
    /// block out of the agents' settings files on its way out either. The owner keeps a bound socket
    /// and a toggle reading on while no agent has a hook left to forward with.
    func testASecondInstancesDisableLeavesTheLiveOwnersHooksInstalled() throws {
        let settingsPath = try makeClaudeSettingsDirectory()

        monitor.setEnabled(true)
        let installed = try Data(contentsOf: URL(fileURLWithPath: settingsPath))

        let second = AgentActivityMonitor(home: home)
        second.setEnabled(true)
        XCTAssertEqual(second.health, .socketOwnedByAnotherInstance, "the fixture is only meaningful if the second instance was blocked")
        second.setEnabled(false)

        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: settingsPath)),
            installed,
            "the owner's hooks survive a second instance that never bound"
        )
    }

    /// The positive side of that gate: the instance that *did* bind still takes its block back out.
    /// `stop()` reads whether a listener was held one line before it clears it, so the order of
    /// those two lines is the whole rule, and reversing them leaves every user's `settings.json`
    /// carrying Clearway's hooks after the toggle is off.
    func testAnOwnersDisableRemovesTheHooksItInstalled() throws {
        let settingsPath = try makeClaudeSettingsDirectory()

        monitor.setEnabled(true)
        XCTAssertNotNil(try hooks(at: settingsPath), "the owner installed its block")

        monitor.setEnabled(false)

        XCTAssertNil(try hooks(at: settingsPath), "and took it back out")
    }

    /// The discriminating case for where the `unlink` lives: in the listener's `deinit`, which runs
    /// synchronously on the main actor at `listener = nil`, so a disable immediately followed by an
    /// enable cannot take away the socket the new listener has just bound. Get it wrong — unlink
    /// from the cancel handler, which fires on the source's own queue — and the toggle keeps reading
    /// on, the hooks stay installed, and nothing arrives again until the app is relaunched.
    func testTheFeedSurvivesADisableAndReEnable() async throws {
        monitor.setEnabled(true)
        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the worktree's phase") { self.monitor.worktreePhases[self.worktreePath] ?? .idle }

        monitor.setEnabled(false)
        monitor.setEnabled(true)

        try fire(#"{"hook_event_name": "UserPromptSubmit"}"#)
        try await waitFor(.working, describing: "the worktree's phase after a re-enable") { self.monitor.worktreePhases[self.worktreePath] ?? .idle }
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
        XCTAssertEqual(monitor.health, .socketUnopenable, "a bind that fails is neither off nor another instance's doing")
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
        let path = try makeClaudeSettingsDirectory()
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

    // MARK: - The health

    func testAnEnableThatListensReportsNothingAndGoesQuietOnDisable() throws {
        try makeClaudeSettingsDirectory()

        monitor.setEnabled(true)
        XCTAssertEqual(monitor.health, .listening)
        XCTAssertNil(monitor.health.message, "a working install has nothing to say in Settings")

        monitor.setEnabled(false)
        XCTAssertEqual(monitor.health, .off)
    }

    func testASettingsFileThatCannotBeMergedIsNamed() throws {
        let settingsPath = try makeClaudeSettingsDirectory()
        try Data("[1, 2, 3]".utf8).write(to: URL(fileURLWithPath: settingsPath))

        monitor.setEnabled(true)

        XCTAssertEqual(monitor.health, .settingsRefused(path: "~/.claude/settings.json"))
    }

    /// The temp home has neither agent, which is the one shape that earns the absence line: a user
    /// with Claude Code and no Codex must not carry a warning about a tool they do not use.
    func testAHomeWithNeitherAgentIsReportedAsHavingNoDirectory() {
        monitor.setEnabled(true)

        XCTAssertEqual(monitor.health, .noAgentDirectory)
    }

    // MARK: - Helpers

    /// The one agent directory `AgentHookInstaller` can install into, and the settings file it
    /// writes there. A temp home has neither agent, which resolves to `.noAgentDirectory` and hides
    /// whatever the socket did.
    @discardableResult
    private func makeClaudeSettingsDirectory() throws -> String {
        let directory = (home as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return (directory as NSString).appendingPathComponent("settings.json")
    }

    /// The managed block as the file carries it, or `nil` once `uninstall` has collapsed the
    /// container it emptied.
    private func hooks(at path: String) throws -> [String: Any]? {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let settings = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return settings?["hooks"] as? [String: Any]
    }

    private func socketInode() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.socketPath)
        return try XCTUnwrap(attributes[.systemFileNumber] as? UInt64, "the socket path must exist")
    }

    /// One connection, written to and closed. `nil` is the shape a second instance's liveness probe
    /// leaves behind; a payload is the shape the forwarder leaves.
    private func connectToSocket(writing payload: Data?) throws {
        let address = try XCTUnwrap(HookSocketListener.unixAddress(for: paths.socketPath))
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(HookSocketListener.withUnixAddress(address) { Darwin.connect(descriptor, $0, $1) }, 0)
        if let payload {
            payload.withUnsafeBytes { _ = Darwin.write(descriptor, $0.baseAddress, $0.count) }
        }
    }

    /// `bind` + `listen` on a descriptor closed without unlinking: what a killed instance leaves
    /// behind. A regular file written at the path is not the same thing — it answers `ENOTSOCK`,
    /// while this answers `ECONNREFUSED`.
    private func bindAndAbandon(_ socketPath: String) throws {
        let address = try XCTUnwrap(HookSocketListener.unixAddress(for: socketPath))
        // Qualified: `XCTestCase` inherits `NSObject.bind(_:to:withKeyPath:options:)`, which wins
        // the unqualified name inside a test case.
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let bound = HookSocketListener.withUnixAddress(address) { Darwin.bind(descriptor, $0, $1) }
        XCTAssertEqual(bound, 0, "the fixture must leave a real socket inode behind")
        XCTAssertEqual(Darwin.listen(descriptor, 64), 0)
        Darwin.close(descriptor)
    }

    /// Runs the installed forwarder exactly as an agent does: the three identity variables in the
    /// environment, the hook JSON on stdin, nothing else inherited.
    private func fire(_ json: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: paths.scriptPath)
        process.environment = [
            AgentHookIdentity.surfaceIdKey: surfaceId,
            AgentHookIdentity.worktreeIdKey: AgentActivityOwner.worktree(worktreePath).rawValue,
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

/// The listener's callback runs on its own queue, so what it saw crosses back under a lock.
private final class DeliveredPayloads: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [Data] = []

    func append(_ payload: Data) {
        lock.lock()
        defer { lock.unlock() }
        payloads.append(payload)
    }

    var all: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }
}
