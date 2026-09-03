import XCTest
import GhosttyKit
@testable import Clearway

/// Per-entry `model` at the launch sites the coordinator owns: `performLaunch` (autopilot),
/// `planningAgentCommand` (Plan), and the command a step's "Run in New Terminal" stamps onto its
/// launcher tab. `applyModel`'s own per-agent matrix is `AgentLaunchModelTests`' subject; here the
/// question is only whether each site reads the right entry's model and pairs it with the right
/// agent.
@MainActor
final class WorkflowModelLaunchTests: WorkflowHarnessTestCase {

    // MARK: - Per-entry model

    /// A workflow whose `test` action and planning entry both name a model.
    private func writeModelledWorkflow() throws {
        try writeWorkflowJSON("""
        {
          "version": 1,
          "start": "implement",
          "planning": { "instructions": "Plan.", "model": "fable" },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Implement.", "routes": { "success": "test" } },
            "test": { "name": "Test", "instructions": "Test.", "model": "sonnet", "routes": { "success": "review" } },
            "review": { "name": "Review", "instructions": "Review." }
          }
        }
        """)
    }

    /// That `performLaunch` reads `action.model` and routes it through `applyModel`. The gate's own
    /// per-agent matrix is `AgentLaunchModelTests`' subject; here one accepting and one unknown
    /// command are enough to prove the value arrives.
    func testLaunchAppendsActionModel() throws {
        try writeModelledWorkflow()
        XCTAssertEqual(try capturedLaunchCommand(branch: "model-claude", mainTerminal: "claude"),
                       "claude --model sonnet")
    }

    func testLaunchIgnoresActionModelUnderAnUnknownAgent() throws {
        try writeModelledWorkflow()
        XCTAssertEqual(try capturedLaunchCommand(branch: "model-unknown", mainTerminal: "aider"),
                       "aider", "an unverified agent never receives the flag")
    }

    func testLaunchOfModellessActionIsUnchanged() throws {
        try writeWorkflow()
        XCTAssertEqual(try capturedLaunchCommand(branch: "model-none", mainTerminal: "claude"),
                       "claude", "an action with no model launches exactly as before")
    }

    /// A workflow that overrides `agent.command` carries its own agent to **every** launch site: a
    /// model is authored against that agent, so pairing it with Main Terminal's command instead —
    /// which is what a step's "Run in New Terminal" would do if it resolved its own command —
    /// hands `claude` a codex model id and breaks the launch outright.
    func testWorkflowAgentCommandKeepsTheModelWithTheWorkflowAgent() throws {
        try writeWorkflowJSON("""
        {
          "version": 1,
          "start": "implement",
          "agent": { "command": "codex" },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Implement.", "routes": { "success": "test" } },
            "test": {
              "name": "Test", "instructions": "Test.", "model": "gpt-5.4-codex",
              "routes": { "success": "review" }
            },
            "review": { "name": "Review", "instructions": "Review." }
          }
        }
        """)
        let branch = "agent-override"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)
        let definition = try WorkflowDefinition.load(projectPath: tempRoot)

        try withMainTerminalCommand("claude") {
            // The command handed to both `performLaunch` and the "Run in New Terminal" launcher tab.
            XCTAssertEqual(
                coordinator.workflowAgentCommand(for: definition, action: try XCTUnwrap(definition.actions["test"])),
                "codex --model gpt-5.4-codex"
            )
        }

        XCTAssertEqual(try capturedLaunchCommand(branch: "agent-override-run", mainTerminal: "claude"),
                       "codex --model gpt-5.4-codex")
    }

    func testPlanningCommandHonorsPlanningModel() throws {
        try writeModelledWorkflow()
        let branch = "planning-model"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        try withMainTerminalCommand("claude") {
            XCTAssertEqual(coordinator.planningAgentCommand, "claude --model fable")
        }
        try withMainTerminalCommand("aider") {
            XCTAssertEqual(coordinator.planningAgentCommand, "aider",
                           "an unverified agent never receives the flag")
        }
    }

    func testPlanningCommandUnchangedWithoutPlanningModel() throws {
        try writeWorkflowJSON("""
        {
          "version": 1,
          "start": "implement",
          "planning": { "instructions": "Plan." },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Implement." }
          }
        }
        """)
        let branch = "planning-no-model"
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        try withMainTerminalCommand("claude") {
            XCTAssertEqual(coordinator.planningAgentCommand, "claude")
        }
    }

    // MARK: - Run in New Terminal

    /// The stamp a step's "Run in New Terminal" puts on its launcher tab is the workflow's own
    /// resolved agent *and* the step's model — the same command autopilot would launch, not Main
    /// Terminal's. Observed through `launcherTabAppender` because `appendLauncherTab` builds a real
    /// Ghostty surface; without the seam this whole wiring is unpinnable, and dropping the `command:`
    /// argument would leave the suite green.
    func testRunInNewTerminalStampsTheWorkflowAgentAndModel() throws {
        try writeWorkflowJSON("""
        {
          "version": 1,
          "start": "implement",
          "agent": { "command": "codex" },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Implement.", "routes": { "success": "test" } },
            "test": { "name": "Test", "instructions": "Test.", "model": "gpt-5.4-codex" }
          }
        }
        """)
        let stamped = try stampedLauncherCommand(branch: "run-new-stamp", slug: "test", mainTerminal: "claude")
        XCTAssertEqual(stamped, "codex --model gpt-5.4-codex",
                       "the tab must run the workflow's agent on the step's model, not Main Terminal")
    }

    /// A step with no model still stamps, so the tab runs the workflow's agent rather than falling
    /// back to Main Terminal — the stamp carries the agent override even when there is no flag.
    func testRunInNewTerminalStampsAgentWithoutAModel() throws {
        try writeWorkflowJSON("""
        {
          "version": 1,
          "start": "implement",
          "agent": { "command": "codex" },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Implement.", "routes": { "success": "test" } },
            "test": { "name": "Test", "instructions": "Test." }
          }
        }
        """)
        let stamped = try stampedLauncherCommand(
            branch: "run-new-stamp-bare", slug: "test", mainTerminal: "claude")
        XCTAssertEqual(stamped, "codex", "no model means no flag, not a fallback to Main Terminal")
    }
}
