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

    /// Maps worktree branch → linked task title. Hidden (placeholder) tasks and tasks with
    /// empty titles are excluded — the sidebar falls back to the branch name in either case,
    /// instead of rendering a blank primary label with the branch pushed to a subtitle.
    var titlesByBranch: [String: String] {
        Dictionary(
            tasks.compactMap { t in
                guard !t.hidden, !t.title.isEmpty, let branch = t.worktree else { return nil }
                return (branch, t.title)
            },
            uniquingKeysWith: { first, _ in first }
        )
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

    /// Creates a hidden shadow task linked to `branch` so the worktree has state tracking
    /// without cluttering Planning. Idempotent: returns the existing task if one already
    /// links that branch (so task-initiated worktrees, which create their task first, aren't
    /// shadowed a second time). Default status is `.inProgress` — `.new` / `.readyToStart`
    /// are reserved for Planning (pre-worktree) and excluded from the aside picker.
    @discardableResult
    func createShadowTask(forBranch branch: String) -> WorkTask? {
        if let existing = task(forWorktree: branch) { return existing }
        // Title is intentionally empty — the user fills it in when they expose the task
        // via the aside's Create Task button (which opens the editor window).
        var shadow = WorkTask(title: "", status: .inProgress, worktree: branch)
        shadow.hidden = true
        write(shadow)
        reload()
        return tasks.first { $0.id == shadow.id }
    }

    /// Flips a hidden task to visible and persists. No-op when already exposed.
    @discardableResult
    func expose(_ task: WorkTask) -> WorkTask {
        guard task.hidden else { return task }
        var updated = task
        updated.hidden = false
        updateTask(updated)
        return updated
    }

    /// Creates an exposed task linked to `branch` — used by the aside CTA when a worktree
    /// has no linked task at all (e.g. pre-change worktrees).
    @discardableResult
    func createExposedTask(forBranch branch: String) -> WorkTask? {
        if let existing = task(forWorktree: branch) {
            return existing.hidden ? expose(existing) : existing
        }
        // Same defaults as shadow tasks: in-progress, empty title (the editor fills it in).
        let task = WorkTask(title: "", status: .inProgress, worktree: branch)
        write(task)
        reload()
        return tasks.first { $0.id == task.id }
    }

    func updateTask(_ task: WorkTask) {
        write(task)
        // Update in-memory so callers see immediate changes without
        // waiting for the watcher reload.
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        }
    }

    /// Applies an editor buffer's parsed form to the persisted task. System-managed fields
    /// (`worktree`, `status`, `attempt`, token counts, timestamps) are owned by
    /// `WorkTaskCoordinator` and state commands — editor buffers never overwrite them, which
    /// is what prevents a stale buffer from clobbering a concurrent coordinator write.
    /// Returns `false` if the buffer has unparseable frontmatter.
    @discardableResult
    func applyEditorBuffer(_ content: String, expectedId: UUID) -> Bool {
        let existing = tasks.first { $0.id == expectedId }
        guard let parsed = WorkTask.parse(
            from: content,
            id: expectedId,
            createdAt: existing?.createdAt ?? Date()
        ) else {
            return false
        }
        if var merged = existing {
            merged.title = parsed.title
            merged.body = parsed.body
            updateTask(merged)
        } else {
            updateTask(parsed)
        }
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
        for file in files where file.hasSuffix(".md") {
            guard let id = UUID(uuidString: (file as NSString).deletingPathExtension) else { continue }
            let path = (tasksDirectory as NSString).appendingPathComponent(file)
            let createdAt = (try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date ?? Date()
            guard let data = fm.contents(atPath: path),
                  let content = String(data: data, encoding: .utf8),
                  let task = WorkTask.parse(from: content, id: id, createdAt: createdAt) else { continue }
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
