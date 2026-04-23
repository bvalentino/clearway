import Foundation
import GhosttyKit

// MARK: - Model

enum HeadStatus {
    case attached
    case rebasing
    case bisecting
    case detached
}

/// A worktree entry parsed from `git worktree list --porcelain`.
struct Worktree: Identifiable, Hashable {
    /// Stable per-worktree id. For non-main worktrees this is the last component of the
    /// resolved gitdir (e.g. `.git/worktrees/foo` → `"foo"`), which git keeps fixed across
    /// `branch -m`, `worktree move`, and `worktree repair`. For main, a fixed sentinel
    /// (`"<main>"`) that never collides with a real gitdir name. When no path is available,
    /// the branch name is used as a last-resort fallback (primarily a test-helper path).
    let id: String

    let branch: String?
    let path: String?
    let isMain: Bool
    let headStatus: HeadStatus

    init(branch: String?, path: String?, isMain: Bool, headStatus: HeadStatus) {
        self.branch = branch
        self.path = path
        self.isMain = isMain
        self.headStatus = headStatus
        if let path {
            self.id = WorktreeManager.worktreeId(isMain: isMain, path: path)
        } else {
            self.id = isMain ? "<main>" : (branch ?? "")
        }
    }

    var displayName: String { branch ?? "(detached)" }

    var canRemove: Bool { headStatus == .attached }
    var canFetchPR: Bool { headStatus == .attached }

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
    /// PR fetch state for worktrees, keyed by worktree ID.
    @Published var worktreePRStates: [String: PRFetchState] = [:]

    init(projectPath: String) {
        self.projectPath = projectPath
        refresh()
    }

