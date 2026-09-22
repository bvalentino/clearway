import Foundation

/// Ordered so a worktree's dot is `max` over its surfaces rather than nested conditionals. Waiting
/// outranks working because it is the state that needs the user.
enum AgentPhase: Int, Comparable {
    case idle
    case working
    case waiting

    static func < (lhs: AgentPhase, rhs: AgentPhase) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct AgentSubagent: Identifiable, Equatable {
    let id: String
    var type: String?
    var description: String?
}

struct AgentSurfaceState {
    var owner: AgentActivityOwner
    var phase: AgentPhase = .idle
    var leadToolName: String?
    var subagents: [String: AgentSubagent] = [:]

    /// A live subagent is work even while the lead sits between turns, so the roster lifts an idle
    /// surface to working before the worktree rule ever sees it.
    fileprivate var effectivePhase: AgentPhase {
        subagents.isEmpty ? phase : Swift.max(phase, .working)
    }

    /// The phase and the tool are both the lead's, and only the lead's: a subagent's own tool
    /// traffic must never touch the label a tab chip reads, and it must not write the phase either.
    /// `effectivePhase` already lifts the surface to working for as long as that subagent holds a
    /// row, so a write here would outlive the row that justified it — a background subagent runs on
    /// past the lead's `Stop`, so its `PreToolUse` would pin an idle lead at working and its
    /// `SubagentStop` would then take the roster away and leave the dot lit with nothing running
    /// and no event left to clear it. It still upserts the row, because a `PreToolUse` whose
    /// `SubagentStart` was missed names a real subagent, and every event carrying an `agent_id`
    /// carries its `agent_type` beside it.
    fileprivate mutating func startTool(
        _ toolName: String?,
        agentId: String?,
        agentType: String?,
        phase newPhase: AgentPhase
    ) {
        guard let agentId else {
            phase = newPhase
            leadToolName = toolName
            return
        }
        note(agentId: agentId, type: agentType)
    }

    /// A type the event did not carry never overwrites one already known: only `Stop`'s roster
    /// carries every live subagent's type, and the tool events carry it only for their own.
    fileprivate mutating func note(agentId: String, type: String?) {
        var subagent = subagents[agentId] ?? AgentSubagent(id: agentId)
        subagent.type = type ?? subagent.type
        subagents[agentId] = subagent
    }

    /// `Stop` fires while background subagents are still running and names the ones that are, so the
    /// roster is reduced to that list rather than emptied. Reducing keeps the sweep a blind
    /// `removeAll` was there for — a missed `SubagentStop` still cannot pin a row — while a `Stop`
    /// that names none clears the roster exactly as before. The type and the description carry over
    /// from the row already held when this payload omits them, for the same reason `note` keeps a
    /// known type: a later `Stop` must not blank what an earlier one named.
    fileprivate mutating func keepOnly(_ running: [AgentSubagent]) {
        subagents = running.reduce(into: [:]) { roster, subagent in
            let known = subagents[subagent.id]
            roster[subagent.id] = AgentSubagent(
                id: subagent.id,
                type: subagent.type ?? known?.type,
                description: subagent.description ?? known?.description
            )
        }
    }

    /// Returns the lead to working and clears its tool, and only the lead's: a subagent finishing
    /// must move neither while the lead is still running — nor while it is waiting on a permission
    /// prompt, which is the one state that needs the user. It creates nothing, so a `PostToolUse`
    /// for a subagent already gone leaves no empty row behind.
    fileprivate mutating func finishTool(agentId: String?) {
        guard agentId == nil else { return }
        phase = .working
        leadToolName = nil
    }
}

/// The rule the socket listener is a shell around: hook events in, per-worktree phases and subagent
/// rosters out. No I/O, no actor, no clock — a surface leaves a state only because an event said so,
/// so nothing here expires.
struct AgentActivityStore {
    private var surfaces: [String: AgentSurfaceState] = [:]
    /// A surface Clearway has torn down. Its id is remembered rather than merely dropped, because a
    /// hook process already in flight when the tab closed would otherwise re-create the entry.
    private var retiredSurfaceIds: Set<String> = []

