import Foundation

/// Manages user-created todos persisted as JSON files in `.wtpad/todos/`.
@MainActor
class TodoManager: ObservableObject {
    @Published var todos: [Todo] = []

    var incompleteTodos: [Todo] { todos.filter { $0.status != .completed } }
    var completedTodos: [Todo] { todos.filter { $0.status == .completed } }

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
        watchTodosDirectory()
    }

    func stopWatching() {
        pendingReload?.cancel()
        pendingReload = nil
        watcherSource?.cancel()
        watcherSource = nil
    }

    // MARK: - CRUD

    func createTodo(subject: String) {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let nextID = (todos.map(\.id).max() ?? 0) + 1
        let todo = Todo(id: nextID, subject: trimmed)
        write(todo)
        reload()
    }

    func updateTodoSubject(_ todo: Todo, to newSubject: String) {
        let trimmed = newSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = todo
        updated.subject = trimmed
        write(updated)
        reload()
    }

    func cycleStatus(_ todo: Todo) {
        setStatus(todo, to: todo.nextStatus)
    }

    func setStatus(_ todo: Todo, to status: Todo.Status) {
        guard todo.status != status else { return }
        var updated = todo
        let crossedSections = (todo.status == .completed) != (status == .completed)
        updated.status = status
        if crossedSections { updated.statusChangedAt = Date() }
        write(updated)
        reload()
    }

    func deleteTodo(_ todo: Todo) {
        guard let dir = todosDirectory else { return }
        let path = (dir as NSString).appendingPathComponent("\(todo.id).json")
        try? FileManager.default.removeItem(atPath: path)
        reload()
    }

    // MARK: - Persistence

    private var todosDirectory: String? {
        guard let worktreePath else { return nil }
        return (worktreePath as NSString).appendingPathComponent(".wtpad/todos")
    }

    private func write(_ todo: Todo) {
        guard let dir = todosDirectory else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(todo.id).json")
        guard let data = try? JSONEncoder().encode(todo) else { return }
        fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        // Start watching if this was the first write that created the directory
        if watcherSource == nil { watchTodosDirectory() }
    }

    func reload() {
        guard let dir = todosDirectory else {
            todos = []
            return
        }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else {
            todos = []
            return
        }

        let decoder = JSONDecoder()
        var loaded: [Todo] = []

        for file in files where file.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let todo = try? decoder.decode(Todo.self, from: data) else { continue }
            loaded.append(todo)
        }

        // Incomplete: oldest status change first (new todos at top, recently uncompleted at bottom)
        // Completed: most recently completed first
        let incomplete = loaded.filter { $0.status != .completed }
            .sorted { $0.statusChangedAt < $1.statusChangedAt }
        let completed = loaded.filter { $0.status == .completed }
            .sorted { $0.statusChangedAt > $1.statusChangedAt }
        let newTodos = incomplete + completed
        if newTodos != todos { todos = newTodos }
    }

    // MARK: - File Watching

    private func watchTodosDirectory() {
        watcherSource?.cancel()
        watcherSource = nil

        guard let dir = todosDirectory else { return }

        // Only watch if the directory already exists — it gets created on first todo write.
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
