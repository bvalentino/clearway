import Foundation

/// The four fields Clearway reads out of an agent's hook payload. Both Claude Code and Codex spell
/// them identically, so nothing downstream needs to know which agent sent an event. Every other
/// field in the payload is ignored: the `CodingKeys` name only these four, and `Decodable` drops the
/// rest.
struct AgentHookEvent: Decodable, Equatable {
    let hookEventName: String
    let agentId: String?
    let agentType: String?
    let toolName: String?

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case toolName = "tool_name"
    }
}

/// One hook invocation as it arrives on the socket: line 1 the surface id, line 2 the worktree id,
/// then the agent's raw JSON body to EOF. The forwarder neither escapes nor re-encodes the body, so
/// it arrives exactly as the agent wrote it.
struct AgentHookEnvelope: Equatable {
    let surfaceId: String
    let worktreeId: String
    let event: AgentHookEvent

    /// Takes the two preamble lines off the front and decodes everything after them as one JSON
    /// object. The split is on the **first two** newlines only, never on every newline: a
    /// pretty-printed body is as valid as a compact one and must survive intact.
    static func parse(_ data: Data) -> AgentHookEnvelope? {
        guard let (surfaceId, afterSurface) = takeLine(data),
              let (worktreeId, body) = takeLine(afterSurface),
              !surfaceId.isEmpty, !worktreeId.isEmpty,
              let event = try? JSONDecoder().decode(AgentHookEvent.self, from: Data(body))
        else { return nil }
        return AgentHookEnvelope(surfaceId: surfaceId, worktreeId: worktreeId, event: event)
    }

    private static func takeLine(_ data: Data) -> (line: String, rest: Data.SubSequence)? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let line = String(data: data[data.startIndex..<newline], encoding: .utf8)
        else { return nil }
        return (line, data[data.index(after: newline)...])
    }
}
