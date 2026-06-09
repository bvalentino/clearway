import Foundation

/// Manages tasks persisted as markdown files whose location encodes their association with a
/// worktree. Backlog tasks live centrally in `.clearway/tasks/<UUID>.md`; a task linked to a live
/// worktree lives in that worktree as `.clearway/TASK.md`. The pool is merge-loaded from both
/// sources, with a branch→worktree-path resolver injected at construction so the manager keeps no
/// `WorktreeManager` dependency.
@MainActor
class WorkTaskManager: ObservableObject {
    @Published var tasks: [WorkTask] = []

    let projectPath: String
    let tasksDirectory: String
    private var watcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    /// `.clearway` watchers for opened worktrees, keyed by the watched directory path. Only
    /// opened worktrees are watched (mirroring the central watcher); closed worktrees are still
    /// loaded by `reload()` but not watched, keeping file-descriptor cost proportional to what's
    /// on screen. Driven from the view layer via `setWatchedWorktrees(_:)`.
    private var worktreeWatchers: [String: DispatchSourceFileSystemObject] = [:]

    /// Guards `migrateCentralTasks()` so it runs at most once per manager instance.
    private var didMigrate = false

    /// Resolves the live worktrees as `(branch, path)` pairs. Injected at construction so the
    /// manager can route a task's file to its worktree (and merge-load every worktree's
    /// `TASK.md`) without taking a hard dependency on `WorktreeManager`. Defaults to empty,
    /// which yields central-only behavior — the shape unit tests exercise.
    var worktreeResolver: @MainActor () -> [(branch: String, path: String)] = { [] }

    init(projectPath: String) {
        self.projectPath = projectPath
        self.tasksDirectory = (projectPath as NSString).appendingPathComponent(".clearway/tasks")
        reload()
        watchDirectory()
    }

    /// Absolute path to a branch's live worktree, or nil when the branch has no worktree.
    private func worktreePath(forBranch branch: String) -> String? {
        worktreeResolver().first { $0.branch == branch }?.path
    }

    /// Relocates a task's central `<UUID>.md` into its now-live worktree as `TASK.md`, preserving
    /// the file's creation date via `FileManager.moveItem` (never copy+delete). Idempotent: a no-op
    /// when the central file is already gone; if the destination already exists, the central residue
    /// is removed so the worktree copy wins. The `id` already lives in frontmatter (carried on every
    /// write), so identity survives the rename. Re-merges the pool afterward.
    func relocateTaskToWorktree(id: UUID, worktreePath: String) {
        moveCentralFileIntoWorktree(id: id, worktreePath: worktreePath)
        reload()
    }

