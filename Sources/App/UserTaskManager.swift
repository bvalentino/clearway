import Foundation

/// Manages user-created tasks persisted as JSON files in `.wtpad/tasks/`.
@MainActor
class UserTaskManager: ObservableObject {
    @Published var tasks: [UserTask] = []

    private var worktreePath: String?
    private var watcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    /// Monotonic timestamp of the last programmatic reload, used to suppress
    /// redundant watcher-triggered reloads within the debounce window.
    private var lastReloadTime: DispatchTime = .init(uptimeNanoseconds: 0)

    nonisolated deinit {
        pendingReload?.cancel()
        watcherSource?.cancel()
    }

    // MARK: - Lifecycle

    func setWorktreePath(_ path: String?) {
        guard path != worktreePath else { return }
        stopWatching()
        worktreePath = path
        reload()
        watchTasksDirectory()
    }

    func stopWatching() {
        pendingReload?.cancel()
        pendingReload = nil
        watcherSource?.cancel()
        watcherSource = nil
    }

    // MARK: - CRUD

    func createTask(subject: String) {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = UserTask(subject: trimmed)
        write(task)
        reload()
    }

    func updateTaskSubject(_ task: UserTask, to newSubject: String) {
        let trimmed = newSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = task
        updated.subject = trimmed
        updated.updatedAt = Date()
        write(updated)
        reload()
    }

    func toggleComplete(_ task: UserTask) {
        var updated = task
        updated.isCompleted.toggle()
        updated.updatedAt = Date()
        write(updated)
        reload()
    }

    func deleteTask(_ task: UserTask) {
        guard let dir = tasksDirectory else { return }
        let path = (dir as NSString).appendingPathComponent("\(task.id).json")
        try? FileManager.default.removeItem(atPath: path)
        reload()
    }

    // MARK: - Persistence

    private var tasksDirectory: String? {
        guard let worktreePath else { return nil }
        return (worktreePath as NSString).appendingPathComponent(".wtpad/tasks")
    }

    private func write(_ task: UserTask) {
        guard let dir = tasksDirectory else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(task.id).json")
        guard let data = try? JSONEncoder().encode(task) else { return }
        fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        // Start watching if this was the first write that created the directory
        if watcherSource == nil { watchTasksDirectory() }
    }

    func reload() {
        lastReloadTime = .now()

        guard let dir = tasksDirectory else {
            tasks = []
            return
        }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else {
            tasks = []
            return
        }

        let decoder = JSONDecoder()
        var loaded: [UserTask] = []

        for file in files where file.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let task = try? decoder.decode(UserTask.self, from: data) else { continue }
            loaded.append(task)
        }

        // Incomplete tasks sorted by createdAt (oldest first), completed at bottom
        let incomplete = loaded.filter { !$0.isCompleted }.sorted { $0.createdAt < $1.createdAt }
        let completed = loaded.filter { $0.isCompleted }.sorted { $0.updatedAt > $1.updatedAt }
        tasks = incomplete + completed
    }

    // MARK: - File Watching

    private func watchTasksDirectory() {
        watcherSource?.cancel()
        watcherSource = nil

        guard let dir = tasksDirectory else { return }

        // Only watch if the directory already exists — it gets created on first task write.
        guard FileManager.default.fileExists(atPath: dir) else { return }

        let fd = open(dir, O_EVTONLY)
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
                guard let self else { return }
                // Skip if a programmatic reload happened recently
                guard DispatchTime.now() > self.lastReloadTime + 0.3 else { return }
                self.reload()
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
}
