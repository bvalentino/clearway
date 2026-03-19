import Foundation
import os

/// Reads Claude Code todos for a given worktree path from `~/.claude/`.
///
/// Session UUIDs are discovered from `~/.claude/projects/<encoded-path>/`
/// and their todos are read from `~/.claude/tasks/<uuid>/`.
@MainActor
class ClaudeTodoManager: ObservableObject {
    @Published var sessions: [ClaudeSession] = []

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.wtpad.mac",
        category: "claude-todos"
    )

    private var worktreePath: String?
    private var clearedSessionIds: Set<String> = []
    private var watcherSources: [DispatchSourceFileSystemObject] = []
    private var pendingReload: DispatchWorkItem?
    private var reloadTask: Task<Void, Never>?
    private var pendingPolls: [DispatchWorkItem] = []
    private var needsWatcherRebuild = false

    private static let claudeDir: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }()

    nonisolated deinit {
        reloadTask?.cancel()
        pendingReload?.cancel()
        for poll in pendingPolls { poll.cancel() }
        for source in watcherSources { source.cancel() }
    }

    func setWorktreePath(_ path: String?) {
        guard path != worktreePath else { return }
        Self.logger.info("setWorktreePath: \(path ?? "nil", privacy: .public)")
        stopWatching()
        worktreePath = path
        // Immediately load cached sessions so the UI has data right away,
        // before the async reload fetches live data from ~/.claude/tasks/.
        if let path {
            sessions = Self.readCache(at: Self.cacheFilePath(forWorktreePath: path))
        } else {
            sessions = []
        }
        reload()
        watchTodoDirectories()
    }

    func stopWatching() {
        reloadTask?.cancel()
        reloadTask = nil
        pendingReload?.cancel()
        pendingReload = nil
        for poll in pendingPolls { poll.cancel() }
        pendingPolls = []
        for source in watcherSources { source.cancel() }
        watcherSources = []
        clearedSessionIds = []
        worktreePath = nil
    }

    func reload() {
        reloadTask?.cancel()
        guard let worktreePath else {
            sessions = []
            return
        }

        let claudeDir = Self.claudeDir
        let encodedPath = Self.encodePathForClaude(worktreePath)
        let cacheFile = Self.cacheFilePath(forWorktreePath: worktreePath)

        let cleared = clearedSessionIds
        reloadTask = Task.detached { [weak self] in
            let live = Self.loadSessions(claudeDir: claudeDir, encodedPath: encodedPath)
            guard !Task.isCancelled else { return }
            let cached = Self.readCache(at: cacheFile)
            let merged = Self.mergeSessions(live: live, cached: cached)
                .filter { !cleared.contains($0.id) }
            Self.writeCache(merged, to: cacheFile)
            guard !Task.isCancelled else { return }
            let todoCount = merged.reduce(0) { $0 + $1.todos.count }
            Self.logger.info("reload: \(merged.count) sessions, \(todoCount) todos (live=\(live.count), cached=\(cached.count))")
            await MainActor.run {
                self?.sessions = merged
            }
        }
    }

    private nonisolated static func loadSessions(claudeDir: String, encodedPath: String) -> [ClaudeSession] {
        let projectDir = (claudeDir as NSString)
            .appendingPathComponent("projects")
            .appending("/\(encodedPath)")

        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: projectDir) else {
            Self.logger.debug("loadSessions: no project dir at \(encodedPath, privacy: .public)")
            return []
        }

        let sessionUUIDs = contents
            .filter { $0.hasSuffix(".jsonl") }
            .map { String($0.dropLast(".jsonl".count)) }

        var newSessions: [ClaudeSession] = []
        let decoder = JSONDecoder()

        for uuid in sessionUUIDs {
            let tasksDir = (claudeDir as NSString)
                .appendingPathComponent("tasks")
                .appending("/\(uuid)")

            guard let todoFiles = try? fm.contentsOfDirectory(atPath: tasksDir) else {
                Self.logger.debug("loadSessions: no tasks dir for session \(uuid, privacy: .public)")
                continue
            }

            let jsonFiles = todoFiles.filter { $0.hasSuffix(".json") }
            guard !jsonFiles.isEmpty else { continue }

            var todos: [ClaudeTodo] = []
            var latestDate = Date.distantPast

            for file in jsonFiles {
                let filePath = (tasksDir as NSString).appendingPathComponent(file)
                guard let data = fm.contents(atPath: filePath) else { continue }
                guard let todo = try? decoder.decode(ClaudeTodo.self, from: data) else { continue }
                todos.append(todo)

                if let attrs = try? fm.attributesOfItem(atPath: filePath),
                   let modDate = attrs[.modificationDate] as? Date,
                   modDate > latestDate {
                    latestDate = modDate
                }
            }

            if !todos.isEmpty {
                todos.sort { Int($0.id) ?? 0 < Int($1.id) ?? 0 }
                newSessions.append(ClaudeSession(id: uuid, todos: todos, modificationDate: latestDate))
            }
        }

        newSessions.sort { $0.modificationDate > $1.modificationDate }
        return newSessions
    }

    /// Removes a session from the displayed list and cache.
    /// Does not touch `~/.claude/tasks/` — those files belong to Claude Code.
    func clearSession(_ sessionId: String) {
        clearedSessionIds.insert(sessionId)
        sessions.removeAll { $0.id == sessionId }
        guard let worktreePath else { return }
        let cacheFile = Self.cacheFilePath(forWorktreePath: worktreePath)
        let snapshot = sessions
        Task.detached {
            Self.writeCache(snapshot, to: cacheFile)
        }
    }

    // MARK: - Cache

    private static let cacheFileName = ".wtpad/claude-tasks.json"

    private nonisolated static func cacheFilePath(forWorktreePath path: String) -> String {
        (path as NSString).appendingPathComponent(cacheFileName)
    }

    private nonisolated static func readCache(at path: String) -> [ClaudeSession] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([ClaudeSession].self, from: data)) ?? []
    }

    private nonisolated static func writeCache(_ sessions: [ClaudeSession], to path: String) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Merges live sessions with cached sessions. Live todos take precedence;
    /// cached todos whose files were deleted are marked completed (Claude Code
    /// deletes task files when a session finishes).
    private nonisolated static func mergeSessions(live: [ClaudeSession], cached: [ClaudeSession]) -> [ClaudeSession] {
        var sessionsByID: [String: ClaudeSession] = [:]
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { $1 })

        for session in cached {
            if let liveSession = liveByID[session.id] {
                // Merge: live todos win, cached-only todos marked completed
                let liveTodoIDs = Set(liveSession.todos.map(\.id))
                var todosByID: [String: ClaudeTodo] = [:]
                for todo in session.todos where !liveTodoIDs.contains(todo.id) {
                    var marked = todo
                    if marked.status != .completed { marked.status = .completed }
                    todosByID[todo.id] = marked
                }
                for todo in liveSession.todos { todosByID[todo.id] = todo }
                let mergedTodos = todosByID.values.sorted { Int($0.id) ?? 0 < Int($1.id) ?? 0 }
                sessionsByID[session.id] = ClaudeSession(
                    id: session.id,
                    todos: mergedTodos,
                    modificationDate: max(liveSession.modificationDate, session.modificationDate)
                )
            } else {
                // Session no longer live — mark all non-completed todos as completed
                let todos = session.todos.map { todo -> ClaudeTodo in
                    guard todo.status != .completed else { return todo }
                    var copy = todo
                    copy.status = .completed
                    return copy
                }
                sessionsByID[session.id] = ClaudeSession(
                    id: session.id, todos: todos, modificationDate: session.modificationDate
                )
            }
        }

        // Add live-only sessions (not in cache)
        for liveSession in live where sessionsByID[liveSession.id] == nil {
            sessionsByID[liveSession.id] = liveSession
        }

        return sessionsByID.values.sorted { $0.modificationDate > $1.modificationDate }
    }

    // MARK: - Path Encoding

    /// Encodes a filesystem path to Claude Code's project directory name format.
    /// `/Users/foo/bar` → `-Users-foo-bar` (replaces `/` and `.` with `-`).
    static func encodePathForClaude(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Returns the Claude Code projects directory for a given worktree path.
    static func projectDir(forWorktreePath path: String) -> String {
        let encoded = encodePathForClaude(path)
        return (claudeDir as NSString)
            .appendingPathComponent("projects")
            .appending("/\(encoded)")
    }

    // MARK: - File Watching

    private func watchTodoDirectories() {
        for source in watcherSources { source.cancel() }
        watcherSources = []
        for poll in pendingPolls { poll.cancel() }
        pendingPolls = []

        guard let worktreePath else { return }

        let claudeDir = Self.claudeDir
        let encodedPath = Self.encodePathForClaude(worktreePath)
        let projectDir = (claudeDir as NSString)
            .appendingPathComponent("projects")
            .appending("/\(encodedPath)")

        // Watch the projects directory for new sessions
        if let source = Self.makeWatcher(path: projectDir) { [weak self] in
            Self.logger.debug("projects dir watcher fired")
            self?.scheduleReload(rebuildWatchers: true)
        } {
            Self.logger.info("watching projects dir: \(projectDir, privacy: .public)")
            watcherSources.append(source)
        } else {
            // Projects directory doesn't exist yet (new worktree, never had Claude).
            // Poll until Claude creates it.
            Self.logger.info("projects dir missing, polling: \(projectDir, privacy: .public)")
            pollForDirectory(path: projectDir) { [weak self] in
                self?.scheduleReload(rebuildWatchers: true)
            }
        }

        // Watch each session's tasks directory for todo changes
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: projectDir)) ?? []
        let sessionUUIDs = contents
            .filter { $0.hasSuffix(".jsonl") }
            .map { String($0.dropLast(".jsonl".count)) }

        for uuid in sessionUUIDs {
            let tasksDir = (claudeDir as NSString)
                .appendingPathComponent("tasks")
                .appending("/\(uuid)")

            if let source = Self.makeWatcher(path: tasksDir) { [weak self] in
                Self.logger.debug("tasks dir watcher fired for \(uuid, privacy: .public)")
                self?.scheduleReload(rebuildWatchers: false)
            } {
                Self.logger.info("watching tasks dir: \(uuid, privacy: .public)")
                watcherSources.append(source)
            } else {
                // Tasks directory doesn't exist yet — poll until it appears
                // so we pick it up when Claude creates it.
                Self.logger.info("tasks dir missing, polling: \(uuid, privacy: .public)")
                pollForDirectory(path: tasksDir) { [weak self] in
                    Self.logger.info("poll found tasks dir: \(uuid, privacy: .public)")
                    self?.scheduleReload(rebuildWatchers: true)
                }
            }
        }
    }

    /// Coalesces rapid file system events into a single reload after a short delay.
    /// The `rebuildWatchers` flag is latched — once any event requests a rebuild,
    /// it won't be lost even if a later event within the window doesn't need one.
    private nonisolated func scheduleReload(rebuildWatchers: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingReload?.cancel()
            if rebuildWatchers { self.needsWatcherRebuild = true }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldRebuild = self.needsWatcherRebuild
                self.needsWatcherRebuild = false
                self.reload()
                if shouldRebuild {
                    self.watchTodoDirectories()
                }
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// Checks for a directory's existence every second, up to 30 times.
    /// Calls `handler` once when the directory appears, then stops.
    /// Poll work items are tracked in `pendingPolls` so they can be cancelled
    /// when watchers are rebuilt.
    private nonisolated func pollForDirectory(
        path: String,
        attempt: Int = 0,
        handler: @escaping () -> Void
    ) {
        guard attempt < 30 else { return }
        let work = DispatchWorkItem { [weak self] in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                handler()
            } else {
                self?.pollForDirectory(path: path, attempt: attempt + 1, handler: handler)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.pendingPolls.append(work)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    nonisolated static func makeWatcher(
        path: String,
        handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