    /// The file move itself, without a re-merge — so batch callers (migration) can move many files
    /// and reload once. See `relocateTaskToWorktree` for the doc on creation-date preservation and
    /// idempotency.
    private func moveCentralFileIntoWorktree(id: UUID, worktreePath: String) {
        let fm = FileManager.default
        let central = (tasksDirectory as NSString).appendingPathComponent("\(id.uuidString).md")
        guard fm.fileExists(atPath: central) else { return }

        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        let destination = (clearway as NSString).appendingPathComponent("TASK.md")
        if fm.fileExists(atPath: destination) {
            try? fm.removeItem(atPath: central)
        } else {
            try? fm.createDirectory(atPath: clearway, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.moveItem(atPath: central, toPath: destination)
            // Legacy files carried identity in the filename (`<UUID>.md`), which the rename to
            // `TASK.md` discards. Inject the id into the moved file's frontmatter so identity
            // survives — otherwise the next reload, having no filename UUID and no frontmatter id,
            // would skip it (see `reload`) and the task would vanish.
            ensureFrontmatterID(id, atPath: destination)
        }
    }

    /// Inserts `id: <uuid>` as the first frontmatter line of the file at `path` when its frontmatter
    /// carries no usable `id`. Rewrites in place (non-atomic, so the same inode — and the creation
    /// date the move preserved — is kept) and touches nothing else byte-for-byte.
    private func ensureFrontmatterID(_ id: UUID, atPath path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              var content = String(data: data, encoding: .utf8),
              WorkTask.frontmatterID(from: content) == nil,
              content.hasPrefix("---\n") else { return }
        content.insert(contentsOf: "id: \(id.uuidString)\n", at: content.index(content.startIndex, offsetBy: 4))
        try? content.write(toFile: path, atomically: false, encoding: .utf8)
    }

    nonisolated deinit {
        pendingReload?.cancel()
        watcherSource?.cancel()
        worktreeWatchers.values.forEach { $0.cancel() }
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
    /// (`worktree`, `status`, `attempt`, timestamps) are owned by
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

    /// Absolute path to this task's markdown file: the worktree's `TASK.md` when the task is
    /// linked to a live worktree, else the central `<UUID>.md`. Location encodes association,
    /// so the same task resolves to the worktree file the instant its branch becomes live.
    func filePath(for task: WorkTask) -> String {
        if let branch = task.worktree,
           let path = worktreePath(forBranch: branch) {
            let clearway = (path as NSString).appendingPathComponent(".clearway")
            return (clearway as NSString).appendingPathComponent("TASK.md")
        }
        return (tasksDirectory as NSString).appendingPathComponent("\(task.id.uuidString).md")
    }

    private func write(_ task: WorkTask) {
        let fm = FileManager.default
        let path = filePath(for: task)
        let directory = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = task.serialized().data(using: .utf8) else { return }
        fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        if watcherSource == nil { watchDirectory() }
    }

    /// Merge-loads the single task pool from two sources: the central backlog (`<UUID>.md`)
    /// **and** every live worktree's `TASK.md`. A task that exists in both (e.g. mid-move) is
    /// deduped by `id` with the worktree copy winning. Load breadth spans *all* worktrees — not
    /// just watched ones — so the sidebar can label even unopened worktrees by title.
    private func reload() {
        var byId: [UUID: WorkTask] = [:]

        // Central backlog files: keyed by filename UUID (also the fallback identity for legacy
        // files written before `id` was serialized into frontmatter).
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tasksDirectory) {
            for file in files where file.hasSuffix(".md") {
                guard let id = UUID(uuidString: (file as NSString).deletingPathExtension) else { continue }
                let path = (tasksDirectory as NSString).appendingPathComponent(file)
                if let task = loadTask(atPath: path, fallbackId: id) { byId[task.id] = task }
            }
        }

        // Each live worktree's TASK.md (identity comes from frontmatter). The worktree copy wins
        // over any central entry with the same id. A `TASK.md` whose frontmatter carries no usable
        // `id` is skipped — without one its identity would be a fresh random UUID on every reload,
        // flapping the task in and out of the pool. (Going forward every write emits `id`; this
        // guards against an external agent/hook rewriting `TASK.md` and dropping the line.)
        for worktree in worktreeResolver() {
            let clearway = (worktree.path as NSString).appendingPathComponent(".clearway")
            let taskMd = (clearway as NSString).appendingPathComponent("TASK.md")
            if let task = loadTask(atPath: taskMd, fallbackId: UUID(), requireFrontmatterID: true) {
                byId[task.id] = task
            }
        }

        // Newest first
        let sorted = byId.values.sorted { $0.createdAt > $1.createdAt }
        if sorted != tasks { tasks = sorted }
    }

    /// Reads and parses a task file, deriving `createdAt` from the file's creation date and using
    /// `fallbackId` only when the frontmatter carries no `id`. When `requireFrontmatterID` is set
    /// (worktree `TASK.md`, whose filename carries no UUID), a file lacking a usable frontmatter
    /// `id` is rejected rather than loaded under the synthetic `fallbackId`. Returns nil on
    /// read/parse failure.
    private func loadTask(atPath path: String, fallbackId: UUID, requireFrontmatterID: Bool = false) -> WorkTask? {
        let fm = FileManager.default
        let createdAt = (try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date ?? Date()
        guard let data = fm.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }
        if requireFrontmatterID, WorkTask.frontmatterID(from: content) == nil { return nil }
        return WorkTask.parse(from: content, id: fallbackId, createdAt: createdAt)
    }

    // MARK: - Migration

    /// One-time, idempotent migration toward location-encoded association. For each central
    /// `<UUID>.md`:
    ///   (a) if its `worktree` matches a **live** worktree, relocate it into that worktree's
    ///       `TASK.md` (so pre-existing active tasks converge on their worktree); else
    ///   (b) if it is a `done`/`canceled` orphan (no live worktree owns it), move it to the
    ///       **Trash** — recoverable, never `removeItem`, because `.clearway/` is gitignored so
    ///       permanent deletion would destroy user-authored task bodies on upgrade; else
    ///   (c) if it is a non-terminal task linked to a branch with no live worktree (a legacy
    ///       phantom — the worktree was removed out-of-band before upgrade), clear the stale link
    ///       so it returns to Planning instead of lingering as a never-converging "active" task.
    ///       The body is preserved; only the frontmatter link is rewritten in place.
    /// After the first run the central directory holds only backlog (`worktree == nil`,
    /// non-terminal), so Planning's `worktree == nil` filter needs no status check. The manager
    /// guards this to run once per instance; the caller decides *when* (after a trustworthy live
    /// worktree set is known — a partial set could mis-classify (c) and clear a valid link).
    func migrateCentralTasks() {
        guard !didMigrate else { return }

        let liveWorktrees = worktreeResolver()
        // Defer (without consuming the one-shot) until the live worktree set is known: an empty
        // resolver means worktrees haven't loaded yet, and running now would mis-classify active
        // tasks as orphans and clear valid links. Safe to call repeatedly from the view until then.
        guard !liveWorktrees.isEmpty else { return }
        didMigrate = true

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: tasksDirectory) else { return }
        var changed = false

        for file in files where file.hasSuffix(".md") {
            let path = (tasksDirectory as NSString).appendingPathComponent(file)
            guard let id = UUID(uuidString: (file as NSString).deletingPathExtension),
                  let task = loadTask(atPath: path, fallbackId: id) else { continue }

            if let branch = task.worktree,
               let live = liveWorktrees.first(where: { $0.branch == branch }) {
                moveCentralFileIntoWorktree(id: task.id, worktreePath: live.path)
                changed = true
            } else if task.status == .done || task.status == .canceled {
                try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                changed = true
            } else if task.worktree != nil {
                var detached = task
                detached.worktree = nil
                write(detached)  // worktree == nil routes back to the same central `<UUID>.md`
                changed = true
            }
        }

        // The migration trigger always re-merges the pool afterward; only pay for a reload here
        // when this run actually moved files (the steady-state post-convergence run is a no-op).
        if changed { reload() }
    }

