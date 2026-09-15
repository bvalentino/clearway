import Foundation

// MARK: - Model

/// A saved, reusable action: either a shell line to run in a new terminal tab, or a prompt to hand
/// to a named agent. `text` carries whichever the `kind` calls for — a command is exactly one.
struct SavedCommand: Codable, Equatable, Identifiable {

    enum Kind: String, Codable, CaseIterable {
        case terminal
        case agent
    }

    let id: UUID
    var name: String
    var kind: Kind
    var text: String
    var agent: String
    var autoRun: Bool
}

extension SavedCommand {
    /// Decodes `kind` through its raw string so an unrecognized value costs one command its kind
    /// rather than taking the whole file down — the store loads an undecodable file as empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = Kind(rawValue: try container.decode(String.self, forKey: .kind)) ?? .terminal
        text = try container.decode(String.self, forKey: .text)
        agent = try container.decode(String.self, forKey: .agent)
        autoRun = try container.decode(Bool.self, forKey: .autoRun)
    }
}

// MARK: - Filter

enum CommandFilter: String, CaseIterable {
    case all
    case terminal
    case agent

    /// Drag reorder is refused while this is true: a move computed against a subset would rewrite
    /// the wrong global positions.
    var isActive: Bool { self != .all }
}

extension SavedCommand {
    static func filter(_ commands: [SavedCommand], by filter: CommandFilter) -> [SavedCommand] {
        switch filter {
        case .all:
            return commands
        case .terminal:
            return commands.filter { $0.kind == .terminal }
        case .agent:
            return commands.filter { $0.kind == .agent }
        }
    }
}

// MARK: - Launch

/// What running a `SavedCommand` amounts to, with the terminal work factored out so the rule is
/// testable on its own.
enum CommandLaunch: Equatable {
    case shell(text: String, execute: Bool)
    case agent(agent: String, prompt: String, submit: Bool)

    static func launch(for command: SavedCommand) -> CommandLaunch {
        switch command.kind {
        case .terminal:
            return .shell(text: command.text, execute: command.autoRun)
        case .agent:
            return .agent(agent: command.agent, prompt: command.text, submit: command.autoRun)
        }
    }
}
