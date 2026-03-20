import Foundation
import os

/// Monitors Claude Code session activity across all worktrees.
///
/// Watches `~/.claude/projects/<encoded-path>/` for each worktree. When Claude
/// writes to session JSONL files, the worktree is marked as "working." After
/// a period of inactivity the working state expires.
@MainActor
class ClaudeActivityMonitor: ObservableObject {
    @Published var workingWorktreeIds: Set<String> = []

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.wtpad.mac",
        category: "claude-activity"
    )

    /// How long after the last write event before a worktree stops being "working."
    private static let expirySeconds: Double = 5.0

    /// Per-worktree watcher state.
    private struct WatcherState {
        var source: DispatchSourceFileSystemObject?
        var expiryTimer: DispatchWorkItem?
        var pollWorkItem: DispatchWorkItem?
        /// DispatchSource fires an initial `.write` event on resume for existing
        /// directories. Skip events until this flag is set (after a short delay).
        var ready = false
    }

    private var watchers: [String: WatcherState] = [:] // keyed by worktree id

    nonisolated deinit {
        for (_, state) in watchers {
            state.expiryTimer?.cancel()
            state.pollWorkItem?.cancel()
            state.source?.cancel()
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
        var state = WatcherState()

        if let source = ClaudeTodoManager.makeWatcher(path: projectDir) { [weak self] in
            self?.handleActivity(worktreeId: worktreeId)
        } {
            state.source = source
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

        // Check if Claude is already active (file modified recently)
        checkInitialActivity(worktreeId: worktreeId, projectDir: projectDir)
    }

    private func stopWatching(id: String) {
        guard let state = watchers.removeValue(forKey: id) else { return }
        state.source?.cancel()
        state.expiryTimer?.cancel()
        state.pollWorkItem?.cancel()
        if workingWorktreeIds.contains(id) {
            workingWorktreeIds.remove(id)
        }
    }

    // MARK: - Activity Detection

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

    /// Check if any JSONL file was modified recently (within expiry window),
    /// which means Claude was already active when we started watching.
    private func checkInitialActivity(worktreeId: String, projectDir: String) {
        let expirySeconds = Self.expirySeconds
        Task.detached { [weak self] in
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(atPath: projectDir) else { return }

            let now = Date()

            for file in contents where file.hasSuffix(".jsonl") {
                let path = (projectDir as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                if now.timeIntervalSince(modDate) < expirySeconds {
                    await MainActor.run {
                        self?.markWorking(worktreeId: worktreeId)
                    }
                    return
                }
            }
        }
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
                    // Directory appeared — install the real watcher
                    if let source = ClaudeTodoManager.makeWatcher(path: path) { [weak self] in
                        self?.handleActivity(worktreeId: worktreeId)
                    } {
                        self.watchers[worktreeId]?.source = source
                        Self.logger.info("poll found dir, watching: \(path, privacy: .public)")
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
