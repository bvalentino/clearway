import Foundation

/// The on-disk layout of the task pool, shared by the app and the `clearway` CLI. Backlog tasks
/// live centrally in `<project>/.clearway/tasks/<UUID>.md`; a task linked to a live worktree lives
/// in that worktree as `.clearway/TASK.md`.
enum TaskFiles {

    struct LoadedTask: Equatable {
        let task: WorkTask
        let path: String
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
    /// `fallbackId` only when the frontmatter carries no `id`. When `requireFrontmatterID` is set
    /// (worktree `TASK.md`, whose filename carries no UUID), a file lacking a usable frontmatter
    /// `id` is rejected rather than loaded under the synthetic `fallbackId`. Returns nil on
    /// read/parse failure.
    static func load(atPath path: String, fallbackId: UUID, requireFrontmatterID: Bool = false) -> WorkTask? {
        let fm = FileManager.default
        let createdAt = (try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date ?? Date()
        guard let data = fm.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }
        if requireFrontmatterID, WorkTask.frontmatterID(from: content) == nil { return nil }
        return WorkTask.parse(from: content, id: fallbackId, createdAt: createdAt)
    }

    /// Merge-loads the single task pool from two sources: the central backlog (`<UUID>.md`)
    /// **and** every worktree's `TASK.md`. A task that exists in both (e.g. mid-move) is
    /// deduped by `id` with the worktree copy winning. Newest first.
    static func loadPool(tasksDirectory: String, worktreePaths: [String]) -> [LoadedTask] {
        var byId: [UUID: LoadedTask] = [:]

        // Central backlog files: keyed by filename UUID (also the fallback identity for legacy
        // files written before `id` was serialized into frontmatter).
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tasksDirectory) {
            for file in files where file.hasSuffix(".md") {
                guard let id = UUID(uuidString: (file as NSString).deletingPathExtension) else { continue }
                let path = (tasksDirectory as NSString).appendingPathComponent(file)
                if let task = load(atPath: path, fallbackId: id) {
                    byId[task.id] = LoadedTask(task: task, path: path)
                }
            }
        }

        // Each worktree's TASK.md (identity comes from frontmatter). The worktree copy wins
        // over any central entry with the same id. A `TASK.md` whose frontmatter carries no usable
        // `id` is skipped — without one its identity would be a fresh random UUID on every reload,
        // flapping the task in and out of the pool. (Going forward every write emits `id`; this
        // guards against an external agent/hook rewriting `TASK.md` and dropping the line.)
        for worktreePath in worktreePaths {
            let path = taskMarkdownPath(inWorktree: worktreePath)
            if let task = load(atPath: path, fallbackId: UUID(), requireFrontmatterID: true) {
                byId[task.id] = LoadedTask(task: task, path: path)
            }
        }

        return byId.values.sorted { $0.task.createdAt > $1.task.createdAt }
    }
}
