import Foundation

/// Reads Claude Code tasks for a given worktree path from `~/.claude/`.
///
/// Session UUIDs are discovered from `~/.claude/projects/<encoded-path>/`
/// and their tasks are read from `~/.claude/tasks/<uuid>/`.
@MainActor
class ClaudeTaskManager: ObservableObject {
    @Published var sessions: [ClaudeSession] = []

    private var worktreePath: String?
    private var watcherSources: [DispatchSourceFileSystemObject] = []
    private var pendingReload: DispatchWorkItem?
    private var needsWatcherRebuild = false

    private static let claudeDir: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }()

    nonisolated deinit {
        pendingReload?.cancel()
        for source in watcherSources { source.cancel() }
    }

    func setWorktreePath(_ path: String?) {
        guard path != worktreePath else { return }
        stopWatching()
        worktreePath = path
        reload()
        watchTaskDirectories()
    }

    func stopWatching() {
        pendingReload?.cancel()
        pendingReload = nil
        for source in watcherSources { source.cancel() }
        watcherSources = []
    }

    func reload() {
        guard let worktreePath else {
            sessions = []
            return
        }

        let claudeDir = Self.claudeDir
        let encodedPath = Self.encodePathForClaude(worktreePath)
        let cacheFile = Self.cacheFilePath(forWorktreePath: worktreePath)

        Task.detached { [weak self] in
            let live = Self.loadSessions(claudeDir: claudeDir, encodedPath: encodedPath)
            let cached = Self.readCache(at: cacheFile)
            let merged = Self.mergeSessions(live: live, cached: cached)
            Self.writeCache(merged, to: cacheFile)
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

            guard let taskFiles = try? fm.contentsOfDirectory(atPath: tasksDir) else { continue }

            let jsonFiles = taskFiles.filter { $0.hasSuffix(".json") }
            guard !jsonFiles.isEmpty else { continue }

            var tasks: [ClaudeTask] = []
            var latestDate = Date.distantPast

            for file in jsonFiles {
                let filePath = (tasksDir as NSString).appendingPathComponent(file)
                guard let data = fm.contents(atPath: filePath) else { continue }
                guard let task = try? decoder.decode(ClaudeTask.self, from: data) else { continue }
                tasks.append(task)

                if let attrs = try? fm.attributesOfItem(atPath: filePath),
                   let modDate = attrs[.modificationDate] as? Date,
                   modDate > latestDate {
                    latestDate = modDate
                }
            }

            if !tasks.isEmpty {
                tasks.sort { Int($0.id) ?? 0 < Int($1.id) ?? 0 }
                newSessions.append(ClaudeSession(id: uuid, tasks: tasks, modificationDate: latestDate))
            }
        }

        newSessions.sort { $0.modificationDate > $1.modificationDate }
        return newSessions
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

    /// Merges live sessions with cached sessions. Live tasks take precedence;
    /// cached tasks whose files were deleted are marked completed (Claude Code
    /// deletes task files when a session finishes).
    private nonisolated static func mergeSessions(live: [ClaudeSession], cached: [ClaudeSession]) -> [ClaudeSession] {
        var sessionsByID: [String: ClaudeSession] = [:]
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { $1 })

        for session in cached {
            if let liveSession = liveByID[session.id] {
                // Merge: live tasks win, cached-only tasks marked completed
                let liveTaskIDs = Set(liveSession.tasks.map(\.id))
                var tasksByID: [String: ClaudeTask] = [:]
                for task in session.tasks where !liveTaskIDs.contains(task.id) {
                    var marked = task
                    if marked.status != .completed { marked.status = .completed }
                    tasksByID[task.id] = marked
                }
                for task in liveSession.tasks { tasksByID[task.id] = task }
                let mergedTasks = tasksByID.values.sorted { Int($0.id) ?? 0 < Int($1.id) ?? 0 }
                sessionsByID[session.id] = ClaudeSession(
                    id: session.id,
                    tasks: mergedTasks,
                    modificationDate: max(liveSession.modificationDate, session.modificationDate)
                )
            } else {
                // Session no longer live — mark all non-completed tasks as completed
                let tasks = session.tasks.map { task -> ClaudeTask in
                    guard task.status != .completed else { return task }
                    var copy = task
                    copy.status = .completed
                    return copy
                }
                sessionsByID[session.id] = ClaudeSession(
                    id: session.id, tasks: tasks, modificationDate: session.modificationDate
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

    // MARK: - File Watching

    private func watchTaskDirectories() {
        for source in watcherSources { source.cancel() }
        watcherSources = []

        guard let worktreePath else { return }

        let claudeDir = Self.claudeDir
        let encodedPath = Self.encodePathForClaude(worktreePath)
        let projectDir = (claudeDir as NSString)
            .appendingPathComponent("projects")
            .appending("/\(encodedPath)")

        // Watch the projects directory for new sessions
        if let source = Self.makeWatcher(path: projectDir) { [weak self] in
            self?.scheduleReload(rebuildWatchers: true)
        } {
            watcherSources.append(source)
        }

        // Watch each session's tasks directory for task changes
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
                self?.scheduleReload(rebuildWatchers: false)
            } {
                watcherSources.append(source)
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
                    self.watchTaskDirectories()
                }
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private nonisolated static func makeWatcher(
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
