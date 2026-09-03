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
    /// The project root's `.clearway/` directory (parent of `tasks/`). This is where `WORKFLOW.json`
    /// lives, so it's watched separately from `tasks/`: the central watcher is on `tasks/` and the
    /// per-worktree watchers are on each *worktree's* `.clearway/`, none of which see a WORKFLOW.json
    /// add/remove/edit in the project root unless the main worktree happens to be opened. Without this
    /// watcher the cached `isWorkflowJSONProject` gate would go stale on a runtime WORKFLOW.json change.
    private let rootClearwayDirectory: String
    private var watcherSource: DispatchSourceFileSystemObject?
    private var rootClearwayWatcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: ScheduledWork?

    /// `.clearway` watchers for opened worktrees, keyed by the watched directory path. Only
    /// opened worktrees are watched (mirroring the central watcher); closed worktrees are still
    /// loaded by `reload()` but not watched, keeping file-descriptor cost proportional to what's
    /// on screen. Driven from the view layer via `setWatchedWorktrees(_:)`.
    private var worktreeWatchers: [String: DispatchSourceFileSystemObject] = [:]

    /// Per-task-file watchers keyed by absolute path. Directory watchers miss many in-place
    /// content rewrites (agent open/truncate/write of an existing `TASK.md` / `<UUID>.md`);
    /// watching the file inode catches those. Rebuilt after every reload from the pool's paths.
    private var taskFileWatchers: [String: DispatchSourceFileSystemObject] = [:]

    /// Resolves the live worktrees as `(branch, path)` pairs. Injected at construction so the
    /// manager can route a task's file to its worktree (and merge-load every worktree's
    /// `TASK.md`) without taking a hard dependency on `WorktreeManager`. Defaults to empty,
    /// which yields central-only behavior — the shape unit tests exercise.
    var worktreeResolver: @MainActor () -> [(branch: String, path: String)] = { [] }

    /// Invoked after every `reload()` that changes the pool, with the branches of all
    /// worktree-linked tasks. The `WorkTaskCoordinator` sets this to drive the `WORKFLOW.json`
    /// loop engine off the existing debounced `TASK.md` watcher: each changed `TASK.md` re-merges
    /// the pool, then the engine re-evaluates `status` per worktree (idempotent — a no-op when the
    /// written status already equals the running action). Defaults to a no-op so the legacy path
    /// and unit tests are unaffected.
    var onTasksReloaded: @MainActor (_ worktreeBranches: [String]) -> Void = { _ in }

    /// Invoked on **every** `.clearway/` change the watchers see — *unconditionally*, before the
    /// pool-changed / worktree-linked guards that gate `onTasksReloaded`. The coordinator uses this to
    /// refresh its cached `isWorkflowJSONProject` gate + `WorkflowDefinition` cache, which must track a
    /// runtime `WORKFLOW.json` add/remove/edit even when no task changed (the file's presence is what
    /// flips the gate, and that change touches no `TASK.md`). Deliberately decoupled from the engine
    /// advance (`onTasksReloaded`) so a pure no-change reload refreshes the gate without driving a
    /// (would-be-idempotent, but needless) loop re-evaluation. Defaults to a no-op for unit tests.
    var onClearwayChanged: @MainActor () -> Void = { }

    init(projectPath: String) {
        self.projectPath = projectPath
        self.tasksDirectory = (projectPath as NSString).appendingPathComponent(".clearway/tasks")
        self.rootClearwayDirectory = (projectPath as NSString).appendingPathComponent(".clearway")
        reload()
        watchDirectory()
        watchRootClearway()
    }

    /// Absolute path to a branch's live worktree, or nil when the branch has no worktree.
    private func worktreePath(forBranch branch: String) -> String? {
        worktreeResolver().first { $0.branch == branch }?.path
    }

    /// Relocates a task's central `<UUID>.md` into its now-live worktree as `TASK.md`, preserving
    /// the file's creation date via `FileManager.moveItem` (never copy+delete). The move happens
    /// only when the worktree slot is empty (no `TASK.md` yet); if one already exists the central
    /// file is left **untouched** — a worktree `TASK.md` (even an empty shadow) must never cost the
    /// user the real central task. Idempotent: a no-op when the central file is already gone. The
    /// `id` is carried into the moved file (injected for legacy files), so identity survives the
    /// rename. Re-merges the pool afterward.
    func relocateTaskToWorktree(id: UUID, worktreePath: String) {
        moveCentralFileIntoWorktree(id: id, worktreePath: worktreePath)
        reload()
    }

    /// The file move itself, without a re-merge — the caller reloads. See `relocateTaskToWorktree`
    /// for the contract (move only into an empty worktree slot, never delete the central file on
    /// collision, creation-date preservation).
    private func moveCentralFileIntoWorktree(id: UUID, worktreePath: String) {
        let fm = FileManager.default
        let central = (tasksDirectory as NSString).appendingPathComponent("\(id.uuidString).md")
        guard fm.fileExists(atPath: central) else { return }

        let destination = Self.taskMarkdownPath(inWorktree: worktreePath)
        // Adopt the central file only into an empty slot. If the worktree already has a TASK.md,
        // leave the central file in place — NEVER delete it to resolve a collision. The merge-load
        // dedups by id, so at worst the task is shown once; at best the user keeps their data.
        guard !fm.fileExists(atPath: destination) else { return }

        let clearway = (destination as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: clearway, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.moveItem(atPath: central, toPath: destination)
        // Legacy files carried identity in the filename (`<UUID>.md`), which the rename to
        // `TASK.md` discards. Inject the id into the moved file's frontmatter so identity
        // survives — otherwise the next reload, having no filename UUID and no frontmatter id,
        // would skip it (see `reload`) and the task would vanish.
        ensureFrontmatterID(id, atPath: destination)
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
        watcherSource?.cancel()
        rootClearwayWatcherSource?.cancel()
        worktreeWatchers.values.forEach { $0.cancel() }
        taskFileWatchers.values.forEach { $0.cancel() }
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
        var shadow = WorkTask(title: "", status: WorkTask.ReservedStatus.inProgress, worktree: branch)
        shadow.hidden = true
        write(shadow)
        reload()
        return tasks.first { $0.id == shadow.id }
    }

    /// Flips a hidden task to visible and persists. No-op when already exposed.
    @discardableResult
    func expose(_ task: WorkTask) -> WorkTask {
        guard task.hidden else { return task }
        return updateFields(id: task.id) { $0.hidden = false } ?? task
    }

    /// Creates an exposed task linked to `branch` — used by the aside CTA when a worktree
    /// has no linked task at all (e.g. pre-change worktrees).
    @discardableResult
    func createExposedTask(forBranch branch: String) -> WorkTask? {
        if let existing = task(forWorktree: branch) {
            return existing.hidden ? expose(existing) : existing
        }
        // Same defaults as shadow tasks: in-progress, empty title (the editor fills it in).
        let task = WorkTask(title: "", status: WorkTask.ReservedStatus.inProgress, worktree: branch)
        write(task)
        reload()
        return tasks.first { $0.id == task.id }
    }

    /// Loads the current on-disk task for `id`, falling back to the in-memory pool entry.
    /// Field writers and Start Now use this so a stale caller snapshot never becomes the
    /// serialization base when disk is newer.
    func freshTask(id: UUID) -> WorkTask? {
        if let pooled = tasks.first(where: { $0.id == id }) {
            return loadTask(atPath: filePath(for: pooled), fallbackId: id, requireFrontmatterID: false)
                ?? pooled
        }
        let central = (tasksDirectory as NSString).appendingPathComponent("\(id.uuidString).md")
        return loadTask(atPath: central, fallbackId: id)
    }

    /// Re-bases from disk/pool by id, applies `mutate`, and writes only when something changed.
    /// Sole public mutation path for existing tasks — callers cannot pass a full snapshot that
    /// would clobber fresher title/body/status on disk.
    @discardableResult
    func updateFields(id: UUID, mutate: (inout WorkTask) -> Void) -> WorkTask? {
        guard var base = freshTask(id: id) else { return nil }
        let before = base
        mutate(&base)
        guard base != before else { return base }
        persist(base)
        return base
    }

    /// Applies an editor buffer's parsed form to the persisted task. System-managed fields
    /// (`worktree`, `status`, `attempt`, timestamps) are owned by
    /// `WorkTaskCoordinator` and state commands — editor buffers never overwrite them, which
    /// is what prevents a stale buffer from clobbering a concurrent coordinator write.
    /// Re-bases those fields from disk (via `freshTask`) so a lagging pool cannot re-publish
    /// a pre-agent status/title over a newer file either.
    /// Returns `false` if the buffer has unparseable frontmatter.
    @discardableResult
    func applyEditorBuffer(_ content: String, expectedId: UUID) -> Bool {
        let existing = freshTask(id: expectedId)
        guard let parsed = WorkTask.parse(
            from: content,
            id: expectedId,
            createdAt: existing?.createdAt ?? Date()
        ) else {
            return false
        }
        if existing != nil {
            updateFields(id: expectedId) {
                $0.title = parsed.title
                $0.body = parsed.body
            }
        } else {
            // Novel id (not on disk/pool yet) — no prior document to clobber.
            persist(parsed)
        }
        return true
    }

    /// Writes a fully resolved task and updates the pool. Private so callers cannot supply a
    /// stale full snapshot; use `updateFields` (re-base + mutate) for existing tasks.
    private func persist(_ task: WorkTask) {
        write(task)
        // Update in-memory so callers see immediate changes without
        // waiting for the watcher reload.
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
            // Path may change (e.g. worktree just linked); keep per-file watchers in sync.
            syncTaskFileWatchers()
        } else {
            // New id not yet in the pool (e.g. applyEditorBuffer novel insert) — re-merge so
            // subsequent freshTask/updateFields can resolve it. `reload` also re-syncs watchers.
            reload()
        }
    }

    func setStatus(_ task: WorkTask, to status: String) {
        updateFields(id: task.id) { $0.status = status }
    }

    /// Reads a worktree task's `status` **fresh from its `TASK.md` on disk**, bypassing the
    /// in-memory pool — which lags disk by the watcher's debounce. Used by the engine's
    /// pause-on-agent-death check (`pauseIfAgentDiedMidStep`) to distinguish "the agent died
    /// mid-step" (disk status still equals the action that was running) from "the agent wrote its
    /// advance and exited before the debounced reload landed" (disk status already moved on). The
    /// read is race-free for that purpose: a process that has already exited can't write afterwards.
    /// `nil` when the branch has no live worktree or its `TASK.md` doesn't parse.
    func freshStatus(forWorktree branch: String) -> String? {
        guard let path = worktreePath(forBranch: branch) else { return nil }
        return loadTask(
            atPath: Self.taskMarkdownPath(inWorktree: path),
            fallbackId: UUID(),
            requireFrontmatterID: false
        )?.status
    }

    /// Writes the `autopilot` flag into the task's `.clearway/TASK.md` (the single field-write
    /// path the task aside's autopilot row drives). Clearway is the writer for this field; the
    /// loop engine's watcher then enacts the flip (enable → resume, disable → pause). Unlike
    /// `status`, `autopilot` is Clearway-owned, so this write is allowed. No-op on no change.
    func setAutopilot(_ task: WorkTask, to autopilot: Bool) {
        updateFields(id: task.id) { $0.autopilot = autopilot }
    }

    /// Forces a merge-load from disk into the pool. Production relies on watchers; tests use
    /// this to assert adoption without waiting on debounce timing.
    func reloadFromDisk() {
        reload()
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
            return Self.taskMarkdownPath(inWorktree: path)
        }
        return (tasksDirectory as NSString).appendingPathComponent("\(task.id.uuidString).md")
    }

    /// `.clearway/TASK.md` under a worktree root.
    private static func taskMarkdownPath(inWorktree worktreePath: String) -> String {
        let clearway = (worktreePath as NSString).appendingPathComponent(".clearway")
        return (clearway as NSString).appendingPathComponent("TASK.md")
    }

    private func write(_ task: WorkTask) {
        let fm = FileManager.default
        let path = filePath(for: task)
        let directory = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = task.serialized().data(using: .utf8) else { return }
        fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        if watcherSource == nil { watchDirectory() }
        // A central-backlog write creates `.clearway/` if it was absent; re-arm the root watcher so a
        // later WORKFLOW.json drop in a brand-new project is still seen (same re-arm the central
        // watcher does above). Cheap no-op once armed.
        if rootClearwayWatcherSource == nil { watchRootClearway() }
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
            let taskMd = Self.taskMarkdownPath(inWorktree: worktree.path)
            if let task = loadTask(atPath: taskMd, fallbackId: UUID(), requireFrontmatterID: true) {
                byId[task.id] = task
            }
        }

        // Refresh the coordinator's cached WORKFLOW.json gate on *every* reload — unconditionally,
        // before the pool-changed guard below. A WORKFLOW.json add/remove/edit changes no `TASK.md`,
        // so it never trips the `sorted != tasks` guard; firing here (decoupled from the engine
        // advance in `onTasksReloaded`) is what keeps the gate from going stale on a runtime change.
        onClearwayChanged()

        // Newest first
        let sorted = byId.values.sorted { $0.createdAt > $1.createdAt }
        // Always re-arm per-file watchers — even on a no-op content reload an atomic rewrite can
        // replace the inode under a path, leaving a dead file watcher if we only sync on change.
        let poolChanged = sorted != tasks
        if poolChanged {
            tasks = sorted
        }
        syncTaskFileWatchers()

        guard poolChanged else { return }

        // Drive the loop engine off the same reload the watcher already debounces. Only worktree-
        // linked tasks can be in a running loop, so that's the set the engine re-evaluates.
        let branches = sorted.compactMap(\.worktree)
        if !branches.isEmpty { onTasksReloaded(branches) }
    }

    /// Watches each known task file so in-place content edits fire a reload. Directory watchers
    /// alone miss many agent write patterns (open + truncate + write of an existing path).
    ///
    /// Always re-opens every desired path: `DispatchSource` holds an fd on a specific inode, and
    /// an atomic rewrite (write-to-temp → rename) replaces that inode under the same path. Keeping
    /// the old source keyed by path leaves a **dead** watcher that never sees later writes — the
    /// failure mode that left the pool/UI on a stale `status` after an external frontmatter edit.
    private func syncTaskFileWatchers() {
        let desired = desiredTaskFileWatcherPaths()

        for (path, source) in taskFileWatchers where !desired.contains(path) {
            source.cancel()
            taskFileWatchers.removeValue(forKey: path)
        }
        for path in desired {
            taskFileWatchers[path]?.cancel()
            if let source = makeTaskFileWatcher(path: path) {
                taskFileWatchers[path] = source
            } else {
                taskFileWatchers.removeValue(forKey: path)
            }
        }
    }

    /// File watcher that re-arms itself on each event before the debounced reload. Needed because
    /// a rename/delete event invalidates the current fd; without an immediate re-open, a second
    /// write during the 0.3s debounce (or after a no-op reload path) would be missed.
    private func makeTaskFileWatcher(path: String) -> DispatchSourceFileSystemObject? {
        ClaudeSessionFiles.makeWatcher(path: path) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Re-open this path if still desired; the event may have been the atomic replace
                // that killed the previous inode.
                if self.desiredTaskFileWatcherPaths().contains(path) {
                    self.taskFileWatchers[path]?.cancel()
                    if let source = self.makeTaskFileWatcher(path: path) {
                        self.taskFileWatchers[path] = source
                    } else {
                        self.taskFileWatchers.removeValue(forKey: path)
                    }
                }
            }
            self?.scheduleReload()
        }
    }

    /// Pool paths plus any on-disk task files not yet merged (mid-create / unparsed).
    private func desiredTaskFileWatcherPaths() -> Set<String> {
        var desired = Set(tasks.map { filePath(for: $0) })
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tasksDirectory) {
            for file in files where file.hasSuffix(".md") {
                desired.insert((tasksDirectory as NSString).appendingPathComponent(file))
            }
        }
        for worktree in worktreeResolver() {
            let taskMd = Self.taskMarkdownPath(inWorktree: worktree.path)
            if FileManager.default.fileExists(atPath: taskMd) {
                desired.insert(taskMd)
            }
        }
        return desired
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
            if let source = makeWatcher(forPath: dir) { worktreeWatchers[dir] = source }
        }

        reload()
    }

    private func watchDirectory() {
        watcherSource?.cancel()
        watcherSource = makeWatcher(forPath: tasksDirectory)
    }

    /// Watches the project root's `.clearway/` directory so a `WORKFLOW.json` add/remove/edit fires a
    /// reload (which re-runs the always-fired `onClearwayChanged` gate refresh). Reuses the same
    /// debounced `makeWatcher`/`scheduleReload` pattern as the central watcher — `nil` until the
    /// directory exists, then re-armed from `write` (which creates `.clearway/` on the first task
    /// write) so a project that has no `.clearway/` yet still picks one up the moment one appears.
    private func watchRootClearway() {
        rootClearwayWatcherSource?.cancel()
        rootClearwayWatcherSource = makeWatcher(forPath: rootClearwayDirectory)
    }

    /// Directory watcher → debounced pool reload. Nil when the path does not exist yet
    /// (re-armed from `write` once the directory appears). Task **files** use
    /// `makeTaskFileWatcher` so their inodes re-arm after atomic replace.
    private func makeWatcher(forPath path: String) -> DispatchSourceFileSystemObject? {
        ClaudeSessionFiles.makeWatcher(path: path) { [weak self] in
            self?.scheduleReload()
        }
    }

    private nonisolated func scheduleReload() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.reload()
            }
            self.pendingReload = ScheduledWork(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
}
