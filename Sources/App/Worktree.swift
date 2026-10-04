import Foundation

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

    /// The live worktrees that carry a task, in the shape `WorkTaskManager.worktreeResolver`
    /// expects; every window that wires the task manager points its resolver here.
    func taskResolverPairs() -> [(branch: String, path: String)] {
        Worktree.taskCarriers(worktrees)
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
        guard !branch.contains("..") && !branch.hasPrefix("/") && !branch.hasPrefix("-") else {
            self.error = "Invalid branch name"
            return nil
        }
        if let base, base.contains("..") || base.hasPrefix("/") || base.hasPrefix("-") {
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

    /// Remove a worktree: `git worktree remove --force --force <path>`
    func removeWorktree(branch: String) {
        let projectPath = self.projectPath
        guard let wt = worktrees.first(where: { $0.branch == branch }),
              let worktreePath = wt.path else {
            self.error = "Could not find path for worktree '\(branch)'"
            return
        }
        guard wt.canRemove else {
            self.error = "Cannot remove worktree while HEAD is not attached (git operation in progress)"
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
    func hookCommand(_ keyPath: KeyPath<WorktreeHooks, String>, forBranch branch: String, worktreePath: String) -> String? {
        let hooks = WorktreeHooks.load(for: projectPath)
        let context = WorktreeHooks.Context(
            branch: branch,
            worktreePath: worktreePath,
            primaryWorktreePath: projectPath
        )
        return hooks.interpolated(keyPath, context: context)
    }

    // MARK: - Process helpers

    private static func fetchWorktrees(in directory: String) async throws -> [Worktree] {
        let data = try await runCommand(["git", "worktree", "list", "--porcelain"], in: directory)
        let output = String(data: data, encoding: .utf8) ?? ""
        return Worktree.applyHeadResolution(to: Worktree.parseList(output))
    }

    @discardableResult
    nonisolated static func runCommand(_ args: [String], in directory: String) async throws -> Data {
        let process = Process()

        // For git commands, use the resolved git path directly.
        // For everything else (e.g. `gh`), use /usr/bin/env with the resolved PATH. Neither
        // branch starts a resolution: the shell can open an approval browser, so that trigger
        // belongs on an agent launch, not on a subprocess spawn.
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
            throw WorktreeError.commandFailed(cmd, stderr: stderrString, status: process.terminationStatus)
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

    /// A command that ran and exited non-zero. `status` is what lets a caller tell git's
    /// documented "nothing to report" answers — `config --get`/`--list` exit 1, `--unset` exits 5 —
    /// from a genuine failure. A command that could never be spawned throws Foundation's own
    /// error instead, so this case always carries a status git chose.
    enum WorktreeError: LocalizedError {
        case commandFailed(String, stderr: String, status: Int32)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let cmd, let stderr, _):
                if !stderr.isEmpty { return stderr }
                return "Command failed: \(cmd)"
            }
        }
    }
}
