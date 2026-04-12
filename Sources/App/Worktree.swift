import Foundation
import GhosttyKit
import SwiftUI

// MARK: - Model

/// A worktree entry parsed from `git worktree list --porcelain`.
struct Worktree: Identifiable, Hashable {
    var id: String { path ?? branch ?? "" }

    let branch: String?
    let path: String?
    let isMain: Bool

    var displayName: String { branch ?? "(detached)" }

    /// Sort worktrees: main first, then open (by open order), then closed (alphabetical).
    static func sorted(_ worktrees: [Worktree], openIds: [String]) -> [Worktree] {
        let openOrder = Dictionary(uniqueKeysWithValues: openIds.enumerated().map { ($1, $0) })
        return worktrees.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            let aIdx = openOrder[a.id]
            let bIdx = openOrder[b.id]
            if let ai = aIdx, let bi = bIdx { return ai < bi }
            if (aIdx == nil) != (bIdx == nil) { return aIdx != nil }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }
}

// MARK: - PR Status

/// PR information fetched from `gh pr list` for a worktree's branch.
struct PRStatus: Equatable {
    let number: Int
    let title: String
    let url: String
}

enum PRFetchState: Equatable {
    case loading
    case result(PRStatus?)
}

// MARK: - Manager

/// Manages worktree listing and actions for a single project directory.
///
/// Each window creates its own `WorktreeManager` scoped to one project path.
@MainActor
class WorktreeManager: ObservableObject {
    let projectPath: String
    @Published var worktrees: [Worktree] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastCreatedBranch: String?
    /// Titles read from Claude Code session JSONL files, keyed by worktree path.
    @Published var worktreeTitles: [String: String] = [:]
    /// PR fetch state for worktrees, keyed by worktree ID.
    @Published var worktreePRStates: [String: PRFetchState] = [:]

