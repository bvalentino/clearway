import Foundation

/// Manages tickets persisted as markdown files in `.wtpad/tickets/`.
///
/// Unlike `UserTaskManager` (per-worktree), this is project-scoped — it always
/// reads/writes from the project root (main worktree path).
@MainActor
class TicketManager: ObservableObject {
    @Published var tickets: [Ticket] = []

    let projectPath: String
    let ticketsDirectory: String
    private var watcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    init(projectPath: String) {
        self.projectPath = projectPath
        self.ticketsDirectory = (projectPath as NSString).appendingPathComponent(".wtpad/tickets")
        reload()
        watchDirectory()
    }

    nonisolated deinit {
        pendingReload?.cancel()
        watcherSource?.cancel()
    }

    // MARK: - Lookups

    func ticket(forWorktree branch: String) -> Ticket? {
        tickets.first { $0.worktree == branch }
    }

    // MARK: - CRUD

    @discardableResult
    func createTicket(title: String) -> Ticket? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ticket = Ticket(title: trimmed)
        write(ticket)
        reload()
        return tickets.first { $0.id == ticket.id }
    }

    func updateTicket(_ ticket: Ticket) {
        var updated = ticket
        updated.updatedAt = Date()
        write(updated)
    }

    func setStatus(_ ticket: Ticket, to status: Ticket.Status) {
        guard ticket.status != status else { return }
        var updated = ticket
        updated.status = status
        updateTicket(updated)
    }

    func deleteTicket(_ ticket: Ticket) {
        try? FileManager.default.removeItem(atPath: filePath(for: ticket))
    }

    // MARK: - Branch Name Derivation

    /// Derives a git branch name from a ticket title.
    /// Slugifies: lowercase, replace non-alphanumeric with `-`, collapse/trim dashes, cap at 50 chars.
    /// Appends a short UUID suffix on collision.
    private static let branchSlugCharacters = CharacterSet.lowercaseLetters.union(.decimalDigits)

    func deriveBranchName(from title: String, existingBranches: Set<String>) -> String {
        let allowed = Self.branchSlugCharacters
        let mapped = title.lowercased().unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }
        let slug = mapped.joined()
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let capped = String(slug.prefix(50))
        if capped.isEmpty {
            return "ticket-\(UUID().uuidString.prefix(8).lowercased())"
        }
        if !existingBranches.contains(capped) { return capped }
        return "\(capped)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    // MARK: - Persistence

    /// Returns the file path for a ticket's markdown file.
    func filePath(for ticket: Ticket) -> String {
        (ticketsDirectory as NSString).appendingPathComponent("\(ticket.id.uuidString).md")
    }

    private func write(_ ticket: Ticket) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: ticketsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = filePath(for: ticket)
        guard let data = ticket.serialized().data(using: .utf8) else { return }
        fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        if watcherSource == nil { watchDirectory() }
    }

    private func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: ticketsDirectory) else {
            tickets = []
            return
        }

        var loaded: [Ticket] = []
        for file in files where file.hasSuffix(".md") && UUID(uuidString: (file as NSString).deletingPathExtension) != nil {
            let path = (ticketsDirectory as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let content = String(data: data, encoding: .utf8),
                  let ticket = Ticket.parse(from: content) else { continue }
            loaded.append(ticket)
        }

        // Newest first
        let sorted = loaded.sorted { $0.createdAt > $1.createdAt }
        if sorted != tickets { tickets = sorted }
    }

    // MARK: - File Watching

    private func watchDirectory() {
        watcherSource?.cancel()
        watcherSource = nil

        guard FileManager.default.fileExists(atPath: ticketsDirectory) else { return }

        let fd = open(ticketsDirectory, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcherSource = source
    }

    private nonisolated func scheduleReload() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.reload()
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
}
