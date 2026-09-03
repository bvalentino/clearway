import XCTest
import GhosttyKit
@testable import Clearway

/// Per-entry `command` at the launch sites the coordinator owns: `performLaunch` (autopilot),
/// `planningAgentCommand` (Plan), and the command a step's "Run in New Terminal" stamps onto its
/// launcher tab. The allowlist's own matrix is `AgentLaunchAgentTests`' subject; here the question
/// is only whether each site reads the right entry's agent and pairs it with that entry's model.
@MainActor
final class WorkflowAgentLaunchTests: WorkflowHarnessTestCase {

    /// A three-step workflow under a workflow-wide `agent`, whose `test` action carries the given
    /// per-entry agent and model. Each is omitted when empty, so callers never hand over punctuation.
    private func writeAgentWorkflow(
        workflowAgent: String,
        actionAgent: String = "",
        actionModel: String = ""
    ) throws {
        let entry = [("command", actionAgent), ("model", actionModel)]
            .filter { !$0.1.isEmpty }
            .map { "\"\($0.0)\": \"\($0.1)\", " }
            .joined()
        try writeWorkflowJSON("""
        {
          "version": 1,
          "start": "implement",
          "agent": { "command": "\(workflowAgent)" },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Implement.", "routes": { "success": "test" } },
            "test": { "name": "Test", "instructions": "Test.", \(entry)"routes": { "success": "review" } },
            "review": { "name": "Review", "instructions": "Review." }
          }
        }
        """)
    }

    // MARK: - Autopilot

    func testLaunchUsesTheActionAgentOverTheWorkflowAgent() throws {
        try writeAgentWorkflow(workflowAgent: "claude", actionAgent: "codex")
        XCTAssertEqual(try capturedLaunchCommand(branch: "agent-entry", mainTerminal: "grok"), "codex")
    }

    /// The two fields are independent, so a step that names its own agent still gets its own model.
    func testLaunchComposesTheActionAgentWithTheActionModel() throws {
        try writeAgentWorkflow(workflowAgent: "claude", actionAgent: "codex", actionModel: "gpt-5.4-codex")
        XCTAssertEqual(try capturedLaunchCommand(branch: "agent-entry-model", mainTerminal: "claude"),
                       "codex --model gpt-5.4-codex")
    }

    func testLaunchFallsThroughAnOffAllowlistActionAgentToTheWorkflowAgent() throws {
        try writeAgentWorkflow(workflowAgent: "codex", actionAgent: "aider")
        XCTAssertEqual(try capturedLaunchCommand(branch: "agent-entry-bad", mainTerminal: "grok"), "codex",
                       "an unusable entry agent inherits rather than failing")
    }

    /// The knowing break: a multi-word workflow-wide `agent.command` is no longer honored.
    func testLaunchFallsThroughAnOffAllowlistWorkflowAgentToSettings() throws {
        try writeAgentWorkflow(workflowAgent: "claude --dangerously-skip-permissions")
        XCTAssertEqual(try capturedLaunchCommand(branch: "agent-workflow-bad", mainTerminal: "grok"), "grok")
    }

    // MARK: - Plan

    /// The command `planningAgentCommand` resolves for a one-action workflow whose `planning` entry
    /// carries `planningEntry`, under a workflow-wide `agent` and Main Terminal `grok`.
    private func planningCommand(
        branch: String,
        workflowAgent: String,
        planningEntry: String
    ) throws -> String {
        try writeWorkflowJSON("""
        {
          "version": 1,
          "start": "implement",
          "agent": { "command": "\(workflowAgent)" },
          "planning": { "instructions": "Plan.", \(planningEntry) },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Implement." }
          }
        }
        """)
        let worktreePath = try writeWorktreeTask(branch: branch, status: "implement")
        let coordinator = makeCoordinator(branch: branch, worktreePath: worktreePath)

        var resolved = ""
        withMainTerminalCommand("grok") { resolved = coordinator.planningAgentCommand }
        return resolved
    }

    func testPlanningUsesItsOwnAgentAndModel() throws {
        let command = try planningCommand(
            branch: "planning-agent",
            workflowAgent: "claude",
            planningEntry: #""command": "codex", "model": "gpt-5.4-codex""#
        )
        XCTAssertEqual(command, "codex --model gpt-5.4-codex")
    }

    func testPlanningFallsThroughAnOffAllowlistAgentToTheWorkflowAgent() throws {
        let command = try planningCommand(
            branch: "planning-agent-bad",
            workflowAgent: "codex",
            planningEntry: #""command": "aider""#
        )
        XCTAssertEqual(command, "codex")
    }

    // MARK: - Run in New Terminal

    /// The stamp must carry the *entry's* agent, so the launcher placeholder and its submit agree
    /// with what autopilot would have run.
    func testRunInNewTerminalStampsTheActionAgentAndModel() throws {
        try writeWorkflowJSON("""
        {
          "version": 1,
          "start": "implement",
          "agent": { "command": "claude" },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Implement.", "routes": { "success": "test" } },
            "test": { "name": "Test", "instructions": "Test.", "command": "codex", "model": "gpt-5.4-codex" }
          }
        }
        """)
        let stamped = try stampedLauncherCommand(branch: "agent-run-new", slug: "test", mainTerminal: "grok")
        XCTAssertEqual(stamped, "codex --model gpt-5.4-codex",
                       "the tab must run the step's own agent, not the workflow's or Main Terminal's")
    }
}
