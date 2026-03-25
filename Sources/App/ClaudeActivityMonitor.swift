import Foundation
import os

/// Monitors Claude Code session activity across all worktrees.
///
/// Watches `~/.claude/projects/<encoded-path>/` for each worktree. A directory
/// watcher detects new session files; a per-file watcher on the most recent
/// JSONL file detects ongoing writes (directory-level `.write` only fires on
/// file creation/deletion, not on content appends).
@MainActor
class ClaudeActivityMonitor: ObservableObject {
    @Published var workingWorktreeIds: Set<String> = []

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.getclearway.mac",
        category: "claude-activity"
    )

    /// How long after the last write event before a worktree stops being "working."
    private static let expirySeconds: Double = 3.0

    /// Per-worktree watcher state.
    private struct WatcherState {
        /// Watches the project directory for new/deleted session files.
        var dirSource: DispatchSourceFileSystemObject?
        /// Watches the most recent JSONL file for content appends.
        var fileSource: DispatchSourceFileSystemObject?
        var expiryTimer: DispatchWorkItem?
        var projectDir: String
        /// DispatchSource fires an initial `.write` event on resume for existing
        /// directories. Skip events until this flag is set (after a short delay).
        var ready = false
    }

    private var watchers: [String: WatcherState] = [:] // keyed by worktree id

    // MARK: - Parent Directory Watcher (for pending worktrees)

    /// Worktrees whose project directory doesn't exist yet. worktreeId → projectDir
    private var pendingWorktrees: [String: String] = [:]
    /// Watches `~/.claude/projects/` for entry changes (subdirectory creation).
    private var parentDirSource: DispatchSourceFileSystemObject?
    /// Fallback poll when `~/.claude/projects/` itself doesn't exist.
    private var parentPollWorkItem: DispatchWorkItem?

    nonisolated deinit {
        for (_, state) in watchers {
            state.expiryTimer?.cancel()
            state.dirSource?.cancel()
            state.fileSource?.cancel()
        }
        parentDirSource?.cancel()
        parentPollWorkItem?.cancel()
    }

    /// Reconcile watchers with the current set of worktrees.
    /// Adds watchers for new worktrees, removes watchers for removed ones.
    func updateWorktrees(_ worktrees: [Worktree]) {
        let currentIds = Set(worktrees.compactMap { $0.path != nil ? $0.id : nil })
        let watchedIds = Set(watchers.keys).union(pendingWorktrees.keys)

        // Remove watchers for worktrees that no longer exist
        for id in watchedIds.subtracting(currentIds) {
            stopWatching(id: id)
        }

        // Add watchers for new worktrees
        for wt in worktrees {
            guard let path = wt.path, !watchedIds.contains(wt.id) else { continue }
            startWatching(worktreeId: wt.id, worktreePath: path)
        }
    }

    // MARK: - Per-Worktree Watching

    private func startWatching(worktreeId: String, worktreePath: String) {
        let projectDir = ClaudeTodoManager.projectDir(forWorktreePath: worktreePath)
        var state = WatcherState(projectDir: projectDir)

        if let source = ClaudeTodoManager.makeWatcher(path: projectDir, handler: { [weak self] in
            self?.handleDirEvent(worktreeId: worktreeId)
        }) {
            state.dirSource = source
            if let result = Self.watchNewestJsonl(
                in: projectDir, worktreeId: worktreeId, monitor: self
            ) {
                state.fileSource = result.source
                // If the newest file was modified recently, Claude is already active
                if Date().timeIntervalSince(result.modDate) < Self.expirySeconds {
                    workingWorktreeIds.insert(worktreeId)
                }
            }
            Self.logger.debug("watching: \(projectDir, privacy: .public)")
            // Mark ready after a short delay so the initial spurious event is ignored
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.watchers[worktreeId]?.ready = true
            }
            watchers[worktreeId] = state
        } else {
            // Directory doesn't exist yet — register as pending and watch parent
            Self.logger.debug("pending: \(projectDir, privacy: .public)")
            watchers[worktreeId] = state
            pendingWorktrees[worktreeId] = projectDir
            ensureParentWatcher()
        }
    }

    /// Installs real watchers for a worktree whose project directory just appeared.
    private func installWatchers(worktreeId: String, projectDir: String) {
        guard watchers[worktreeId] != nil else { return }

        if let source = ClaudeTodoManager.makeWatcher(path: projectDir, handler: { [weak self] in
            self?.handleDirEvent(worktreeId: worktreeId)
        }) {
            watchers[worktreeId]?.dirSource = source
            if let result = Self.watchNewestJsonl(
                in: projectDir, worktreeId: worktreeId, monitor: self
            ) {
                watchers[worktreeId]?.fileSource = result.source
                if Date().timeIntervalSince(result.modDate) < Self.expirySeconds {
                    markWorking(worktreeId: worktreeId)
                }
            }
            Self.logger.info("pending resolved, watching: \(projectDir, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.watchers[worktreeId]?.ready = true
            }
        }
    }

    private func stopWatching(id: String) {
        if let state = watchers.removeValue(forKey: id) {
            state.dirSource?.cancel()
            state.fileSource?.cancel()
            state.expiryTimer?.cancel()
        }
        pendingWorktrees.removeValue(forKey: id)
        if pendingWorktrees.isEmpty {
            tearDownParentWatcher()
        }
        if workingWorktreeIds.contains(id) {
            workingWorktreeIds.remove(id)
        }
    }

    // MARK: - File Watcher

    /// Finds the most recently modified JSONL file and watches it for writes.
    /// Returns the watcher source and the newest file's modification date.
    private nonisolated static func watchNewestJsonl(
        in projectDir: String,
        worktreeId: String,
        monitor: ClaudeActivityMonitor
    ) -> (source: DispatchSourceFileSystemObject, modDate: Date)? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: projectDir) else { return nil }

        var newestPath: String?
        var newestDate: Date = .distantPast

        for file in contents where file.hasSuffix(".jsonl") {
            let path = (projectDir as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mod = attrs[.modificationDate] as? Date else { continue }
            if mod > newestDate {
                newestDate = mod
                newestPath = path
            }
        }

        guard let path = newestPath else { return nil }
        guard let source = ClaudeTodoManager.makeWatcher(path: path, handler: { [weak monitor] in
            monitor?.handleActivity(worktreeId: worktreeId)
        }) else { return nil }
        return (source, newestDate)
    }

    /// Replace the file watcher with one on the current newest JSONL.
    private func rebuildFileWatcher(worktreeId: String) {
        guard let state = watchers[worktreeId] else { return }
        state.fileSource?.cancel()
        watchers[worktreeId]?.fileSource = Self.watchNewestJsonl(
            in: state.projectDir, worktreeId: worktreeId, monitor: self
        )?.source
    }

    // MARK: - Activity Detection

    /// Called when the project directory itself changes (file created/deleted).
    private nonisolated func handleDirEvent(worktreeId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.watchers[worktreeId]?.ready == true else { return }
            // A new session file may have appeared — rewire to the newest one
            self.rebuildFileWatcher(worktreeId: worktreeId)
            self.markWorking(worktreeId: worktreeId)
        }
    }

    /// Called when a JSONL file is written to (Claude actively working).
    private nonisolated func handleActivity(worktreeId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.watchers[worktreeId]?.ready == true else { return }
            self.markWorking(worktreeId: worktreeId)
        }
    }

    private func markWorking(worktreeId: String) {
        if !workingWorktreeIds.contains(worktreeId) {
            workingWorktreeIds.insert(worktreeId)
        }
        resetExpiryTimer(worktreeId: worktreeId)
    }

    private func resetExpiryTimer(worktreeId: String) {
        watchers[worktreeId]?.expiryTimer?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.workingWorktreeIds.contains(worktreeId) else { return }
            self.workingWorktreeIds.remove(worktreeId)
        }
        watchers[worktreeId]?.expiryTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expirySeconds, execute: work)
    }

    // MARK: - Parent Directory Watcher

    /// Ensures a watcher on `~/.claude/projects/` is active to detect when
    /// pending worktree directories are created. Uses a `fileExists` guard per
    /// pending entry to keep the handler cheap despite churn from other sessions.
    private func ensureParentWatcher() {
        guard parentDirSource == nil else { return }

        let parentDir = ClaudeTodoManager.projectsParentDir
        if let source = ClaudeTodoManager.makeWatcher(path: parentDir, handler: { [weak self] in
            self?.checkPendingWorktrees()
        }) {
            parentDirSource = source
            Self.logger.debug("watching parent: \(parentDir, privacy: .public)")
        } else {
            // ~/.claude/projects/ doesn't exist yet — poll for it at a long interval
            Self.logger.debug("parent dir missing, polling: \(parentDir, privacy: .public)")
            pollForParentDirectory()
        }
    }

    /// Checks each pending worktree's project directory. If it now exists,
    /// installs real watchers and removes it from the pending set.
    private nonisolated func checkPendingWorktrees() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var resolved: [String] = []
            for (worktreeId, projectDir) in self.pendingWorktrees {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: projectDir, isDirectory: &isDir),
                   isDir.boolValue {
                    resolved.append(worktreeId)
                    self.installWatchers(worktreeId: worktreeId, projectDir: projectDir)
                }
            }
            for id in resolved {
                self.pendingWorktrees.removeValue(forKey: id)
            }
            if self.pendingWorktrees.isEmpty {
                self.tearDownParentWatcher()
            }
        }
    }

    /// Polls for `~/.claude/projects/` with exponential backoff (10s → 120s cap).
    private func pollForParentDirectory(interval: Double = 10.0) {
        parentPollWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: ClaudeTodoManager.projectsParentDir, isDirectory: &isDir
            ) && isDir.boolValue
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.pendingWorktrees.isEmpty else {
                    self?.parentPollWorkItem = nil
                    return
                }
                if exists {
                    self.parentPollWorkItem = nil
                    self.ensureParentWatcher()
                } else {
                    self.pollForParentDirectory(interval: min(interval * 2, 120))
                }
            }
        }
        parentPollWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func tearDownParentWatcher() {
        parentDirSource?.cancel()
        parentDirSource = nil
        parentPollWorkItem?.cancel()
        parentPollWorkItem = nil
    }
}