    // MARK: - File Watching

    /// Sets which worktrees are watched for external `TASK.md` edits (by the in-worktree agent
    /// or a hook). Only **opened** worktrees are passed here — closed worktrees are still loaded
    /// by `reload()` but not watched. Adds/removes `.clearway` watchers to match `worktreePaths`,
    /// then re-merges so the pool reflects the current worktree set.
    func setWatchedWorktrees(_ worktreePaths: [String]) {
        let desired = Set(worktreePaths.map { ($0 as NSString).appendingPathComponent(".clearway") })

        for (dir, source) in worktreeWatchers where !desired.contains(dir) {
            source.cancel()
            worktreeWatchers.removeValue(forKey: dir)
        }
        for dir in desired where worktreeWatchers[dir] == nil {
            if let source = makeWatcher(forDirectory: dir) { worktreeWatchers[dir] = source }
        }

        reload()
    }

    private func watchDirectory() {
        watcherSource?.cancel()
        watcherSource = makeWatcher(forDirectory: tasksDirectory)
    }

    /// Debounced watcher on `directory` (nil when it doesn't exist yet — it gets created on first
    /// write, which re-arms the central watcher via `write`). Delegates to the shared
    /// `ClaudeSessionFiles.makeWatcher`, whose broad event mask catches the atomic write-then-rename
    /// an in-worktree agent uses when it edits `TASK.md`.
    private func makeWatcher(forDirectory directory: String) -> DispatchSourceFileSystemObject? {
        ClaudeSessionFiles.makeWatcher(path: directory) { [weak self] in
            self?.scheduleReload()
        }
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
