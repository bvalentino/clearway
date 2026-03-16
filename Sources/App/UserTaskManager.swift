import Foundation

/// Manages user-created tasks persisted as JSON files in `.wtpad/tasks/`.
@MainActor
class UserTaskManager: ObservableObject {
    @Published var tasks: [UserTask] = []

    var incompleteTasks: [UserTask] { tasks.filter { $0.status != .completed } }
    var completedTasks: [UserTask] { tasks.filter { $0.status == .completed } }

    private var worktreePath: String?
    private var watcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

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
        let nextID = (tasks.map(\.id).max() ?? 0) + 1
        let task = UserTask(id: nextID, subject: trimmed)
        write(task)
        reload()
    }

    func updateTaskSubject(_ task: UserTask, to newSubject: String) {
        let trimmed = newSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = task
        updated.subject = trimmed
        write(updated)
        reload()
    }

    func cycleStatus(_ task: UserTask) {
        setStatus(task, to: task.nextStatus)
    }

    func setStatus(_ task: UserTask, to status: UserTask.Status) {
        guard task.status != status else { return }
        var updated = task
        let crossedSections = (task.status == .completed) != (status == .completed)
        updated.status = status
        if crossedSections { updated.statusChangedAt = Date() }
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

        // Incomplete: oldest status change first (new tasks at top, recently uncompleted at bottom)
        // Completed: most recently completed first
        let incomplete = loaded.filter { $0.status != .completed }
            .sorted { $0.statusChangedAt < $1.statusChangedAt }
        let completed = loaded.filter { $0.status == .completed }
            .sorted { $0.statusChangedAt > $1.statusChangedAt }
        let newTasks = incomplete + completed
        if newTasks != tasks { tasks = newTasks }
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
                self?.reload()
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
}
