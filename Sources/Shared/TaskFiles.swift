import Foundation

/// The on-disk layout of the task pool, shared by the app and the `cway` CLI. Backlog tasks
/// live centrally in `<project>/.clearway/tasks/<UUID>.md`; a task linked to a live worktree lives
/// in that worktree as `.clearway/TASK.md`.
enum TaskFiles {

    struct LoadedTask: Equatable {
        let task: WorkTask
        let path: String
    }

    enum SkipReason: String, Error {
        case unlistable = "cannot list the directory"
        case unreadable = "cannot read the file"
        case unparseable = "cannot parse the frontmatter"
        case noFrontmatterID = "its frontmatter has no id"
    }

    struct SkippedFile: Equatable {
        let path: String
        let reason: SkipReason
    }

    struct LoadedPool: Equatable {
        let tasks: [LoadedTask]
        let skipped: [SkippedFile]
    }

    static func tasksDirectory(inProject projectPath: String) -> String {
        (projectPath as NSString).appendingPathComponent(".clearway/tasks")
    }

    static func centralPath(for id: UUID, tasksDirectory: String) -> String {
        (tasksDirectory as NSString).appendingPathComponent("\(id.uuidString).md")
    }

    /// `.clearway/TASK.md` under a worktree root.
    static func taskMarkdownPath(inWorktree worktreePath: String) -> String {
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        return (clearway as NSString).appendingPathComponent("TASK.md")
    }

    static func write(_ task: WorkTask, toPath path: String) throws {
        let fm = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: path, contents: Data(task.serialized().utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
    }

    /// Reads and parses a task file, deriving `createdAt` from the file's creation date and using
    /// `fallbackId` only when the frontmatter carries no `id`. Returns nil on read/parse failure.
    static func load(atPath path: String, fallbackId: UUID) -> WorkTask? {
        try? loadResult(atPath: path, fallbackId: fallbackId, requireFrontmatterID: false).get()
    }

    private static func loadResult(atPath path: String, fallbackId: UUID, requireFrontmatterID: Bool) -> Result<WorkTask, SkipReason> {
        let fm = FileManager.default
        let createdAt = (try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date ?? Date()
        guard let data = fm.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return .failure(.unreadable) }
        guard let task = WorkTask.parse(from: content, id: fallbackId, createdAt: createdAt) else { return .failure(.unparseable) }
        if requireFrontmatterID, WorkTask.frontmatterID(from: content) == nil { return .failure(.noFrontmatterID) }
        return .success(task)
    }

    /// Merge-loads the single task pool from two sources: the central backlog (`<UUID>.md`)
    /// **and** every worktree's `TASK.md`. A task that exists in both (e.g. mid-move) is
    /// deduped by `id` with the worktree copy winning. Newest first. A file or directory that
    /// exists but cannot be loaded is reported in `skipped`, ordered by path; a missing one is not.
    /// Existence is `lstat`, not `fileExists`, so a dangling symlink is reported rather than missing.
    static func loadPool(tasksDirectory: String, worktreePaths: [String]) -> LoadedPool {
        let fm = FileManager.default
        var byId: [UUID: LoadedTask] = [:]
        var skipped: [SkippedFile] = []

        func exists(_ path: String) -> Bool { (try? fm.attributesOfItem(atPath: path)) != nil }

        func add(_ path: String, fallbackId: UUID, requireFrontmatterID: Bool) {
            switch loadResult(atPath: path, fallbackId: fallbackId, requireFrontmatterID: requireFrontmatterID) {
            case .success(let task): byId[task.id] = LoadedTask(task: task, path: path)
            case .failure(let reason): skipped.append(SkippedFile(path: path, reason: reason))
            }
        }

        // Central backlog files: keyed by filename UUID (also the fallback identity for legacy
        // files written before `id` was serialized into frontmatter).
        if exists(tasksDirectory) {
            if let files = try? fm.contentsOfDirectory(atPath: tasksDirectory) {
                for file in files where file.hasSuffix(".md") {
                    guard let id = UUID(uuidString: (file as NSString).deletingPathExtension) else { continue }
                    add((tasksDirectory as NSString).appendingPathComponent(file), fallbackId: id, requireFrontmatterID: false)
                }
            } else {
                skipped.append(SkippedFile(path: tasksDirectory, reason: .unlistable))
            }
        }

        // Each worktree's TASK.md (identity comes from frontmatter). The worktree copy wins
        // over any central entry with the same id. A `TASK.md` whose frontmatter carries no usable
        // `id` is skipped — without one its identity would be a fresh random UUID on every reload,
        // flapping the task in and out of the pool. (Going forward every write emits `id`; this
        // guards against an external agent/hook rewriting `TASK.md` and dropping the line.)
        for worktreePath in worktreePaths {
            let path = taskMarkdownPath(inWorktree: worktreePath)
            guard exists(path) else { continue }
            add(path, fallbackId: UUID(), requireFrontmatterID: true)
        }

        return LoadedPool(
            tasks: byId.values.sorted { $0.task.createdAt > $1.task.createdAt },
            skipped: skipped.sorted { $0.path < $1.path }
        )
    }
}