    mutating func apply(_ envelope: AgentHookEnvelope) {
        guard !retiredSurfaceIds.contains(envelope.surfaceId) else { return }
        let event = envelope.event

        switch event.hookEventName {
        case "SessionStart":
            surfaces[envelope.surfaceId] = AgentSurfaceState(owner: envelope.owner)
        case "SessionEnd":
            surfaces.removeValue(forKey: envelope.surfaceId)
        case "UserPromptSubmit":
            update(envelope) { state in
                state.phase = .working
                state.leadToolName = nil
            }
        case "PreToolUse":
            update(envelope) { state in
                state.startTool(
                    event.toolName,
                    agentId: event.agentId,
                    agentType: event.agentType,
                    phase: .working
                )
            }
        case "PermissionRequest":
            update(envelope) { state in
                state.startTool(
                    event.toolName,
                    agentId: event.agentId,
                    agentType: event.agentType,
                    phase: .waiting
                )
            }
        case "PostToolUse":
            update(envelope) { state in
                state.finishTool(agentId: event.agentId)
            }
        case "SubagentStart":
            guard let agentId = event.agentId else { return }
            update(envelope) { state in
                state.note(agentId: agentId, type: event.agentType)
            }
        case "SubagentStop":
            guard let agentId = event.agentId else { return }
            update(envelope) { state in
                state.subagents.removeValue(forKey: agentId)
            }
        case "Stop":
            update(envelope) { state in
                state.phase = .idle
                state.leadToolName = nil
                state.keepOnly(event.runningBackgroundSubagents)
            }
        default:
            break
        }
    }

    mutating func retire(surfaceId: String) {
        retiredSurfaceIds.insert(surfaceId)
        surfaces.removeValue(forKey: surfaceId)
    }

    /// The three derivations the monitor publishes whole, so the views read a dictionary rather
    /// than asking the store once per row. `surfaceToolNames` below is not among them — it goes to
    /// `AgentActivityMonitor.ToolNames`, which only the tab chip observes.
    var worktreePhases: [String: AgentPhase] {
        surfaces.values.reduce(into: [:]) { phases, state in
            guard case .worktree(let id) = state.owner else { return }
            phases[id] = Swift.max(phases[id] ?? .idle, state.effectivePhase)
        }
    }

    /// A task's own phase, keyed by the task id its terminal was stamped with. A task surface
    /// contributes here and to nothing else; a worktree surface the reverse.
    var taskPhases: [UUID: AgentPhase] {
        surfaces.values.reduce(into: [:]) { phases, state in
            guard case .task(let id) = state.owner else { return }
            phases[id] = Swift.max(phases[id] ?? .idle, state.effectivePhase)
        }
    }

    /// Only a surface that has a roster contributes a key, so a worktree with no live subagent is
    /// absent rather than mapped to `[]` — an empty entry would make every surface open republish.
    var worktreeSubagents: [String: [AgentSubagent]] {
        var rosters: [String: [AgentSubagent]] = [:]
        for state in surfaces.values where !state.subagents.isEmpty {
            guard case .worktree(let id) = state.owner else { continue }
            rosters[id, default: []].append(contentsOf: state.subagents.values)
        }
        return rosters.mapValues { $0.sorted { $0.id < $1.id } }
    }

    var surfaceToolNames: [String: String] {
        surfaces.compactMapValues { $0.leadToolName }
    }

    private mutating func update(
        _ envelope: AgentHookEnvelope,
        _ change: (inout AgentSurfaceState) -> Void
    ) {
        var state = surfaces[envelope.surfaceId] ?? AgentSurfaceState(owner: envelope.owner)
        state.owner = envelope.owner
        change(&state)
        surfaces[envelope.surfaceId] = state
    }
}
