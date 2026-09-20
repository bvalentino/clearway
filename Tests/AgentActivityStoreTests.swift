import XCTest
@testable import Clearway

private let surfaceA = "1D3C7E9A-0000-4000-8000-00000000000A"
private let surfaceB = "1D3C7E9A-0000-4000-8000-00000000000B"
private let worktreeOne = "/Users/x/my repo/.worktrees/one"
private let worktreeTwo = "/Users/x/my repo/.worktrees/two"

/// Pins the transitions of the spec's Decision 20 and the worktree derivation of Decision 21. Every
/// event goes in through `AgentHookEnvelope.parse`, so the wire format is exercised alongside the
/// rule rather than bypassed by hand-built values.
final class AgentActivityStoreTests: XCTestCase {

    private var store = AgentActivityStore()

    // MARK: - The lead agent

    func testUserPromptSubmitWorksAndStopIdles() {
        apply("UserPromptSubmit")
        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .working)

        apply("Stop")
        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .idle)
    }

    func testPreToolUseSetsTheLeadToolAndPostToolUseClearsIt() {
        apply("PreToolUse", tool: "Bash")
        XCTAssertEqual(store.leadToolName(forSurface: surfaceA), "Bash")
        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .working)

        apply("PostToolUse", tool: "Bash")
        XCTAssertNil(store.leadToolName(forSurface: surfaceA))
        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .working)
    }

    /// The discriminating case for "clear the *corresponding* tool": a subagent's tool traffic must
    /// never touch the lead's label, or the tab chip goes blank while the lead is still running.
    func testSubagentToolTrafficLeavesTheLeadToolAlone() {
        apply("PreToolUse", tool: "Edit")
        apply("PreToolUse", tool: "Grep", agentId: "sub-1")

        XCTAssertEqual(store.leadToolName(forSurface: surfaceA), "Edit")
        XCTAssertEqual(store.subagents(forWorktree: worktreeOne).map(\.toolName), ["Grep"])

        apply("PostToolUse", tool: "Grep", agentId: "sub-1")

        XCTAssertEqual(store.leadToolName(forSurface: surfaceA), "Edit")
        XCTAssertEqual(store.subagents(forWorktree: worktreeOne).map(\.toolName), [String?.none])
    }

    // MARK: - Waiting on permission

    func testPermissionRequestWaitsAndRecordsItsTool() {
        apply("UserPromptSubmit")
        apply("PermissionRequest", tool: "Bash")

        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .waiting)
        XCTAssertEqual(store.leadToolName(forSurface: surfaceA), "Bash")
    }

    func testPostToolUseReturnsAWaitingSurfaceToWorking() {
        apply("PermissionRequest", tool: "Bash")
        apply("PostToolUse", tool: "Bash")

        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .working)
    }

    func testUserPromptSubmitReturnsAWaitingSurfaceToWorking() {
        apply("PermissionRequest", tool: "Bash")
        apply("UserPromptSubmit")

        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .working)
    }

    // MARK: - The subagent roster

    func testSubagentStartAddsARowAndSubagentStopRemovesIt() {
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")

        XCTAssertEqual(store.subagents(forWorktree: worktreeOne).map(\.id), ["sub-1"])
        XCTAssertEqual(store.subagents(forWorktree: worktreeOne).map(\.type), ["Explore"])

        apply("SubagentStop", agentId: "sub-1")

        XCTAssertTrue(store.subagents(forWorktree: worktreeOne).isEmpty)
    }

    /// A missed `SubagentStop` must not pin a row. `Stop` is the sweep that guarantees it.
    func testStopClearsEveryOpenSubagent() {
        apply("UserPromptSubmit")
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")
        apply("SubagentStart", agentId: "sub-2", agentType: "Plan")
        XCTAssertEqual(store.subagents(forWorktree: worktreeOne).count, 2)

        apply("Stop")

        XCTAssertTrue(store.subagents(forWorktree: worktreeOne).isEmpty)
        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .idle)
    }

    /// A subagent is work even when the lead is between turns, so the dot stays lit.
    func testIdleSurfaceHoldingALiveSubagentReadsAsWorking() {
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")

        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .working)
    }

    func testSubagentOrderIsStableAcrossCalls() {
        for id in ["sub-9", "sub-1", "sub-5", "sub-3"] {
            apply("SubagentStart", agentId: id, agentType: "Explore")
        }

        let first = store.subagents(forWorktree: worktreeOne).map(\.id)
        XCTAssertEqual(first, ["sub-1", "sub-3", "sub-5", "sub-9"])
        XCTAssertEqual(store.subagents(forWorktree: worktreeOne).map(\.id), first)
    }

    // MARK: - Session boundaries

    func testSessionStartResetsASurfaceMidWork() {
        apply("UserPromptSubmit")
        apply("PreToolUse", tool: "Bash")
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")

        apply("SessionStart")

        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .idle)
        XCTAssertNil(store.leadToolName(forSurface: surfaceA))
        XCTAssertTrue(store.subagents(forWorktree: worktreeOne).isEmpty)
    }

    func testSessionEndDropsTheSurfaceEntirely() {
        apply("UserPromptSubmit")
        apply("UserPromptSubmit", surface: surfaceB)

        apply("SessionEnd")

        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .working)
        XCTAssertNil(store.leadToolName(forSurface: surfaceA))

        apply("SessionEnd", surface: surfaceB)

        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .idle)
    }

    // MARK: - Retirement

    func testEventsForARetiredSurfaceChangeNothing() {
        apply("UserPromptSubmit")
        store.retire(surfaceId: surfaceA)
        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .idle)

        apply("PreToolUse", tool: "Bash")
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")

        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .idle)
        XCTAssertNil(store.leadToolName(forSurface: surfaceA))
        XCTAssertTrue(store.subagents(forWorktree: worktreeOne).isEmpty)
    }

    func testRetiringAWorktreeDropsEveryOneOfItsSurfaces() {
        apply("UserPromptSubmit")
        apply("UserPromptSubmit", surface: surfaceB)
        apply("UserPromptSubmit", surface: "surface-c", worktree: worktreeTwo)

        store.retire(worktreeId: worktreeOne)

        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .idle)
        XCTAssertEqual(store.phase(forWorktree: worktreeTwo), .working)
    }

    // MARK: - Worktree derivation

    func testWorktreesAreIndependent() {
        apply("UserPromptSubmit")
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")

        XCTAssertEqual(store.phase(forWorktree: worktreeTwo), .idle)
        XCTAssertTrue(store.subagents(forWorktree: worktreeTwo).isEmpty)
        XCTAssertEqual(store.subagents(forWorktree: worktreeOne).map(\.id), ["sub-1"])
    }

    func testWaitingWinsOverWorkingOnTheSameWorktree() {
        apply("UserPromptSubmit")
        apply("PermissionRequest", surface: surfaceB, tool: "Bash")

        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .waiting)
    }

    /// Decision 6: a surface id minted before a Clearway relaunch is unknown to this process, yet
    /// its worktree id still is. There is no registration step for an event to fail.
    func testAnUnknownSurfaceStillLightsItsWorktree() {
        apply("PreToolUse", surface: "a-surface-from-a-previous-launch", tool: "Bash")

        XCTAssertEqual(store.phase(forWorktree: worktreeOne), .working)
    }

    // MARK: - Helpers

    private func apply(
        _ event: String,
        surface: String = surfaceA,
        worktree: String = worktreeOne,
        tool: String? = nil,
        agentId: String? = nil,
        agentType: String? = nil
    ) {
        var fields = [#""hook_event_name":"\#(event)""#]
        if let tool { fields.append(#""tool_name":"\#(tool)""#) }
        if let agentId { fields.append(#""agent_id":"\#(agentId)""#) }
        if let agentType { fields.append(#""agent_type":"\#(agentType)""#) }
        let payload = Data("\(surface)\n\(worktree)\n{\(fields.joined(separator: ","))}".utf8)

        guard let envelope = AgentHookEnvelope.parse(payload) else {
            return XCTFail("the test helper built an unparseable \(event) payload")
        }
        store.apply(envelope)
    }
}
