import Foundation

/// The five fields Clearway reads out of an agent's hook payload. Both Claude Code and Codex spell
/// them identically, so nothing downstream needs to know which agent sent an event. Every other
/// field in the payload is ignored: the `CodingKeys` name only these five, and `Decodable` drops the
/// rest.
struct AgentHookEvent: Decodable, Equatable {
    let hookEventName: String
    let agentId: String?
    let agentType: String?
    let toolName: String?
    let backgroundTasks: [BackgroundTask]?

    /// One entry of `Stop`'s `background_tasks`: the work the agent left running when it finished
    /// its turn. `type` is documented as `"subagent"` today and `status` as `running`, `completed`
    /// or `failed`. `description` is the prompt's own summary — "Count Swift files slowly" — and is
    /// the only place any hook payload carries it; `SubagentStart` still does not.
    struct BackgroundTask: Decodable, Equatable {
        let id: String
        let type: String?
        let status: String?
        let agentType: String?
        let description: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case type
            case status
            case agentType = "agent_type"
            case description
        }
    }

    /// The subagents a `Stop` reports as still going. An agent that carries no such field — every
    /// event but `Stop`, and any agent that has no background work — reports none, which is what
    /// makes the absence of the field and an empty list the same answer. Translated here rather
    /// than by the caller, so the payload's own field names stop at this type.
    var runningBackgroundSubagents: [AgentSubagent] {
        (backgroundTasks ?? [])
            .filter { $0.type == "subagent" && $0.status == "running" }
            .map { AgentSubagent(id: $0.id, type: $0.agentType, description: $0.description) }
    }

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case toolName = "tool_name"
        case backgroundTasks = "background_tasks"
    }
}

/// Who a surface's agent activity belongs to. One tagged string on the wire so exactly one owner
/// is representable: a worktree names its path, a task names its id, and neither can be absent
/// while the other is set.
enum AgentActivityOwner: RawRepresentable, Equatable {
    case worktree(String)
    case task(UUID)

    var rawValue: String {
        switch self {
        case .worktree(let path): return "worktree:\(path)"
        case .task(let id): return "task:\(id.uuidString)"
        }
    }

    /// Split on the **first** colon only, so a worktree path containing one survives.
    init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":") else { return nil }
        let value = String(rawValue[rawValue.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch rawValue[rawValue.startIndex..<colon] {
        case "worktree": self = .worktree(value)
        case "task":
            guard let id = UUID(uuidString: value) else { return nil }
            self = .task(id)
        default: return nil
        }
    }
}

/// One hook invocation as it arrives on the socket: line 1 the surface id, line 2 the activity
/// owner, then the agent's raw JSON body to EOF. The forwarder neither escapes nor re-encodes the
/// body, so it arrives exactly as the agent wrote it.
struct AgentHookEnvelope: Equatable {
    let surfaceId: String
    let owner: AgentActivityOwner
    let event: AgentHookEvent

    /// Held rather than built per call: `parse` runs on every hook invocation, which is twice per
    /// tool call for the life of the app, and the decoder carries no per-call state.
    private static let decoder = JSONDecoder()

    /// Takes the two preamble lines off the front and decodes everything after them as one JSON
    /// object. The split is on the **first two** newlines only, never on every newline: a
    /// pretty-printed body is as valid as a compact one and must survive intact.
    static func parse(_ data: Data) -> AgentHookEnvelope? {
        guard let (surfaceId, afterSurface) = takeLine(data),
              let (ownerLine, body) = takeLine(afterSurface),
              !surfaceId.isEmpty,
              let owner = AgentActivityOwner(rawValue: ownerLine),
              let event = try? decoder.decode(AgentHookEvent.self, from: Data(body))
        else { return nil }
        return AgentHookEnvelope(surfaceId: surfaceId, owner: owner, event: event)
    }

    private static func takeLine(_ data: Data) -> (line: String, rest: Data.SubSequence)? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let line = String(data: data[data.startIndex..<newline], encoding: .utf8)
        else { return nil }
        return (line, data[data.index(after: newline)...])
    }
}
