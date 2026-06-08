import Foundation

/// Observes a Claude Code session's JSONL file for a running task.
///
/// Provides two features:
/// 1. **Stall detection**: if the session file hasn't been modified for `timeoutMs`,
///    reports the agent as stalled via the `onStall` callback.
/// 2. **Activity detection**: reports genuinely new session writes via the
///    `onActivity` callback (used to resume a `done` task on new session activity).
///
/// Degrades gracefully — if session files are unavailable or unparseable,
/// the observer does nothing. Process exit detection is the reliable baseline.
@MainActor
class AgentSessionObserver: ObservableObject {
    private var worktreePath: String?
    private var timeoutMs: Int?
    private var watcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var stallTimer: DispatchWorkItem?
    private var sessionDir: String?
    /// Timestamp when observation started — only session files modified after this are considered.
    private var launchTime: Date?
    /// Tracks the last session file and mod date we saw, to avoid spurious onActivity calls.
    private var lastSeenFile: String?
    private var lastSeenModDate: Date?

    var onStall: (() -> Void)?
    /// Called when genuinely new session JSONL activity is detected.
    /// Used to detect manually-started Claude sessions in a task's worktree.
    var onActivity: (() -> Void)?
    private var isStalled = false

    init() {}

    nonisolated deinit {
        pendingReload?.cancel()
        stallTimer?.cancel()
        watcherSource?.cancel()
    }

    /// Start observing sessions for the given worktree path.
    /// Stall detection only activates when `timeoutMs` is provided.
    func startObserving(worktreePath: String, timeoutMs: Int? = nil) {
        stopObserving()
        self.worktreePath = worktreePath
        self.timeoutMs = timeoutMs
        self.launchTime = Date()

        sessionDir = ClaudeSessionFiles.projectDir(forWorktreePath: worktreePath)

        reload()
        watchSessionDirectory()
        if timeoutMs != nil { resetStallTimer() }
    }

    func stopObserving() {
        pendingReload?.cancel()
        pendingReload = nil
        stallTimer?.cancel()
        stallTimer = nil
        watcherSource?.cancel()
        watcherSource = nil
        worktreePath = nil
        sessionDir = nil
        launchTime = nil
        lastSeenFile = nil
        lastSeenModDate = nil
        isStalled = false
    }

    // MARK: - Session File Discovery

    /// Finds the most recently modified JSONL file created after our launch time.
    /// This pins us to the session we launched rather than picking up old sessions.
    private func findLatestSessionFile() -> (path: String, modDate: Date)? {
        guard let sessionDir, let launchTime else { return nil }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: sessionDir) else { return nil }

        var latest: (path: String, modDate: Date)?
        for file in contents where file.hasSuffix(".jsonl") {
            let path = (sessionDir as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate > launchTime else { continue }
            if latest == nil || modDate > latest!.modDate {
                latest = (path, modDate)
            }
        }
        return latest
    }

    // MARK: - Activity Detection

    private func reload() {
        guard let session = findLatestSessionFile() else { return }

        // Only fire onActivity for genuinely new writes (new file or updated mod date)
        let isNewActivity = session.path != lastSeenFile || session.modDate != lastSeenModDate
        lastSeenFile = session.path
        lastSeenModDate = session.modDate
        if isNewActivity { onActivity?() }
    }

    // MARK: - Stall Detection

    private func resetStallTimer() {
        stallTimer?.cancel()
        guard let timeoutMs else { return }
        isStalled = false

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.worktreePath != nil else { return }
                self.isStalled = true
                self.onStall?()
            }
        }
        stallTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(timeoutMs),
            execute: work
        )
    }

    // MARK: - File Watching

    private func watchSessionDirectory() {
        watcherSource?.cancel()
        watcherSource = nil

        guard let sessionDir else { return }
        // Reuse the shared watcher factory from ClaudeSessionFiles
        watcherSource = ClaudeSessionFiles.makeWatcher(path: sessionDir) { [weak self] in
            self?.scheduleReload()
        }
    }

    private nonisolated func scheduleReload() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.reload()
                self.resetStallTimer()
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
}
