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
        subsystem: Bundle.main.bundleIdentifier ?? "com.wtpad.mac",
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
        var pollWorkItem: DispatchWorkItem?
        var projectDir: String
        /// DispatchSource fires an initial `.write` event on resume for existing
        /// directories. Skip events until this flag is set (after a short delay).
        var ready = false
    }

    private var watchers: [String: WatcherState] = [:] // keyed by worktree id

    nonisolated deinit {
        for (_, state) in watchers {
            state.expiryTimer?.cancel()
            state.pollWorkItem?.cancel()
            state.dirSource?.cancel()
            state.fileSource?.cancel()
        }
    }

    /// Reconcile watchers with the current set of worktrees.
    /// Adds watchers for new worktrees, removes watchers for removed ones.
    func updateWorktrees(_ worktrees: [Worktree]) {
        let currentIds = Set(worktrees.compactMap { $0.path != nil ? $0.id : nil })
        let watchedIds = Set(watchers.keys)

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

        if let source = ClaudeTodoManager.makeWatcher(path: projectDir) { [weak self] in
            self?.handleDirEvent(worktreeId: worktreeId)
        } {
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
        } else {
            // Directory doesn't exist yet — poll for it
            Self.logger.debug("polling for: \(projectDir, privacy: .public)")
            pollForDirectory(worktreeId: worktreeId, path: projectDir)
        }

        watchers[worktreeId] = state
    }

    private func stopWatching(id: String) {
        guard let state = watchers.removeValue(forKey: id) else { return }
        state.dirSource?.cancel()
        state.fileSource?.cancel()
        state.expiryTimer?.cancel()
        state.pollWorkItem?.cancel()
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

    // MARK: - Polling for Missing Directories

    private func pollForDirectory(
        worktreeId: String,
        path: String,
        attempt: Int = 0
    ) {
        guard attempt < 30 else { return }
        watchers[worktreeId]?.pollWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                DispatchQueue.main.async {
                    guard let self, self.watchers[worktreeId] != nil else { return }
                    // Directory appeared — install the real watchers
                    if let source = ClaudeTodoManager.makeWatcher(path: path) { [weak self] in
                        self?.handleDirEvent(worktreeId: worktreeId)
                    } {
                        self.watchers[worktreeId]?.dirSource = source
                        self.watchers[worktreeId]?.fileSource = Self.watchNewestJsonl(
                            in: path, worktreeId: worktreeId, monitor: self
                        )?.source
                        Self.logger.info("poll found dir, watching: \(path, privacy: .public)")
                    }
                    // Mark ready after delay (same as direct path)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.watchers[worktreeId]?.ready = true
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self?.pollForDirectory(
                        worktreeId: worktreeId,
                        path: path,
                        attempt: attempt + 1
                    )
                }
            }
        }
        watchers[worktreeId]?.pollWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
