import XCTest
@testable import Clearway

/// Pins `taskTerminalLaunchCommand`, the choice behind both doors onto the task terminal (the
/// toolbar toggle and Cmd+J): the bare Main Terminal command, or a plain shell. `toggleTaskTerminal`
/// itself is unreachable from XCTest — it takes a non-optional `ghostty_app_t` — so this helper is
/// the whole testable surface of the launch.
@MainActor
final class TaskTerminalLaunchCommandTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-task-terminal-launch" }

    /// A Main Terminal command is set: it runs bare, exactly as `buildBareCommand` builds it.
    func testBareMainTerminalCommandWhenConfigured() throws {
        let coordinator = makeCoordinator()
        coordinator.terminalManager.mainCommandProvider = { "claude" }

        let makeCommand = try XCTUnwrap(coordinator.taskTerminalLaunchCommand())
        let command = makeCommand("/usr/bin:/bin")

        XCTAssertEqual(
            command,
            coordinator.terminalManager.buildBareCommand(agentCommand: "claude", path: "/usr/bin:/bin")
        )
    }

    /// Nothing configured at all: no launch to build, so the panel opens on a plain shell. The
    /// provider is `settings.configuredMainTerminalCommand`, which is nil for a blank *or*
    /// whitespace-only setting (`SettingsManagerTests.test_configuredMainTerminalCommand_isNilWhenWhitespaceOnly`);
    /// the raw `UserDefaults` read this replaced saw `"   "` as non-empty and launched three spaces
    /// as a command, opening the panel on an immediately-dead terminal.
    func testNoConfiguredCommandOpensAPlainShell() throws {
        let coordinator = makeCoordinator()
        coordinator.terminalManager.mainCommandProvider = { nil }

        XCTAssertNil(coordinator.taskTerminalLaunchCommand())
    }

    // MARK: - Confirming a plan

    /// `planTask` closes whatever surface the task terminal already holds and opens a fresh one, so
    /// a plan started over a running agent would take its session away with no warning. A live
    /// foreground process is the whole of the rule; nothing else about the task matters.
    func testPlanNeedsConfirmationOnlyWhenAProcessIsRunning() {
        XCTAssertTrue(WorkTaskCoordinator.planNeedsConfirmation(hasActiveProcess: true))
        XCTAssertFalse(WorkTaskCoordinator.planNeedsConfirmation(hasActiveProcess: false))
    }
}
