import Foundation
import SwiftUI

/// A user-created task, persisted as JSON in `.wtpad/tasks/<id>.json`.
struct UserTask: Codable, Identifiable, Equatable {
    let id: Int
    var subject: String
    var status: Status
    var statusChangedAt: Date

    enum Status: String, Codable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case completed

        var label: String {
            switch self {
            case .pending: return "Pending"
            case .inProgress: return "In Progress"
            case .completed: return "Completed"
            }
        }

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

    /// Cycles pending → inProgress → completed → pending.
    var nextStatus: Status {
        switch status {
        case .pending: return .inProgress
        case .inProgress: return .completed
        case .completed: return .pending
        }
    }

    init(id: Int, subject: String, status: Status = .pending) {
        self.id = id
        self.subject = subject
        self.status = status
        self.statusChangedAt = Date()
    }
}