    private nonisolated static let claudeDir: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }()

    private var backgroundRefreshTask: Task<Void, Never>?
    private var titleWatcherSources: [DispatchSourceFileSystemObject] = []
    private var pendingTitleReload: Task<Void, Never>?
    private var currentTitleWatchPath: String?

    init(projectPath: String) {
        self.projectPath = projectPath
        refresh()
    }

    nonisolated deinit {
        backgroundRefreshTask?.cancel()
        pendingTitleReload?.cancel()
        for source in titleWatcherSources { source.cancel() }
    }

    func refresh(showLoading: Bool = true) {
        let projectPath = self.projectPath
        if showLoading { isLoading = true }
        error = nil

        Task.detached { [weak self] in
            do {
                let (wts, titles) = try await Self.fetchWorktreesAndTitles(in: projectPath)
                await MainActor.run { [weak self] in
                    self?.applyWorktreeRefresh(wts, titles: titles)
                    if self?.isLoading == true { self?.isLoading = false }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.error = error.localizedDescription
                    self?.worktrees = []
                    self?.isLoading = false
                }
            }
        }
    }

    private nonisolated static func fetchWorktreesAndTitles(in directory: String) async throws -> ([Worktree], [String: String]) {
        let wts = try await fetchWorktrees(in: directory)
        let titles = fetchTitles(for: wts)
        return (wts, titles)
    }

    private func applyWorktreeRefresh(_ worktrees: [Worktree], titles: [String: String]) {
        if worktrees != self.worktrees { self.worktrees = worktrees }
        if titles != self.worktreeTitles { self.worktreeTitles = titles }
    }

    // MARK: - Titles (from Claude Code sessions)

    /// Returns the subtitle to display for a worktree.
    /// Only non-main worktrees show session titles.
    func subtitle(for worktree: Worktree) -> String? {
        guard !worktree.isMain, let path = worktree.path, let title = worktreeTitles[path] else { return nil }
        return title
    }

    /// Reads Claude Code session titles for all current worktrees and updates `worktreeTitles`.
    func loadTitles() {
        let worktrees = self.worktrees
        Task.detached { [weak self] in
            let titles = Self.fetchTitles(for: worktrees)
            await MainActor.run { [weak self] in
                if titles != self?.worktreeTitles {
                    self?.worktreeTitles = titles
                }
            }
        }
    }

    /// Reads Claude Code session titles for the given worktrees off the main thread.
    nonisolated static func fetchTitles(for worktrees: [Worktree]) -> [String: String] {
        var titles: [String: String] = [:]
        for wt in worktrees where !wt.isMain {
            guard let path = wt.path else { continue }
            if let title = readClaudeSessionTitle(forWorktreePath: path) {
                titles[path] = title
            }
        }
        return titles
    }

    /// Watches Claude Code session files for title changes for the given worktree path.
    /// Pass `nil` to stop watching.
    func watchTitle(forWorktreePath worktreePath: String?) {
        stopWatchingTitles()

        guard let worktreePath else { return }

        currentTitleWatchPath = worktreePath

        // Read the current value in the background — JSONL files can be large (100MB+),
        // so reading them on the main thread causes visible UI freezes.
        Task.detached { [weak self] in
            let title = Self.readClaudeSessionTitle(forWorktreePath: worktreePath)
            await MainActor.run { [weak self] in
                guard self?.currentTitleWatchPath == worktreePath else { return }
                self?.applyTitle(title, for: worktreePath)
            }
        }

        watchClaudeSessionDirectory(forWorktreePath: worktreePath)
    }

    /// Encodes a filesystem path to Claude Code's project directory name format.
    /// `/Users/foo/bar` → `-Users-foo-bar`
    nonisolated static func encodePathForClaude(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Returns the Claude Code projects directory for a worktree path.
    private nonisolated static func claudeProjectDir(forWorktreePath path: String) -> String {
        (claudeDir as NSString)
            .appendingPathComponent("projects")
            .appending("/\(encodePathForClaude(path))")
    }

    /// Reads the most recent `custom-title` from Claude Code session JSONL files for a worktree.
    nonisolated static func readClaudeSessionTitle(forWorktreePath worktreePath: String) -> String? {
        let projectDir = claudeProjectDir(forWorktreePath: worktreePath)
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: projectDir) else { return nil }

        // Sort by modification date (most recent first), return first title found
        let sorted = contents
            .filter { $0.hasSuffix(".jsonl") }
            .compactMap { file -> (path: String, mod: Date)? in
                let path = (projectDir as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mod = attrs[.modificationDate] as? Date else { return nil }
                return (path, mod)
            }
            .sorted { $0.mod > $1.mod }

        for (path, _) in sorted {
            if let title = readCustomTitle(fromJSONL: path) {
                return title
            }
        }
        return nil
    }

    /// Parses a Claude Code session JSONL file for the last `custom-title` entry.
    private nonisolated static func readCustomTitle(fromJSONL path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }

        // Last matching line wins (user may have renamed multiple times)
        var title: String?
        for line in content.split(separator: "\n") {
            guard line.contains("\"custom-title\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String, type == "custom-title",
                  let customTitle = json["customTitle"] as? String,
                  !customTitle.isEmpty else { continue }
            title = customTitle
        }
        return title
    }

    private func stopWatchingTitles() {
        currentTitleWatchPath = nil
        pendingTitleReload?.cancel()
        pendingTitleReload = nil
        for source in titleWatcherSources { source.cancel() }
        titleWatcherSources = []
    }

    /// Watches the Claude Code projects directory for changes to session JSONL files.
    private func watchClaudeSessionDirectory(forWorktreePath worktreePath: String) {
        let projectDir = Self.claudeProjectDir(forWorktreePath: worktreePath)

        // Watch the projects directory for new session files
        if let source = Self.makeTitleWatcher(path: projectDir, handler: { [weak self] in
            self?.scheduleTitleReload(forWorktreePath: worktreePath, rebuildWatchers: true)
        }) {
            titleWatcherSources.append(source)
        }

        // Watch individual JSONL files for title changes — directory read + N open() calls
        // moved to background to avoid blocking the main thread in large projects.
        Task.detached { [weak self] in
            let fm = FileManager.default
            let contents = (try? fm.contentsOfDirectory(atPath: projectDir)) ?? []
            var newSources: [DispatchSourceFileSystemObject] = []
            for file in contents where file.hasSuffix(".jsonl") {
                let filePath = (projectDir as NSString).appendingPathComponent(file)
                if let source = Self.makeTitleWatcher(path: filePath, eventMask: [.write, .extend], handler: { [weak self] in
                    self?.scheduleTitleReload(forWorktreePath: worktreePath, rebuildWatchers: false)
                }) {
                    newSources.append(source)
                }
            }
            await MainActor.run { [weak self, newSources] in
                guard let self, self.currentTitleWatchPath == worktreePath else {
                    for source in newSources { source.cancel() }
                    return
                }
                self.titleWatcherSources.append(contentsOf: newSources)
            }
        }
    }

    private nonisolated func scheduleTitleReload(forWorktreePath worktreePath: String, rebuildWatchers: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingTitleReload?.cancel()
            self.pendingTitleReload = Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                // Read off main — JSONL files can be large during active sessions.
                let title = Self.readClaudeSessionTitle(forWorktreePath: worktreePath)
                await MainActor.run { [weak self] in
                    guard let self, self.currentTitleWatchPath == worktreePath else { return }
                    self.applyTitle(title, for: worktreePath)
                    if rebuildWatchers {
                        self.stopWatchingTitles()
                        self.currentTitleWatchPath = worktreePath
                        self.watchClaudeSessionDirectory(forWorktreePath: worktreePath)
                    }
                }
            }
        }
    }

    private nonisolated static func makeTitleWatcher(
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

    private func applyTitle(_ title: String?, for worktreePath: String) {
        if let title {
            worktreeTitles[worktreePath] = title
        } else {
            worktreeTitles.removeValue(forKey: worktreePath)
        }
    }

    // MARK: - PR Status

    /// Checks PR status for a single worktree (user-initiated).
    func checkPR(for worktreeId: String) {
        guard let wt = worktrees.first(where: { $0.id == worktreeId }),
              let branch = wt.branch,
              worktreePRStates[worktreeId] != .loading else { return }
        worktreePRStates[worktreeId] = .loading
        let projectPath = self.projectPath
        Task.detached { [weak self] in
            let status = await Self.fetchPRStatus(branch: branch, in: projectPath)
            await MainActor.run { [weak self] in
                self?.worktreePRStates[worktreeId] = .result(status)
            }
        }
    }

    /// Schedules a background refresh 5 seconds from now. Call `cancelBackgroundRefresh()`
    /// when the app returns to foreground to abort — avoids stale results overwriting
    /// a foreground refresh. Intentionally never sets `.loading` PR states so cancellation
    /// doesn't leave the UI in a half-loaded state.
    func refreshInBackground(openWorktreeIds: [String]) {
        backgroundRefreshTask?.cancel()
        let projectPath = self.projectPath
        let openIds = Set(openWorktreeIds)
        backgroundRefreshTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }

            // Phase 1: refresh worktree list + titles
            guard let (wts, titles) = try? await Self.fetchWorktreesAndTitles(in: projectPath) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.applyWorktreeRefresh(wts, titles: titles)
            }

            // Phase 2: fetch PR status for each open worktree with a branch
            guard !Task.isCancelled else { return }
            let branchesById = wts.compactMap { wt -> (id: String, branch: String)? in
                guard let branch = wt.branch, openIds.contains(wt.id) else { return nil }
                return (wt.id, branch)
            }
            let prResults = await withTaskGroup(of: (String, PRStatus?).self) { group -> [(String, PRStatus?)] in
                for (id, branch) in branchesById {
                    group.addTask {
                        let status = await Self.fetchPRStatus(branch: branch, in: projectPath)
                        return (id, status)
                    }
                }
                var results: [(String, PRStatus?)] = []
                for await result in group {
                    guard !Task.isCancelled else { return results }
                    results.append(result)
                }
                return results
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                for (id, status) in prResults {
                    self?.worktreePRStates[id] = .result(status)
                }
            }
        }
    }

    /// Cancels any in-flight background refresh.
    func cancelBackgroundRefresh() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
    }

    /// Removes PR data for worktrees that no longer exist.
    func prunePRStatuses(keeping ids: Set<String>) {
        for key in worktreePRStates.keys where !ids.contains(key) {
            worktreePRStates.removeValue(forKey: key)
        }
    }

    // MARK: - Actions

    /// Create a new worktree. Tries to check out an existing local/remote branch first;
    /// if none exists, creates a new branch with `-b`.
    func createWorktree(branch: String, base: String? = nil, fetch: Bool = false) async {
        guard !branch.contains("..") && !branch.hasPrefix("/") && !branch.hasPrefix("-") else {
            self.error = "Invalid branch name"
            return
        }
        if let base, base.contains("..") || base.hasPrefix("/") || base.hasPrefix("-") {
            self.error = "Invalid base branch name"
            return
        }
        let projectPath = self.projectPath
        do {
            if fetch {
                do {
                    _ = try await Task.detached { try await Self.runCommand(["git", "fetch"], in: projectPath) }.value
                } catch {
                    self.error = "Fetch failed: \(error.localizedDescription). Proceeding with local state."
                }
            }
            let worktreePath = (projectPath as NSString).appendingPathComponent(".worktrees/\(branch)")
            // Try checking out an existing branch (local or remote-tracking via --guess-remote)
            let checkedOut = (try? await Task.detached {
                try await Self.runCommand(["git", "worktree", "add", "--guess-remote", worktreePath, branch], in: projectPath)
            }.value) != nil
            // If no existing branch found, create a new one
            if !checkedOut {
                var args = ["git", "worktree", "add", worktreePath, "-b", branch, "--"]
                if let base { args.append(base) }
                _ = try await Task.detached { try await Self.runCommand(args, in: projectPath) }.value
            }

            let wts = try await Task.detached { try await Self.fetchWorktrees(in: projectPath) }.value
            self.worktrees = wts
            self.loadTitles()
            self.lastCreatedBranch = branch
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Remove a worktree: `git worktree remove --force --force <path>`
    func removeWorktree(branch: String) {
        let projectPath = self.projectPath
        guard let wt = worktrees.first(where: { $0.branch == branch }),
              let worktreePath = wt.path else {
            self.error = "Could not find path for worktree '\(branch)'"
            return
        }
        worktrees.removeAll { $0.branch == branch }
        Task.detached { [weak self] in
            do {
                try await Self.runCommand(["git", "worktree", "remove", "--force", "--force", worktreePath], in: projectPath)
                _ = try? await Self.runCommand(["git", "branch", "-D", "--", branch], in: projectPath)
            } catch {
                Ghostty.logger.warning("git worktree remove failed: \(error.localizedDescription)")
                do {
                    try FileManager.default.removeItem(atPath: worktreePath)
                    _ = try? await Self.runCommand(["git", "worktree", "prune"], in: projectPath)
                    _ = try? await Self.runCommand(["git", "branch", "-D", "--", branch], in: projectPath)
                } catch {
                    let wts = (try? await Self.fetchWorktrees(in: projectPath)) ?? []
                    await MainActor.run { [weak self] in
                        self?.worktrees = wts
                        self?.error = error.localizedDescription
                    }
                }
            }
        }
    }

    // MARK: - Hooks

    /// Returns the interpolated hook command for the given worktree, or nil if no hook is configured.
    func hookCommand(_ keyPath: KeyPath<ProjectHooks, String>, forBranch branch: String, worktreePath: String) -> String? {
        let hooks = ProjectHooks.load(for: projectPath)
        let context = ProjectHooks.Context(
            branch: branch,
            worktreePath: worktreePath,
            primaryWorktreePath: projectPath
        )
        return hooks.interpolated(keyPath, context: context)
    }

    // MARK: - Process helpers

    /// Parses `git worktree list --porcelain` output into `Worktree` entries.
    nonisolated static func parseWorktreeListOutput(_ output: String) -> [Worktree] {
        let blocks = output.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var worktrees: [Worktree] = []

        for (index, block) in blocks.enumerated() {
            let lines = block.components(separatedBy: "\n")
            var path: String?
            var branch: String?
            var isDetached = false

            for line in lines {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("branch refs/heads/") {
                    branch = String(line.dropFirst("branch refs/heads/".count))
                } else if line == "detached" {
                    isDetached = true
                }
            }

            // Skip entries with no path (shouldn't happen with porcelain output)
            guard path != nil else { continue }

            let isMain = index == 0
            if isDetached { branch = nil }

            worktrees.append(Worktree(branch: branch, path: path, isMain: isMain))
        }

        return worktrees
    }

    private static func fetchWorktrees(in directory: String) async throws -> [Worktree] {
        let data = try await runCommand(["git", "worktree", "list", "--porcelain"], in: directory)
        let output = String(data: data, encoding: .utf8) ?? ""
        return parseWorktreeListOutput(output)
    }

    @discardableResult
    static func runCommand(_ args: [String], in directory: String) async throws -> Data {
        let process = Process()

        // For git commands, use the resolved git path directly — no PATH needed.
        // For everything else (e.g. `gh`), use /usr/bin/env with the resolved PATH.
        if args.first == "git" {
            process.executableURL = URL(fileURLWithPath: GitResolver.resolvedPath)
            process.arguments = Array(args.dropFirst())
            if let execPath = GitResolver.execPath {
                process.environment = ["GIT_EXEC_PATH": execPath]
            }
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.environment = ShellEnvironment.processEnvironment
        }

        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Read pipes before waitUntilExit to avoid deadlock if the subprocess
        // fills the pipe buffer (~64KB) — it would block waiting for the reader
        // while we block waiting for exit.
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrString = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cmd = args.joined(separator: " ")
            throw WorktreeError.commandFailed(cmd, stderr: stderrString)
        }

        return stdoutData
    }

    /// Fetches PR status for a branch via `gh pr list`. Returns nil if no PR found or `gh` unavailable.
    nonisolated static func fetchPRStatus(branch: String, in directory: String) async -> PRStatus? {
        let args = [
            "gh", "pr", "list",
            "--head", branch,
            "--state", "all",
            "--limit", "1",
            "--json", "number,title,url",
        ]
        guard let data = try? await runCommand(args, in: directory) else { return nil }
        guard let prs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let pr = prs.first else { return nil }

        guard let number = pr["number"] as? Int,
              let title = pr["title"] as? String,
              let url = pr["url"] as? String else { return nil }

        return PRStatus(number: number, title: title, url: url)
    }

    enum WorktreeError: LocalizedError {
        case commandFailed(String, stderr: String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let cmd, let stderr):
                if !stderr.isEmpty { return stderr }
                return "Command failed: \(cmd)"
            }
        }
    }
}
