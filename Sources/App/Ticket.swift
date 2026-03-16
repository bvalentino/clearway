import Foundation

/// A ticket — a unit of work persisted as a markdown file with YAML frontmatter
/// in `.wtpad/tickets/<id>.md`.
struct Ticket: Identifiable, Equatable, Hashable {
    let id: UUID
    var title: String
    var status: Status
    var worktree: String?
    var createdAt: Date
    var updatedAt: Date
    var body: String

    enum Status: String, CaseIterable {
        case open
        case running
        case done
        case stopped

        var label: String {
            switch self {
            case .open: return "Open"
            case .running: return "Running"
            case .done: return "Done"
            case .stopped: return "Stopped"
            }
        }
    }

    init(id: UUID = UUID(), title: String, status: Status = .open, worktree: String? = nil, body: String = "") {
        self.id = id
        self.title = title
        self.status = status
        self.worktree = worktree
        self.createdAt = Date()
        self.updatedAt = Date()
        self.body = body
    }

    // MARK: - Serialization

    /// Serializes the ticket to YAML frontmatter + markdown body.
    func serialized() -> String {
        var lines = ["---"]
        lines.append("id: \(id.uuidString)")
        lines.append("title: \(title.replacingOccurrences(of: "\n", with: " "))")
        lines.append("status: \(status.rawValue)")
        lines.append("worktree: \(worktree?.replacingOccurrences(of: "\n", with: "") ?? "null")")
        lines.append("created_at: \(Self.dateFormatter.string(from: createdAt))")
        lines.append("updated_at: \(Self.dateFormatter.string(from: updatedAt))")
        lines.append("---")
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Parses a ticket from YAML frontmatter + markdown body.
    /// Returns nil if the frontmatter is missing required fields.
    static func parse(from content: String) -> Ticket? {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }

        // Find closing ---
        var endIndex: Int?
        for i in 1..<lines.count {
            if lines[i] == "---" {
                endIndex = i
                break
            }
        }
        guard let closingIndex = endIndex else { return nil }

        // Parse frontmatter key-value pairs
        var fields: [String: String] = [:]
        for i in 1..<closingIndex {
            let line = lines[i]
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        // Required fields
        guard let idString = fields["id"],
              let id = UUID(uuidString: idString),
              let title = fields["title"], !title.isEmpty,
              let statusString = fields["status"],
              let status = Status(rawValue: statusString) else { return nil }

        let worktree: String? = {
            guard let value = fields["worktree"], value != "null" else { return nil }
            return value
        }()

        let createdAt = fields["created_at"].flatMap { dateFormatter.date(from: $0) } ?? Date()
        let updatedAt = fields["updated_at"].flatMap { dateFormatter.date(from: $0) } ?? Date()

        // Body is everything after the closing --- (skip one blank line if present)
        var bodyStartIndex = closingIndex + 1
        if bodyStartIndex < lines.count && lines[bodyStartIndex].isEmpty {
            bodyStartIndex += 1
        }
        let body: String
        if bodyStartIndex < lines.count {
            body = lines[bodyStartIndex...].joined(separator: "\n")
        } else {
            body = ""
        }

        var ticket = Ticket(id: id, title: title, status: status, worktree: worktree, body: body)
        ticket.createdAt = createdAt
        ticket.updatedAt = updatedAt
        return ticket
    }

    // MARK: - Date Formatting

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
