import Foundation

/// A user-created task, persisted as JSON in `.wtpad/tasks/<id>.json`.
struct UserTask: Codable, Identifiable, Equatable {
    let id: Int
    var subject: String
    var isCompleted: Bool

    var statusSymbol: String {
        isCompleted ? "checkmark.circle.fill" : "circle"
    }
}
