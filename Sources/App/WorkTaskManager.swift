import Foundation

/// Manages tasks persisted as markdown files in `.clearway/tasks/`.
///
/// Unlike `TodoManager` (per-worktree), this is project-scoped — it always
/// reads/writes from the project root (main worktree path).
@MainActor
class WorkTaskManager: ObservableObject {
    @Published var tasks: [WorkTask] = []

    let projectPath: String
    let tasksDirectory: String
    private var watcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    init(projectPath: String) {
        self.projectPath = projectPath
        self.tasksDirectory = (projectPath as NSString).appendingPathComponent(".clearway/tasks")
        reload()
        watchDirectory()
    }

    nonisolated deinit {
        pendingReload?.cancel()
        watcherSource?.cancel()
    }

    // MARK: - Lookups

    func task(forWorktree branch: String) -> WorkTask? {
        tasks.first { $0.worktree == branch }
    }

    // MARK: - CRUD

    @discardableResult
    func createTask(title: String = "") -> WorkTask? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = WorkTask(title: trimmed)
        write(task)
        reload()
        return tasks.first { $0.id == task.id }
    }

    func updateTask(_ task: WorkTask) {
        var updated = task
        // Truncate to whole seconds so in-memory Date matches the ISO8601
        // round-trip through disk, preventing the watcher reload from seeing
        // a spurious difference and firing a redundant @Published update.
        updated.updatedAt = Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate))
        write(updated)
        // Update in-memory so callers see immediate changes without
        // waiting for the watcher reload.
        if let index = tasks.firstIndex(where: { $0.id == updated.id }) {
            tasks[index] = updated
        }
    }

    /// Parses raw frontmatter+body content and saves the task if valid.
    /// Returns true on success. Returns false (and does not save) if
    /// the YAML is unparseable or the parsed id doesn't match expectedId.
    func updateFromRawContent(_ content: String, expectedId: UUID) -> Bool {
        guard let parsed = WorkTask.parse(from: content), parsed.id == expectedId else {
            return false
        }
        updateTask(parsed)
        return true
    }

    func setStatus(_ task: WorkTask, to status: WorkTask.Status) {
        guard task.status != status else { return }
        var updated = task
        updated.status = status
        updateTask(updated)
    }

    func deleteTask(_ task: WorkTask) {
        try? FileManager.default.removeItem(atPath: filePath(for: task))
    }

    // MARK: - Branch Name Derivation

    /// Derives a git branch name from a task title.
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
            return "task-\(UUID().uuidString.prefix(8).lowercased())"
        }
        if !existingBranches.contains(capped) { return capped }
        return "\(capped)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    // MARK: - Persistence

    /// Returns the file path for a task's markdown file.
    func filePath(for task: WorkTask) -> String {
        (tasksDirectory as NSString).appendingPathComponent("\(task.id.uuidString).md")
    }

    private func write(_ task: WorkTask) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tasksDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = filePath(for: task)
        guard let data = task.serialized().data(using: .utf8) else { return }
        fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        if watcherSource == nil { watchDirectory() }
    }

    private func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: tasksDirectory) else {
            tasks = []
            return
        }

        var loaded: [WorkTask] = []
        for file in files where file.hasSuffix(".md") && UUID(uuidString: (file as NSString).deletingPathExtension) != nil {
            let path = (tasksDirectory as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let content = String(data: data, encoding: .utf8),
                  let task = WorkTask.parse(from: content) else { continue }
            loaded.append(task)
        }

        // Newest first
        let sorted = loaded.sorted { $0.createdAt > $1.createdAt }
        if sorted != tasks { tasks = sorted }
    }

    // MARK: - File Watching

    private func watchDirectory() {
        watcherSource?.cancel()
        watcherSource = nil

        guard FileManager.default.fileExists(atPath: tasksDirectory) else { return }

        let fd = open(tasksDirectory, O_EVTONLY)
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
