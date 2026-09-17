import Foundation

// MARK: - Model

/// A saved, reusable action: either a command to run in a new terminal tab, or a prompt to hand to
/// a named agent. `text` carries whichever the `kind` calls for.
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
    case shell(ShellSend)
    case agent(agent: String, prompt: String, submit: Bool)

    static func launch(for command: SavedCommand) -> CommandLaunch {
        switch command.kind {
        case .terminal:
            return .shell(ShellSend(text: command.text, runsLastLine: command.autoRun))
        case .agent:
            return .agent(agent: command.agent, prompt: command.text, submit: command.autoRun)
        }
    }
}

/// A terminal command reduced to what the surface is handed: one line per paste, Enter between the
/// lines, and a trailing Enter after the last one only when "Append Enter to run immediately" is on.
///
/// Every embedded newline is therefore an Enter, so the lines run in order in the user's own shell,
/// and the toggle governs the last line alone. Sending the block as one paste would not do that:
/// under bracketed paste the whole thing lands staged on a single prompt.
struct ShellSend: Equatable {

    /// One thing the surface is handed, in order.
    enum Step: Equatable {
        case text(String)
        case enter
    }

    let lines: [String]
    let runsLastLine: Bool

    /// `\r\n` and a bare `\r` normalise to `\n` so neither arrives as a second Enter, and the
    /// surrounding whitespace goes with them — a trailing newline the text editor left behind would
    /// otherwise stage an empty line instead of the last real one. Empty text yields no lines, which
    /// leaves `steps` empty and sends nothing.
    init(text: String, runsLastLine: Bool) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lines = normalized.isEmpty ? [] : normalized.components(separatedBy: "\n")
        self.runsLastLine = runsLastLine
    }

    /// Enter after every line but the last, and after the last one only when `runsLastLine` — the
    /// whole of what "Append Enter to run immediately" governs. Lives here rather than on the
    /// surface so it is reachable from a test.
    var steps: [Step] {
        guard let last = lines.last else { return [] }
        var steps = lines.dropLast().flatMap { [Step.text($0), .enter] }
        steps.append(.text(last))
        if runsLastLine { steps.append(.enter) }
        return steps
    }
}
