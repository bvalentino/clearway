import XCTest
@testable import Clearway

/// Pins `planningLaunchCommand`, the choice behind both doors onto the planning terminal (the Plan
/// icon and Cmd+J): the bare Main Terminal command, or a plain shell. `planTask` itself is
/// unreachable from XCTest — it takes a non-optional `ghostty_app_t` — so this helper is the whole
/// testable surface of the launch.
@MainActor
final class PlanningLaunchCommandTests: TempRootTestCase {

    override class var tempRootPrefix: String { "clearway-planning-launch" }

    /// A coordinator scoped to the scratch root. The launch reads nothing but the terminal manager's
    /// `mainCommandProvider`, so no task or worktree fixture is needed.
    private func makeCoordinator() -> WorkTaskCoordinator {
        WorkTaskCoordinator(
            workTaskManager: WorkTaskManager(projectPath: tempRoot),
            terminalManager: TerminalManager(),
            worktreeManager: WorktreeManager(projectPath: tempRoot)
        )
    }

    /// A Main Terminal command is set: it runs bare, with no prompt file. Guards against this branch
    /// regressing to the prompt-file recipe, which would launch the agent against a `$2` that was
    /// never written.
    func testBareMainTerminalCommandWhenConfigured() throws {
        let coordinator = makeCoordinator()
        coordinator.terminalManager.mainCommandProvider = { "claude" }

        let makeCommand = try XCTUnwrap(coordinator.planningLaunchCommand())
        let command = makeCommand("/usr/bin:/bin")

        XCTAssertEqual(
            command,
            coordinator.terminalManager.buildBareCommand(agentCommand: "claude", path: "/usr/bin:/bin")
        )
        XCTAssertFalse(command.contains("clearway-plan"), "a bare command carries no prompt file")
    }

    /// Nothing configured at all: no launch to build, so the panel opens on a plain shell. The
    /// provider is `settings.configuredMainTerminalCommand`, which is nil for a blank *or*
    /// whitespace-only setting (`SettingsManagerTests.test_configuredMainTerminalCommand_isNilWhenWhitespaceOnly`);
    /// the raw `UserDefaults` read this replaced saw `"   "` as non-empty and launched three spaces
    /// as a command, opening the panel on an immediately-dead terminal.
    func testNoConfiguredCommandOpensAPlainShell() throws {
        let coordinator = makeCoordinator()
        coordinator.terminalManager.mainCommandProvider = { nil }

        XCTAssertNil(coordinator.planningLaunchCommand())
    }
}
