import Foundation

/// A user-created task, persisted as JSON in `.wtpad/tasks/<id>.json`.
struct UserTask: Codable, Identifiable, Equatable {
    let id: String
    var subject: String
    var isCompleted: Bool
    let createdAt: Date
    var updatedAt: Date

    init(subject: String) {
        self.id = UUID().uuidString
        self.subject = subject
        self.isCompleted = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var statusSymbol: String {
        isCompleted ? "checkmark.circle.fill" : "circle"
    }
}
