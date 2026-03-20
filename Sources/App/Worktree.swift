import Foundation
import SwiftUI

// MARK: - Model

/// A worktree entry parsed from `git worktree list --porcelain`.
struct Worktree: Identifiable, Hashable {
    var id: String { path ?? branch ?? "" }

    let branch: String?
    let path: String?
    let isMain: Bool

    var displayName: String { branch ?? "(detached)" }

    /// Sort worktrees: main first, then open (alphabetical), then closed (alphabetical).
    static func sorted(_ worktrees: [Worktree], openIds: Set<String>) -> [Worktree] {
        worktrees.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            let aOpen = openIds.contains(a.id)
            let bOpen = openIds.contains(b.id)
            if aOpen != bOpen { return aOpen }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }
}

// MARK: - PR Status

/// PR state as reported by GitHub.
enum PRState: String, Equatable {
    case open = "OPEN"
    case merged = "MERGED"
    case closed = "CLOSED"

    /// Color matching GitHub's PR state indicators.
    var color: Color {
        switch self {
        case .open: return .green
        case .merged: return .purple
        case .closed: return .red
        }
    }
}

/// PR information fetched from `gh pr list` for a worktree's branch.
struct PRStatus: Equatable {
    let number: Int
    let title: String
    let state: PRState
    let url: String
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
    /// PR status for worktrees, keyed by worktree ID.
    @Published var worktreePRs: [String: PRStatus] = [:]

    /// Tracks when each worktree's PR status was last fetched, keyed by worktree ID.
    private var prFetchDates: [String: Date] = [:]
    /// Cache TTL for PR status fetches.
    private static let prCacheTTL: TimeInterval = 60

    private static let claudeDir: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }()

    private var titleWatcherSources: [DispatchSourceFileSystemObject] = []
    private var pendingTitleReload: DispatchWorkItem?

    init(projectPath: String) {
        self.projectPath = projectPath
        refresh()
    }

    nonisolated deinit {
        pendingTitleReload?.cancel()
        for source in titleWatcherSources { source.cancel() }
    }

    func refresh() {
        let projectPath = self.projectPath
        isLoading = true
        error = nil

        Task.detached { [weak self] in
            do {
                let wts = try await Self.fetchWorktrees(in: projectPath)
                await MainActor.run {
                    self?.worktrees = wts
                    self?.loadTitles()
                    self?.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self?.error = error.localizedDescription
                    self?.worktrees = []
                    self?.isLoading = false
                }
            }
        }
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
        var titles: [String: String] = [:]
        for wt in worktrees where !wt.isMain {
            guard let path = wt.path else { continue }
            if let title = Self.readClaudeSessionTitle(forWorktreePath: path) {
                titles[path] = title
            }
        }
        if titles != worktreeTitles {
            worktreeTitles = titles
        }
    }

    /// Watches Claude Code session files for title changes for the given worktree path.
    /// Pass `nil` to stop watching.
    func watchTitle(forWorktreePath worktreePath: String?) {
        stopWatchingTitles()

        guard let worktreePath else { return }

        // Read the current value immediately
        applyTitle(Self.readClaudeSessionTitle(forWorktreePath: worktreePath), for: worktreePath)

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
        pendingTitleReload?.cancel()
        pendingTitleReload = nil
        for source in titleWatcherSources { source.cancel() }
        titleWatcherSources = []
    }

    /// Watches the Claude Code projects directory for changes to session JSONL files.
    private func watchClaudeSessionDirectory(forWorktreePath worktreePath: String) {
        let projectDir = Self.claudeProjectDir(forWorktreePath: worktreePath)

        // Watch the projects directory for new session files — rebuild watchers when directory changes
        if let source = Self.makeTitleWatcher(path: projectDir) { [weak self] in
            self?.scheduleTitleReload(forWorktreePath: worktreePath, rebuildWatchers: true)
        } {
            titleWatcherSources.append(source)
        }

        // Watch individual JSONL files for title changes within existing sessions
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: projectDir)) ?? []
        for file in contents where file.hasSuffix(".jsonl") {
            let filePath = (projectDir as NSString).appendingPathComponent(file)
            if let source = Self.makeTitleWatcher(path: filePath, eventMask: [.write, .extend]) { [weak self] in
                self?.scheduleTitleReload(forWorktreePath: worktreePath, rebuildWatchers: false)
            } {
                titleWatcherSources.append(source)
            }
        }
    }

    private nonisolated func scheduleTitleReload(forWorktreePath worktreePath: String, rebuildWatchers: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingTitleReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let title = Self.readClaudeSessionTitle(forWorktreePath: worktreePath)
                self.applyTitle(title, for: worktreePath)
                if rebuildWatchers {
                    self.stopWatchingTitles()
                    self.watchClaudeSessionDirectory(forWorktreePath: worktreePath)
                }
            }
            self.pendingTitleReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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

    /// Refreshes PR status for all open, non-main worktrees with branches.
    func refreshPRStatuses(openIds: Set<String>) {
        for wt in worktrees where !wt.isMain && openIds.contains(wt.id) {
            guard let branch = wt.branch else { continue }
            fetchAndApplyPR(id: wt.id, branch: branch)
        }
    }

    /// Refreshes PR status for a single worktree, respecting cache TTL.
    func refreshPRForWorktree(_ id: String) {
        guard let wt = worktrees.first(where: { $0.id == id }),
              !wt.isMain,
              let branch = wt.branch else { return }
        fetchAndApplyPR(id: id, branch: branch)
    }

    /// Clears the PR cache so the next refresh re-fetches all statuses.
    func clearPRCache() {
        prFetchDates.removeAll()
    }

    /// Removes PR data for worktrees that no longer exist.
    func prunePRStatuses(keeping ids: Set<String>) {
        for key in worktreePRs.keys where !ids.contains(key) {
            worktreePRs.removeValue(forKey: key)
            prFetchDates.removeValue(forKey: key)
        }
    }

    private func fetchAndApplyPR(id: String, branch: String) {
        if let lastFetch = prFetchDates[id],
           Date().timeIntervalSince(lastFetch) < Self.prCacheTTL {
            return
        }
        let projectPath = self.projectPath
        prFetchDates[id] = Date()
        Task.detached { [weak self] in
            let status = await Self.fetchPRStatus(branch: branch, in: projectPath)
            await MainActor.run {
                guard let self else { return }
                if self.worktreePRs[id] != status {
                    self.worktreePRs[id] = status
                }
            }
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
                let wts = (try? await Self.fetchWorktrees(in: projectPath)) ?? []
                await MainActor.run {
                    self?.worktrees = wts
                    self?.error = error.localizedDescription
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
    private static func runCommand(_ args: [String], in directory: String) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ShellEnvironment.processEnvironment

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
            "--json", "number,title,state,url",
        ]
        guard let data = try? await runCommand(args, in: directory) else { return nil }
        guard let prs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let pr = prs.first else { return nil }

        guard let number = pr["number"] as? Int,
              let title = pr["title"] as? String,
              let stateRaw = pr["state"] as? String,
              let state = PRState(rawValue: stateRaw),
              let url = pr["url"] as? String else { return nil }

        return PRStatus(number: number, title: title, state: state, url: url)
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
