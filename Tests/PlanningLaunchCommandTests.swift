import XCTest
@testable import Clearway

/// Pins `planningLaunchCommand`, the three-way choice behind both doors onto the planning terminal
/// (the Plan button and Cmd+J): the planning agent on a rendered prompt, the bare Main Terminal
/// command, or a plain shell. `planTask` itself is unreachable from XCTest — it takes a
/// non-optional `ghostty_app_t` — so this helper is the whole testable surface of the launch.
@MainActor
final class PlanningLaunchCommandTests: WorkflowHarnessTestCase {

    /// A one-action workflow carrying `planningEntry` as its `planning` object (omitted when nil),
    /// plus the task the launch renders against.
    private func makeLaunchFixture(
        branch: String,
        planningEntry: String?
    ) throws -> (WorkTaskCoordinator, WorkTask) {
        let planningBlock = planningEntry.map { "\"planning\": { \($0) }," } ?? ""
        try writeWorkflowJSON("""
        {
          "version": 1,
          "start": "implement",
          \(planningBlock)
          "actions": {
            "implement": { "name": "Implement", "instructions": "Implement." }
          }
        }
        """)
        let id = UUID()
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement", id: id)
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        return (coordinator, WorkTask(id: id, title: "Task", status: "implement", worktree: branch))
    }

    /// Planning instructions win outright: the Main Terminal command is never consulted, and the
    /// entry's own agent runs the rendered prompt. Guards against the branches being reordered so
    /// the fallback shadows the planning agent — Cmd+J and Plan would silently stop running the
    /// workflow's planning agent, which is the headline behavior of this path.
    func testPlanningInstructionsWinOverTheMainTerminalCommand() throws {
        let (coordinator, task) = try makeLaunchFixture(
            branch: "plan-instructions",
            planningEntry: #""instructions": "Plan {{title}}.", "command": "codex""#
        )
        coordinator.terminalManager.mainCommandProvider = { "claude" }

        let makeCommand = try XCTUnwrap(coordinator.planningLaunchCommand(for: task))
        let command = makeCommand("/usr/bin:/bin")

        XCTAssertTrue(command.contains("codex"), command)
        XCTAssertFalse(command.contains("claude"), "the Main Terminal command must not leak in")
        XCTAssertTrue(command.contains("clearway-plan"), "the rendered prompt goes through a prompt file")
    }

    /// No planning instructions, but a Main Terminal command is set: it runs bare, with no prompt
    /// file. Guards against this branch regressing to the prompt-file recipe, which would launch
    /// the agent against a `$2` that was never written.
    func testBareMainTerminalCommandWhenNoPlanningInstructions() throws {
        let (coordinator, task) = try makeLaunchFixture(branch: "plan-bare", planningEntry: nil)
        coordinator.terminalManager.mainCommandProvider = { "claude" }

        let makeCommand = try XCTUnwrap(coordinator.planningLaunchCommand(for: task))
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
        let (coordinator, task) = try makeLaunchFixture(branch: "plan-blank", planningEntry: nil)
        coordinator.terminalManager.mainCommandProvider = { nil }

        XCTAssertNil(coordinator.planningLaunchCommand(for: task))
    }
}
