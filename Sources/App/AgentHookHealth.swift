import Foundation

/// What became of one agent's settings file during an install.
enum AgentHookFileOutcome: Equatable, Sendable {

    /// The agent's config directory is not there, which is how "this agent is not installed here"
    /// is spelled. On its own it is not a failure — see `AgentHookHealth.resolve`.
    case absent

    /// The managed block is in place, whether this call wrote it or found it already written.
    case installed

    /// Unreadable, not a JSON object, not re-serialisable, not backed up, or not written. `path` is
    /// home-relative (`~/.claude/settings.json`) so the message reads the same under a temp root as
    /// it does under a real home.
    case refused(path: String)
}

/// One enable attempt's install half, in the order the installer walks the agents.
struct AgentHookInstallReport: Equatable, Sendable {
    let scriptWritten: Bool
    let files: [AgentHookFileOutcome]
}

/// One enable attempt's socket half.
enum AgentHookSocketOutcome: Equatable, Sendable {
    case listening
    case ownedByAnotherInstance
    case unopenable
}

/// The last enable attempt's outcome, and the one line Settings displays for it. Pure: the
/// installer and the listener produce the inputs, and no rule lives in either.
enum AgentHookHealth: Equatable, Sendable {
    case off
    case listening
    case socketOwnedByAnotherInstance
    case socketUnopenable
    case scriptNotWritten
    case noAgentDirectory
    case settingsRefused(path: String)

    /// Most fatal first, exactly one case displayed. The socket outranks the install because it is
    /// the single channel: with it closed, a perfect install delivers nothing.
    static func resolve(install: AgentHookInstallReport, socket: AgentHookSocketOutcome) -> AgentHookHealth {
        switch socket {
        case .ownedByAnotherInstance: return .socketOwnedByAnotherInstance
        case .unopenable: return .socketUnopenable
        case .listening: break
        }

        guard install.scriptWritten else { return .scriptNotWritten }

        // Only a wholly absent set is a failure: a user who has Claude Code and not Codex would
        // otherwise carry a permanent warning about a tool they do not use.
        if !install.files.isEmpty, install.files.allSatisfy({ $0 == .absent }) { return .noAgentDirectory }

        for case .refused(let path) in install.files { return .settingsRefused(path: path) }
        return .listening
    }

    /// `nil` where there is nothing to say. A "Listening" confirmation would only restate the
    /// toggle.
    var message: String? {
        switch self {
        case .off, .listening:
            return nil
        case .socketOwnedByAnotherInstance:
            return "Another Clearway instance is using the hook socket."
        case .socketUnopenable:
            return "The hook socket at ~/.clearway/hook.sock could not be opened."
        case .scriptNotWritten:
            return "The hook script could not be written to ~/.clearway/hooks."
        case .noAgentDirectory:
            return "No ~/.claude or ~/.codex directory was found, so no hooks were installed."
        case .settingsRefused(let path):
            return "\(path) could not be updated."
        }
    }
}
