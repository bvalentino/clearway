import XCTest
@testable import Clearway

/// Pins the wire contract between `clearway-hook.sh` and the socket listener: two newline-terminated
/// preamble lines carrying the surface id and the worktree id, then the agent's raw JSON body to
/// EOF. The body is never re-encoded by the forwarder, so it arrives exactly as the agent wrote it —
/// pretty-printed on one agent, compact on another — and the split must therefore be on the first
/// two lines only.
final class AgentHookEnvelopeTests: XCTestCase {

    private let surfaceId = "8F1D4C0A-5B2E-4A77-9C31-6E0F2A8D1B44"
    private let worktreeId = "/Users/x/my repo/.worktrees/a b"

    private func payload(_ body: String) -> Data {
        Data("\(surfaceId)\n\(worktreeId)\n\(body)".utf8)
    }

    // MARK: - The happy path

    func testParsesBothIdsAndTheEvent() {
        let envelope = AgentHookEnvelope.parse(
            payload(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#)
        )

        XCTAssertEqual(envelope?.surfaceId, surfaceId)
        XCTAssertEqual(envelope?.worktreeId, worktreeId)
        XCTAssertEqual(envelope?.event.hookEventName, "PreToolUse")
        XCTAssertEqual(envelope?.event.toolName, "Bash")
    }

    /// A worktree id is a filesystem path and paths carry spaces. Nothing quotes or escapes the
    /// preamble, so the line is taken whole.
    func testWorktreeIdKeepsItsSpaces() {
        let envelope = AgentHookEnvelope.parse(payload(#"{"hook_event_name":"Stop"}"#))
        XCTAssertEqual(envelope?.worktreeId, "/Users/x/my repo/.worktrees/a b")
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
        XCTAssertNil(AgentHookEnvelope.parse(Data("\n\(worktreeId)\n{\"hook_event_name\":\"Stop\"}".utf8)))
    }

    func testEmptyWorktreeIdParsesToNil() {
        XCTAssertNil(AgentHookEnvelope.parse(Data("\(surfaceId)\n\n{\"hook_event_name\":\"Stop\"}".utf8)))
    }
}
