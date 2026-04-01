import Foundation

/// Observes a Claude Code session's JSONL file for a running task.
///
/// Provides two features:
/// 1. **Stall detection**: if the session file hasn't been modified for `timeoutMs`,
///    reports the agent as stalled via the `onStall` callback.
/// 2. **Token tracking**: parses JSONL entries for usage data and reports
///    cumulative token counts via the `onTokenUpdate` callback.
///
/// Degrades gracefully — if session files are unavailable or unparseable,
/// the observer does nothing. Process exit detection is the reliable baseline.
@MainActor
class AgentSessionObserver: ObservableObject {
    @Published var inputTokens: Int = 0
    @Published var outputTokens: Int = 0

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

        sessionDir = ClaudeTodoManager.projectDir(forWorktreePath: worktreePath)

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

    // MARK: - Token Parsing

    private func reload() {
        guard let session = findLatestSessionFile() else { return }

        // Only fire onActivity for genuinely new writes (new file or updated mod date)
        let isNewActivity = session.path != lastSeenFile || session.modDate != lastSeenModDate
        lastSeenFile = session.path
        lastSeenModDate = session.modDate
        if isNewActivity { onActivity?() }

        let sessionFile = session.path

        // Read full file (learnings: don't tail-only read)
        Task.detached { [weak self] in
            guard let data = FileManager.default.contents(atPath: sessionFile),
                  let content = String(data: data, encoding: .utf8) else { return }

            let (input, output) = Self.parseTokenUsage(from: content)

            await MainActor.run { [weak self] in
                guard let self else { return }
                if input > 0, input != self.inputTokens { self.inputTokens = input }
                if output > 0, output != self.outputTokens { self.outputTokens = output }
            }
        }
    }

    /// Parses cumulative token usage from JSONL content.
    /// Looks for entries with `costUSD` or usage-related fields.
    /// Best-effort — returns (0, 0) if nothing found.
    nonisolated static func parseTokenUsage(from content: String) -> (input: Int, output: Int) {
        var totalInput = 0
        var totalOutput = 0

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Quick check: skip lines without token-related fields
            guard trimmed.contains("\"input_tokens\"") || trimmed.contains("\"output_tokens\"") else { continue }

            // Simple JSON field extraction without full parsing
            if let input = extractInt(from: trimmed, regex: inputTokensRegex) {
                totalInput += input
            }
            if let output = extractInt(from: trimmed, regex: outputTokensRegex) {
                totalOutput += output
            }
        }

        return (totalInput, totalOutput)
    }

    // Pre-compiled regex patterns for token extraction
    private nonisolated static let inputTokensRegex = try! NSRegularExpression(pattern: "\"input_tokens\"\\s*:\\s*(\\d+)")
    private nonisolated static let outputTokensRegex = try! NSRegularExpression(pattern: "\"output_tokens\"\\s*:\\s*(\\d+)")

    /// Extracts an integer value for a JSON field using a pre-compiled regex.
    private nonisolated static func extractInt(from json: String, regex: NSRegularExpression) -> Int? {
        guard let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else { return nil }
        return Int(json[range])
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
        // Reuse existing watcher factory from ClaudeTodoManager
        watcherSource = ClaudeTodoManager.makeWatcher(path: sessionDir) { [weak self] in
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
