import Foundation

/// A task created by Claude Code, parsed from `~/.claude/tasks/<session>/<id>.json`.
struct ClaudeTask: Codable, Identifiable {
    let id: String
    let subject: String
    let description: String
    var status: Status
    let blocks: [String]
    let blockedBy: [String]

    enum Status: String, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    var statusSymbol: String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .inProgress: return "circle.dotted.circle"
        case .pending: return "circle"
        }
    }
}

/// A group of tasks from a single Claude Code session.
struct ClaudeSession: Codable, Identifiable {
    let id: String // session UUID
    let tasks: [ClaudeTask]
    let modificationDate: Date
}