    func refresh(showLoading: Bool = true) {
        let projectPath = self.projectPath
        if showLoading { isLoading = true }
        error = nil

        Task.detached { [weak self] in
            do {
                let wts = try await Self.fetchWorktrees(in: projectPath)
                await MainActor.run { [weak self] in
                    self?.applyWorktreeRefresh(wts)
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

    private func applyWorktreeRefresh(_ worktrees: [Worktree]) {
        if worktrees != self.worktrees { self.worktrees = worktrees }
    }

    // MARK: - PR Status

    /// Checks PR status for a single worktree (user-initiated).
    func checkPR(for worktreeId: String) {
        guard let wt = worktrees.first(where: { $0.id == worktreeId }),
              wt.canFetchPR,
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

    /// Removes PR data for worktrees that no longer exist.
    func prunePRStatuses(keeping ids: Set<String>) {
        for key in worktreePRStates.keys where !ids.contains(key) {
            worktreePRStates.removeValue(forKey: key)
        }
    }

    // MARK: - Actions

    /// Create a new worktree. Tries to check out an existing local/remote branch first;
    /// if none exists, creates a new branch with `-b`.
    @discardableResult
    func createWorktree(branch: String, base: String? = nil, fetch: Bool = false) async -> Worktree? {
        guard Self.isValidBranchName(branch) else {
            self.error = "Invalid branch name"
            return nil
        }
        if let base, !Self.isValidBranchName(base) {
            self.error = "Invalid base branch name"
            return nil
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
            let created = wts.first { $0.branch == branch }
            self.worktrees = wts
            self.lastCreatedBranch = branch
            return created
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Rename a branch via `git branch -m <old> <new> --`. On success, refetches
    /// worktrees and returns the refreshed entry; the gitdir-derived `id` is unchanged
    /// so panes, groups, and PR cache survive transparently. On failure, sets
    /// `self.error` and returns nil.
    @discardableResult
    func renameBranch(from oldName: String, to newName: String) async -> Worktree? {
        guard Self.isValidBranchName(oldName) else {
            self.error = "Invalid branch name"
            return nil
        }
        guard Self.isValidBranchName(newName) else {
            self.error = "Invalid branch name"
            return nil
        }
        let projectPath = self.projectPath
        do {
            _ = try await Task.detached {
                try await Self.runCommand(["git", "branch", "-m", oldName, newName, "--"], in: projectPath)
            }.value
            let wts = try await Task.detached { try await Self.fetchWorktrees(in: projectPath) }.value
            self.worktrees = wts
            return wts.first { $0.branch == newName }
        } catch {
            self.error = error.localizedDescription
            return nil
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
        guard wt.canRemove else {
            self.error = "Cannot remove worktree while HEAD is not attached (rebase/bisect in progress)"
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
            let headStatus: HeadStatus = isDetached ? .detached : .attached

            worktrees.append(Worktree(branch: branch, path: path, isMain: isMain, headStatus: headStatus))
        }

        return worktrees
    }

    /// Validates a branch name against the subset of git's rules we care about: rejects
    /// empty strings, any `..` sequence, and leading `/` or `-`. Shared between
    /// `createWorktree` and `renameBranch` so both code paths apply the same checks.
    nonisolated static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.contains("..") { return false }
        if name.hasPrefix("/") { return false }
        if name.hasPrefix("-") { return false }
        return true
    }

    /// Stable per-worktree identifier. For non-main worktrees, the last component of the
    /// resolved gitdir — git keeps this name fixed across `branch -m`, `worktree move`,
    /// and `worktree repair`. For the main worktree, a fixed sentinel so it's unambiguous
    /// and never collides with a real gitdir name. When the gitdir can't be resolved the
    /// path is used as a best-effort fallback, with a warning logged.
    nonisolated static func worktreeId(isMain: Bool, path: String) -> String {
        if isMain { return "<main>" }
        guard let gitdir = gitdir(forWorktreeAt: path) else {
            Ghostty.logger.warning("Worktree.id: unable to resolve gitdir for \(path); falling back to path")
            return path
        }
        return (gitdir as NSString).lastPathComponent
    }

    nonisolated static func gitdir(forWorktreeAt worktreePath: String) -> String? {
        let dotGit = (worktreePath as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let raw = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir: ") else { return nil }
        let pathPart = String(trimmed.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pathPart.isEmpty else { return nil }
        if pathPart.hasPrefix("/") {
            return pathPart
        }
        let base = URL(fileURLWithPath: worktreePath, isDirectory: true)
        return URL(fileURLWithPath: pathPart, relativeTo: base).standardizedFileURL.path
    }

    nonisolated static func branchFromInProgressOp(gitdir: String) -> (branch: String, status: HeadStatus)? {
        let probes: [(String, HeadStatus)] = [
            ("rebase-merge/head-name", .rebasing),
            ("rebase-apply/head-name", .rebasing),
            ("BISECT_START", .bisecting),
        ]
        for (relative, status) in probes {
            let path = (gitdir as NSString).appendingPathComponent(relative)
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("refs/heads/") {
                name = String(name.dropFirst("refs/heads/".count))
            }
            if !name.isEmpty {
                return (name, status)
            }
        }
        return nil
    }

    nonisolated static func applyHeadResolution(to worktrees: [Worktree]) -> [Worktree] {
        worktrees.map { wt in
            guard wt.headStatus == .detached, let path = wt.path else { return wt }
            guard let gitdir = gitdir(forWorktreeAt: path),
                  let recovered = branchFromInProgressOp(gitdir: gitdir) else { return wt }
            return Worktree(
                branch: recovered.branch,
                path: wt.path,
                isMain: wt.isMain,
                headStatus: recovered.status
            )
        }
    }

    static func fetchWorktrees(in directory: String) async throws -> [Worktree] {
        let data = try await runCommand(["git", "worktree", "list", "--porcelain"], in: directory)
        let output = String(data: data, encoding: .utf8) ?? ""
        let parsed = parseWorktreeListOutput(output)
        return applyHeadResolution(to: parsed)
    }

    @discardableResult
    static func runCommand(_ args: [String], in directory: String) async throws -> Data {
        let process = Process()

        // For git commands, use the resolved git path directly.
        // For everything else (e.g. `gh`), use /usr/bin/env with the resolved PATH.
        if args.first == "git" {
            process.executableURL = URL(fileURLWithPath: GitResolver.resolvedPath)
            process.arguments = Array(args.dropFirst())
            var env = ShellEnvironment.processEnvironment
            if let execPath = GitResolver.execPath {
                env["GIT_EXEC_PATH"] = execPath
            }
            process.environment = env
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
