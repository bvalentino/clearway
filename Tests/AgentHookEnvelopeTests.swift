import XCTest
@testable import Clearway

/// Pins the wire contract between `clearway-hook.sh` and the socket listener: two newline-terminated
/// preamble lines carrying the surface id and the tagged activity owner, then the agent's raw JSON
/// body to EOF. The body is never re-encoded by the forwarder, so it arrives exactly as the agent wrote it —
/// pretty-printed on one agent, compact on another — and the split must therefore be on the first
/// two lines only.
final class AgentHookEnvelopeTests: XCTestCase {

    private let surfaceId = "8F1D4C0A-5B2E-4A77-9C31-6E0F2A8D1B44"
    private let worktreePath = "/Users/x/my repo/.worktrees/a b"

    private func payload(_ body: String, owner: String? = nil) -> Data {
        let owner = owner ?? AgentActivityOwner.worktree(worktreePath).rawValue
        return Data("\(surfaceId)\n\(owner)\n\(body)".utf8)
    }

    // MARK: - The happy path

    func testParsesTheSurfaceIdTheOwnerAndTheEvent() {
        let envelope = AgentHookEnvelope.parse(
            payload(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#)
        )

        XCTAssertEqual(envelope?.surfaceId, surfaceId)
        XCTAssertEqual(envelope?.owner, .worktree(worktreePath))
        XCTAssertEqual(envelope?.event.hookEventName, "PreToolUse")
        XCTAssertEqual(envelope?.event.toolName, "Bash")
    }

    /// A worktree owner names a filesystem path, and paths carry spaces — and colons. Nothing
    /// quotes or escapes the preamble, and only the leading tag is split off, so everything after
    /// the first colon is taken whole.
    func testAWorktreePathKeepsItsSpacesAndItsOwnColon() {
        let path = "/Users/x/my repo/.worktrees/a:b"
        let envelope = AgentHookEnvelope.parse(
            payload(#"{"hook_event_name":"Stop"}"#, owner: AgentActivityOwner.worktree(path).rawValue)
        )
        XCTAssertEqual(envelope?.owner, .worktree(path))
    }

    /// A task terminal names its task rather than the path it runs in, which is what keeps its
    /// agent off the main worktree's dot.
    func testATaskOwnerRoundTripsToItsId() {
        let id = UUID()
        let envelope = AgentHookEnvelope.parse(
            payload(#"{"hook_event_name":"Stop"}"#, owner: AgentActivityOwner.task(id).rawValue)
        )
        XCTAssertEqual(envelope?.owner, .task(id))
    }

    /// The discriminating case: splitting the whole payload on every newline would leave the body a
    /// lone `{`. Only the first two lines are preamble.
    func testPrettyPrintedBodyParsesIdenticallyToItsCompactForm() {
        let compact = AgentHookEnvelope.parse(
            payload(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#)
        )
        let pretty = AgentHookEnvelope.parse(payload("""
        {
          "hook_event_name": "PreToolUse",
          "tool_name": "Bash"
        }
        """))

        XCTAssertNotNil(pretty)
        XCTAssertEqual(pretty, compact)
    }

    /// Both agents send far more than the four fields Clearway reads. Everything else is dropped
    /// rather than rejected.
    func testUnknownFieldsAreIgnored() {
        let envelope = AgentHookEnvelope.parse(payload("""
        {
          "session_id": "abc",
          "cwd": "/Users/x/my repo",
          "transcript_path": "/tmp/t.jsonl",
          "hook_event_name": "PostToolUse",
          "tool_name": "Edit",
          "tool_input": {"file_path": "/tmp/a.swift"},
          "permission_mode": "acceptEdits",
          "turn_id": "t-7",
          "last_assistant_message": "done"
        }
        """))

        XCTAssertEqual(envelope?.event.hookEventName, "PostToolUse")
        XCTAssertEqual(envelope?.event.toolName, "Edit")
        XCTAssertNil(envelope?.event.agentId)
        XCTAssertNil(envelope?.event.agentType)
    }

    // MARK: - Optional fields

    func testSubagentFieldsAreNilWhenAbsent() {
        let envelope = AgentHookEnvelope.parse(payload(#"{"hook_event_name":"UserPromptSubmit"}"#))

        XCTAssertEqual(envelope?.event.hookEventName, "UserPromptSubmit")
        XCTAssertNil(envelope?.event.agentId)
        XCTAssertNil(envelope?.event.agentType)
        XCTAssertNil(envelope?.event.toolName)
    }

    func testSubagentFieldsArePopulatedWhenPresent() {
        let envelope = AgentHookEnvelope.parse(
            payload(#"{"hook_event_name":"SubagentStart","agent_id":"sub-1","agent_type":"Explore"}"#)
        )

        XCTAssertEqual(envelope?.event.hookEventName, "SubagentStart")
        XCTAssertEqual(envelope?.event.agentId, "sub-1")
        XCTAssertEqual(envelope?.event.agentType, "Explore")
        XCTAssertNil(envelope?.event.toolName)
    }

    /// `keepOnly` is the sweep that stops a missed `SubagentStop` pinning a row, and it trusts this
    /// filter to be the whole of "still going". Both predicates matter: a finished task or a
    /// background task that is not a subagent would each come back as a row nothing can remove.
    func testOnlyRunningSubagentsCountAsBackgroundWork() {
        let envelope = AgentHookEnvelope.parse(payload(#"""
        {"hook_event_name":"Stop","background_tasks":[
        {"id":"one","type":"subagent","status":"running","agent_type":"Explore","description":"Still going"},
        {"id":"two","type":"subagent","status":"completed","agent_type":"Explore"},
        {"id":"three","type":"subagent","status":"failed","agent_type":"Explore"},
        {"id":"four","type":"shell","status":"running"}]}
        """#))

        XCTAssertEqual(envelope?.event.runningBackgroundSubagents.map(\.id), ["one"])
        XCTAssertEqual(envelope?.event.runningBackgroundSubagents.first?.description, "Still going")
    }

    /// Absence and an empty list are the same answer, which is what lets every event but `Stop` go
    /// through `keepOnly` untouched.
    func testAnEventWithNoBackgroundTasksReportsNoneRunning() {
        let envelope = AgentHookEnvelope.parse(payload(#"{"hook_event_name":"Stop"}"#))

        XCTAssertEqual(envelope?.event.runningBackgroundSubagents.count, 0)
    }

    // MARK: - Refusals

    func testEmptyDataParsesToNil() {
        XCTAssertNil(AgentHookEnvelope.parse(Data()))
    }

    func testOneLineAndNoBodyParsesToNil() {
        XCTAssertNil(AgentHookEnvelope.parse(Data("\(surfaceId)\n".utf8)))
    }

    func testTwoLinesAndAnEmptyBodyParsesToNil() {
        XCTAssertNil(AgentHookEnvelope.parse(payload("")))
    }

    func testNonJSONBodyParsesToNil() {
        XCTAssertNil(AgentHookEnvelope.parse(payload("nc: unix connect failed")))
    }

    /// A hook payload is an object. An array decodes as JSON but carries none of the fields, so it
    /// is refused rather than read as an event with everything missing.
    func testJSONArrayBodyParsesToNil() {
        XCTAssertNil(AgentHookEnvelope.parse(payload(#"["hook_event_name","PreToolUse"]"#)))
    }

    func testBodyWithoutHookEventNameParsesToNil() {
        XCTAssertNil(AgentHookEnvelope.parse(payload(#"{"tool_name":"Bash","cwd":"/tmp"}"#)))
    }

    func testEmptySurfaceIdParsesToNil() {
        let owner = AgentActivityOwner.worktree(worktreePath).rawValue
        XCTAssertNil(AgentHookEnvelope.parse(Data("\n\(owner)\n{\"hook_event_name\":\"Stop\"}".utf8)))
    }

    func testEmptyOwnerParsesToNil() {
        XCTAssertNil(AgentHookEnvelope.parse(payload(#"{"hook_event_name":"Stop"}"#, owner: "")))
    }

    /// The shape a forwarder from before the rename sends: a bare path with no tag. It is refused
    /// rather than read as a worktree, which is what makes "exactly one owner" the only parseable
    /// state.
    func testAnUntaggedOwnerParsesToNil() {
        XCTAssertNil(
            AgentHookEnvelope.parse(payload(#"{"hook_event_name":"Stop"}"#, owner: worktreePath))
        )
    }

    func testAnUnknownOwnerTagParsesToNil() {
        XCTAssertNil(
            AgentHookEnvelope.parse(payload(#"{"hook_event_name":"Stop"}"#, owner: "branch:main"))
        )
    }

    func testATaskOwnerThatIsNotAUUIDParsesToNil() {
        XCTAssertNil(
            AgentHookEnvelope.parse(payload(#"{"hook_event_name":"Stop"}"#, owner: "task:not-a-uuid"))
        )
    }

    func testAnOwnerTagWithNoValueParsesToNil() {
        XCTAssertNil(
            AgentHookEnvelope.parse(payload(#"{"hook_event_name":"Stop"}"#, owner: "worktree:"))
        )
    }
}
