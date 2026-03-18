import Foundation
import SwiftUI

/// A todo created by Claude Code, parsed from `~/.claude/tasks/<session>/<id>.json`.
struct ClaudeTodo: Codable, Identifiable {
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

        var symbol: String {
            switch self {
            case .pending: return "circle"
            case .inProgress: return "circle.dotted.circle"
            case .completed: return "checkmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .completed: return .green
            case .inProgress: return .orange
            case .pending: return .secondary
            }
        }
    }
}

/// A group of todos from a single Claude Code session.
struct ClaudeSession: Codable, Identifiable {
    let id: String // session UUID
    let todos: [ClaudeTodo]
    let modificationDate: Date
}
