import XCTest
@testable import Clearway

private let surfaceA = "1D3C7E9A-0000-4000-8000-00000000000A"
private let surfaceB = "1D3C7E9A-0000-4000-8000-00000000000B"
private let worktreeOne = "/Users/x/my repo/.worktrees/one"
private let worktreeTwo = "/Users/x/my repo/.worktrees/two"
private let taskOne = UUID(uuidString: "2E4F8A1B-0000-4000-8000-000000000001")!
private let taskTwo = UUID(uuidString: "2E4F8A1B-0000-4000-8000-000000000002")!

/// Pins the transitions of the spec's Decision 20 and the worktree derivation of Decision 21. Every
/// event goes in through `AgentHookEnvelope.parse`, so the wire format is exercised alongside the
/// rule rather than bypassed by hand-built values.
final class AgentActivityStoreTests: XCTestCase {

    private var store = AgentActivityStore()

    // MARK: - The lead agent

    func testUserPromptSubmitWorksAndStopIdles() {
        apply("UserPromptSubmit")
        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .working)

        apply("Stop")
        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .idle)
    }

    func testPreToolUseSetsTheLeadToolAndPostToolUseClearsIt() {
        apply("PreToolUse", tool: "Bash")
        XCTAssertEqual(store.surfaceToolNames[surfaceA], "Bash")
        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .working)

        apply("PostToolUse", tool: "Bash")
        XCTAssertNil(store.surfaceToolNames[surfaceA])
        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .working)
    }

    /// The discriminating case for "the lead's tool is the lead's alone": a subagent's tool traffic
    /// must never touch that label, or the tab chip goes blank while the lead is still running. The
    /// traffic still names the subagent's row, and neither event may drop it.
    func testSubagentToolTrafficLeavesTheLeadToolAlone() {
        apply("PreToolUse", tool: "Edit")
        apply("PreToolUse", tool: "Grep", agentId: "sub-1")

        XCTAssertEqual(store.surfaceToolNames[surfaceA], "Edit")
        XCTAssertEqual((store.worktreeSubagents[worktreeOne] ?? []).map(\.id), ["sub-1"])

        apply("PostToolUse", tool: "Grep", agentId: "sub-1")

        XCTAssertEqual(store.surfaceToolNames[surfaceA], "Edit")
        XCTAssertEqual((store.worktreeSubagents[worktreeOne] ?? []).map(\.id), ["sub-1"])
    }

    // MARK: - Waiting on permission

    func testPermissionRequestWaitsAndRecordsItsTool() {
        apply("UserPromptSubmit")
        apply("PermissionRequest", tool: "Bash")

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .waiting)
        XCTAssertEqual(store.surfaceToolNames[surfaceA], "Bash")
    }

    func testPostToolUseReturnsAWaitingSurfaceToWorking() {
        apply("PermissionRequest", tool: "Bash")
        apply("PostToolUse", tool: "Bash")

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .working)
    }

    func testUserPromptSubmitReturnsAWaitingSurfaceToWorking() {
        apply("PermissionRequest", tool: "Bash")
        apply("UserPromptSubmit")

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .working)
    }

    /// The phase is the lead's alone, and a subagent's tool traffic must not take it off a
    /// permission prompt — the one state that needs the user, and the one a background subagent
    /// running beside the lead would otherwise clear within a second of it appearing.
    func testASubagentsToolTrafficLeavesTheLeadWaiting() {
        apply("PermissionRequest", tool: "Bash")
        applyRaw(subagentPreToolUse(agentId: "a42b06983b46906f7"))

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .waiting)

        apply("PostToolUse", tool: "Bash", agentId: "a42b06983b46906f7")

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .waiting)
    }

    // MARK: - The subagent roster

    func testSubagentStartAddsARowAndSubagentStopRemovesIt() {
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")

        XCTAssertEqual((store.worktreeSubagents[worktreeOne] ?? []).map(\.id), ["sub-1"])
        XCTAssertEqual((store.worktreeSubagents[worktreeOne] ?? []).map(\.type), ["Explore"])

        apply("SubagentStop", agentId: "sub-1")

        XCTAssertTrue((store.worktreeSubagents[worktreeOne] ?? []).isEmpty)
    }

    /// A missed `SubagentStop` must not pin a row. A `Stop` that reports no background work left is
    /// the sweep that guarantees it.
    func testStopClearsEveryOpenSubagentItDoesNotReportAsRunning() {
        apply("UserPromptSubmit")
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")
        apply("SubagentStart", agentId: "sub-2", agentType: "Plan")
        XCTAssertEqual((store.worktreeSubagents[worktreeOne] ?? []).count, 2)

        apply("Stop")

        XCTAssertTrue((store.worktreeSubagents[worktreeOne] ?? []).isEmpty)
        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .idle)
    }

    /// A subagent is work even when the lead is between turns, so the dot stays lit.
    func testIdleSurfaceHoldingALiveSubagentReadsAsWorking() {
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .working)
    }

    func testSubagentOrderIsStableAcrossCalls() {
        for id in ["sub-9", "sub-1", "sub-5", "sub-3"] {
            apply("SubagentStart", agentId: id, agentType: "Explore")
        }

        let first = (store.worktreeSubagents[worktreeOne] ?? []).map(\.id)
        XCTAssertEqual(first, ["sub-1", "sub-3", "sub-5", "sub-9"])
        XCTAssertEqual((store.worktreeSubagents[worktreeOne] ?? []).map(\.id), first)
    }

    // MARK: - Session boundaries

    func testSessionStartResetsASurfaceMidWork() {
        apply("UserPromptSubmit")
        apply("PreToolUse", tool: "Bash")
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")

        apply("SessionStart")

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .idle)
        XCTAssertNil(store.surfaceToolNames[surfaceA])
        XCTAssertTrue((store.worktreeSubagents[worktreeOne] ?? []).isEmpty)
    }

    func testSessionEndDropsTheSurfaceEntirely() {
        apply("UserPromptSubmit")
        apply("UserPromptSubmit", surface: surfaceB)

        apply("SessionEnd")

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .working)
        XCTAssertNil(store.surfaceToolNames[surfaceA])

        apply("SessionEnd", surface: surfaceB)

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .idle)
    }

    // MARK: - Retirement

    func testEventsForARetiredSurfaceChangeNothing() {
        apply("UserPromptSubmit")
        store.retire(surfaceId: surfaceA)
        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .idle)

        apply("PreToolUse", tool: "Bash")
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .idle)
        XCTAssertNil(store.surfaceToolNames[surfaceA])
        XCTAssertTrue((store.worktreeSubagents[worktreeOne] ?? []).isEmpty)
    }

    // MARK: - Worktree derivation

    func testWorktreesAreIndependent() {
        apply("UserPromptSubmit")
        apply("SubagentStart", agentId: "sub-1", agentType: "Explore")

        XCTAssertEqual((store.worktreePhases[worktreeTwo] ?? .idle), .idle)
        XCTAssertTrue((store.worktreeSubagents[worktreeTwo] ?? []).isEmpty)
        XCTAssertEqual((store.worktreeSubagents[worktreeOne] ?? []).map(\.id), ["sub-1"])
    }

    func testWaitingWinsOverWorkingOnTheSameWorktree() {
        apply("UserPromptSubmit")
        apply("PermissionRequest", surface: surfaceB, tool: "Bash")

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .waiting)
    }

    /// Decision 6: a surface id minted before a Clearway relaunch is unknown to this process, yet
    /// its worktree id still is. There is no registration step for an event to fail.
    func testAnUnknownSurfaceStillLightsItsWorktree() {
        apply("PreToolUse", surface: "a-surface-from-a-previous-launch", tool: "Bash")

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .working)
    }

    // MARK: - Background subagents, from captured Claude Code payloads

    /// Two background subagents, replayed from the payloads a Claude Code 2.1.278 session actually
    /// sent. The lead answers — and so `Stop`s — while both are still running, which is what a
    /// background launch means; the payload names them, so both rows survive it, and the `Bash` one
    /// of them runs takes away neither the other's row nor the lead's own label.
    func testBackgroundSubagentsSurviveTheLeadsStop() {
        applyRaw(subagentStart(agentId: "a42b06983b46906f7"))
        applyRaw(subagentStart(agentId: "aa713d00cbb27a6be"))

        applyRaw(stop(running: [
            ("a42b06983b46906f7", "Count Swift files slowly"),
            ("aa713d00cbb27a6be", "Count test files slowly")
        ]))

        XCTAssertEqual(
            (store.worktreeSubagents[worktreeOne] ?? []).map(\.id),
            ["a42b06983b46906f7", "aa713d00cbb27a6be"]
        )
        XCTAssertEqual(
            (store.worktreeSubagents[worktreeOne] ?? []).map(\.type),
            ["general-purpose", "general-purpose"]
        )
        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .working)

        applyRaw(subagentPreToolUse(agentId: "a42b06983b46906f7"))

        XCTAssertEqual(
            (store.worktreeSubagents[worktreeOne] ?? []).map(\.id),
            ["a42b06983b46906f7", "aa713d00cbb27a6be"]
        )
        XCTAssertNil(store.surfaceToolNames[surfaceA])
    }

    /// The same run's ending: each `SubagentStop` drops its own row, and the `Stop` that follows
    /// reports the survivor rather than clearing the roster under it.
    func testASubagentStopDropsOneRowAndTheNextStopKeepsTheOther() {
        applyRaw(subagentStart(agentId: "a42b06983b46906f7"))
        applyRaw(subagentStart(agentId: "aa713d00cbb27a6be"))
        apply("SubagentStop", agentId: "a42b06983b46906f7")

        applyRaw(stop(running: [("aa713d00cbb27a6be", "Count test files slowly")]))

        XCTAssertEqual((store.worktreeSubagents[worktreeOne] ?? []).map(\.id), ["aa713d00cbb27a6be"])

        applyRaw(stop(running: []))

        XCTAssertTrue((store.worktreeSubagents[worktreeOne] ?? []).isEmpty)
        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .idle)
    }

    /// The discriminating case for the phase being the lead's alone. A background subagent outlives
    /// the lead's `Stop`, so its tool traffic arrives while the lead is idle; a phase written from
    /// that traffic outlives the row that justified it, and the `SubagentStop` that takes the row
    /// away then leaves the worktree lit with nothing running and no event left to clear it —
    /// `Stop` has already been and gone, and nothing in the pipeline has a clock.
    func testABackgroundSubagentsToolTrafficDoesNotOutliveItsRow() {
        applyRaw(subagentStart(agentId: "a42b06983b46906f7"))
        applyRaw(stop(running: [("a42b06983b46906f7", "Count Swift files slowly")]))
        applyRaw(subagentPreToolUse(agentId: "a42b06983b46906f7"))

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .working)

        apply("SubagentStop", agentId: "a42b06983b46906f7")

        XCTAssertEqual((store.worktreePhases[worktreeOne] ?? .idle), .idle)
    }

    /// A subagent whose `SubagentStart` Clearway missed — the app launched mid-run — is named by its
    /// own tool traffic, which carries `agent_type` beside `agent_id`, rather than falling back to
    /// `SubagentRow`'s "Subagent".
    func testASubagentFirstSeenThroughItsToolTrafficIsStillNamed() {
        applyRaw(subagentPreToolUse(agentId: "ac545fc45491c3fde"))

        XCTAssertEqual((store.worktreeSubagents[worktreeOne] ?? []).map(\.type), ["general-purpose"])
    }

    /// `Stop`'s `background_tasks` is the only payload carrying the prompt's own summary, so the row
    /// takes it from there and keeps it: the tool traffic that follows names no description, and
    /// neither does a later `Stop` whose entry omits one.
    func testAStopsDescriptionLandsOnTheRowAndIsNotBlankedByLaterEvents() {
        applyRaw(subagentStart(agentId: "a42b06983b46906f7"))
        applyRaw(stop(running: [("a42b06983b46906f7", "Count Swift files slowly")]))

        XCTAssertEqual(
            (store.worktreeSubagents[worktreeOne] ?? []).map(\.description),
            ["Count Swift files slowly"]
        )

        applyRaw(subagentPreToolUse(agentId: "a42b06983b46906f7"))
        applyRaw(stop(running: [("a42b06983b46906f7", nil)]))

        XCTAssertEqual(
            (store.worktreeSubagents[worktreeOne] ?? []).map(\.description),
            ["Count Swift files slowly"]
        )
    }

    // MARK: - Task owners

    /// The whole point of the tagged owner: an agent in a task terminal lands on its task and
    /// leaves the worktree it happens to run in dark.
    func testATaskOwnerContributesToTaskPhasesAndNotToWorktreePhases() {
        apply("UserPromptSubmit", owner: .task(taskOne))

        XCTAssertEqual(store.taskPhases[taskOne], .working)
        XCTAssertTrue(store.worktreePhases.isEmpty)
    }

    func testAWorktreeOwnerContributesToWorktreePhasesAndNotToTaskPhases() {
        apply("UserPromptSubmit")

        XCTAssertEqual(store.worktreePhases[worktreeOne], .working)
        XCTAssertTrue(store.taskPhases.isEmpty)
    }

    /// A task row carries no subagent children by design, so a task surface's roster contributes no
    /// key at all. Its lead still reads as working between turns, because `effectivePhase` lifts
    /// the surface before either derivation sees it.
    func testATaskOwnersLiveSubagentRaisesItsPhaseAndNoRosterKey() {
        applyRaw(subagentStart(agentId: "a42b06983b46906f7"), owner: .task(taskOne))
        applyRaw(stop(running: [("a42b06983b46906f7", "Count Swift files slowly")]), owner: .task(taskOne))

        XCTAssertEqual(store.taskPhases[taskOne], .working)
        XCTAssertTrue(store.worktreeSubagents.isEmpty)
    }

    func testRetiringATaskSurfaceClearsItsTaskPhase() {
        apply("UserPromptSubmit", owner: .task(taskOne))
        XCTAssertEqual(store.taskPhases[taskOne], .working)

        store.retire(surfaceId: surfaceA)

        XCTAssertNil(store.taskPhases[taskOne])
    }

    func testTasksAreIndependent() {
        apply("UserPromptSubmit", owner: .task(taskOne))
        apply("PermissionRequest", surface: surfaceB, owner: .task(taskTwo), tool: "Bash")

        XCTAssertEqual(store.taskPhases[taskOne], .working)
        XCTAssertEqual(store.taskPhases[taskTwo], .waiting)
    }

    // MARK: - Helpers

    /// The captured payloads, verbatim but for the home-directory paths. Every key the agent sends
    /// is kept, so the decode is exercised against the real field set rather than a reduction of it.
    private func subagentStart(agentId: String) -> String {
        """
        {"session_id":"a31044a0-d307-4a2c-81e7-6cb3fa82d619","transcript_path":"/tmp/t.jsonl",\
        "cwd":"/tmp/repo","prompt_id":"0a226038-5dda-43ab-8006-2204dd46ab41",\
        "agent_id":"\(agentId)","agent_type":"general-purpose","hook_event_name":"SubagentStart"}
        """
    }

    private func subagentPreToolUse(agentId: String) -> String {
        """
        {"session_id":"a31044a0-d307-4a2c-81e7-6cb3fa82d619","transcript_path":"/tmp/t.jsonl",\
        "cwd":"/tmp/repo","prompt_id":"87ad6a86-c71a-45f0-8271-bd1c32f2beb3",\
        "permission_mode":"bypassPermissions","agent_id":"\(agentId)",\
        "agent_type":"general-purpose","hook_event_name":"PreToolUse","tool_name":"Bash",\
        "tool_input":{"command":"sleep 2 && /bin/ls -1 /tmp | wc -l","description":"Count /tmp"},\
        "tool_use_id":"toolu_01V9GTw1Lhdm3m6aE75diPCW"}
        """
    }

    /// A `nil` description omits the key rather than sending `null`, which is how an agent with no
    /// summary to report spells it, and what a second `Stop` must not blank the row with.
    private func stop(running: [(id: String, description: String?)]) -> String {
        let tasks = running.map { task in
            let description = task.description.map { #""description":"\#($0)","# } ?? ""
            return #"{"id":"\#(task.id)","type":"subagent","status":"running",\#(description)"agent_type":"general-purpose"}"#
        }
        return """
        {"session_id":"a31044a0-d307-4a2c-81e7-6cb3fa82d619","transcript_path":"/tmp/t.jsonl",\
        "cwd":"/tmp/repo","prompt_id":"0a226038-5dda-43ab-8006-2204dd46ab41",\
        "permission_mode":"bypassPermissions","effort":{"level":"high"},"hook_event_name":"Stop",\
        "stop_hook_active":false,"last_assistant_message":"Both subagents are running.",\
        "background_tasks":[\(tasks.joined(separator: ","))]}
        """
    }

    private func applyRaw(
        _ body: String,
        surface: String = surfaceA,
        owner: AgentActivityOwner = .worktree(worktreeOne)
    ) {
        guard let envelope = AgentHookEnvelope.parse(Data("\(surface)\n\(owner.rawValue)\n\(body)".utf8)) else {
            return XCTFail("the captured payload did not parse")
        }
        store.apply(envelope)
    }

    private func apply(
        _ event: String,
        surface: String = surfaceA,
        owner: AgentActivityOwner = .worktree(worktreeOne),
        tool: String? = nil,
        agentId: String? = nil,
        agentType: String? = nil
    ) {
        var fields = [#""hook_event_name":"\#(event)""#]
        if let tool { fields.append(#""tool_name":"\#(tool)""#) }
        if let agentId { fields.append(#""agent_id":"\#(agentId)""#) }
        if let agentType { fields.append(#""agent_type":"\#(agentType)""#) }
        let payload = Data("\(surface)\n\(owner.rawValue)\n{\(fields.joined(separator: ","))}".utf8)

        guard let envelope = AgentHookEnvelope.parse(payload) else {
            return XCTFail("the test helper built an unparseable \(event) payload")
        }
        store.apply(envelope)
    }
}
