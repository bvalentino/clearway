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

    private static let claudeDir: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }()

    nonisolated deinit {
        for source in watcherSources { source.cancel() }
    }

    func setWorktreePath(_ path: String?) {
        guard path != worktreePath else { return }
        worktreePath = path
        reload()
        watchTaskDirectories()
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
        FileManager.default.createFile(atPath: path, contents: data)
    }

    /// Merges live sessions with cached sessions. Live tasks take precedence;
    /// cached tasks that no longer exist in live data are preserved.
    private nonisolated static func mergeSessions(live: [ClaudeSession], cached: [ClaudeSession]) -> [ClaudeSession] {
        var sessionsByID: [String: ClaudeSession] = [:]

        // Start with cached sessions
        for session in cached {
            sessionsByID[session.id] = session
        }

        // Merge live data on top
        for liveSession in live {
            if let existing = sessionsByID[liveSession.id] {
                // Merge tasks: live tasks win, keep cached tasks that were deleted
                var tasksByID: [String: ClaudeTask] = [:]
                for task in existing.tasks { tasksByID[task.id] = task }
                for task in liveSession.tasks { tasksByID[task.id] = task }
                let mergedTasks = tasksByID.values.sorted { Int($0.id) ?? 0 < Int($1.id) ?? 0 }
                sessionsByID[liveSession.id] = ClaudeSession(
                    id: liveSession.id,
                    tasks: mergedTasks,
                    modificationDate: max(liveSession.modificationDate, existing.modificationDate)
                )
            } else {
                sessionsByID[liveSession.id] = liveSession
            }
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
            DispatchQueue.main.async {
                // New session appeared — rebuild watchers to include its tasks dir
                self?.reload()
                self?.watchTaskDirectories()
            }
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

            // Watch the directory for new/deleted task files
            if let source = Self.makeWatcher(path: tasksDir) { [weak self] in
                DispatchQueue.main.async {
                    self?.reload()
                    self?.watchTaskDirectories()
                }
            } {
                watcherSources.append(source)
            }

            // Watch each individual task file for content changes (e.g. status updates)
            let taskFiles = (try? fm.contentsOfDirectory(atPath: tasksDir)) ?? []
            for file in taskFiles where file.hasSuffix(".json") {
                let filePath = (tasksDir as NSString).appendingPathComponent(file)
                if let source = Self.makeWatcher(path: filePath, eventMask: [.write, .delete, .rename]) { [weak self] in
                    DispatchQueue.main.async {
                        self?.reload()
                    }
                } {
                    watcherSources.append(source)
                }
            }
        }
    }

    private nonisolated static func makeWatcher(
        path: String,
        eventMask: DispatchSource.FileSystemEvent = .write,
        handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: eventMask,
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
