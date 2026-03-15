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
    /// Titles read from `.wtpad/title.txt` in each worktree, keyed by worktree path.
    @Published var worktreeTitles: [String: String] = [:]

    private static let wtpadTitleFile = ".wtpad/title.txt"
    private var titleWatcherSource: DispatchSourceFileSystemObject?
    /// Watches either `.wtpad/` (for title.txt creation) or the worktree root (for `.wtpad/` creation).
    /// Only one is active at a time.
    private var titleDirWatcherSource: DispatchSourceFileSystemObject?

    init(projectPath: String) {
        self.projectPath = projectPath
        refresh()
    }

    nonisolated deinit {
        titleWatcherSource?.cancel()
        titleDirWatcherSource?.cancel()
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

    // MARK: - Titles

    /// Returns the subtitle to display for a worktree.
    /// Uses `.wtpad/title.txt` if available; returns nil otherwise.
    func subtitle(for worktree: Worktree) -> String? {
        guard let path = worktree.path, let title = worktreeTitles[path] else { return nil }
        return title
    }

    /// Reads `.wtpad/title.txt` for all current worktrees and updates `worktreeTitles`.
    func loadTitles() {
        var titles: [String: String] = [:]
        for wt in worktrees {
            guard let path = wt.path else { continue }
            if let title = Self.readTitle(atWorktreePath: path) {
                titles[path] = title
            }
        }
        if titles != worktreeTitles {
            worktreeTitles = titles
        }
    }

    /// Watches `.wtpad/title.txt` (and `.wtpad/` directory for creation) for the given worktree path.
    /// Pass `nil` to stop watching.
    func watchTitle(forWorktreePath worktreePath: String?) {
        titleWatcherSource?.cancel()
        titleWatcherSource = nil
        titleDirWatcherSource?.cancel()
        titleDirWatcherSource = nil

        guard let worktreePath else { return }

        let (titleFile, wtpadDir) = Self.wtpadPaths(for: worktreePath)

        // Read the current value immediately so it's visible before any watcher fires
        applyTitle(Self.readTitle(atWorktreePath: worktreePath), for: worktreePath)

        watchFile(at: titleFile, worktreePath: worktreePath)

        // If .wtpad/ exists, watch it directly; otherwise watch the worktree root
        // to detect when .wtpad/ is created
        if access(wtpadDir, F_OK) == 0 {
            watchDirectory(at: wtpadDir, worktreePath: worktreePath)
        } else {
            watchWorktreeRoot(at: worktreePath)
        }
    }

    private static func wtpadPaths(for worktreePath: String) -> (titleFile: String, directory: String) {
        let titleFile = (worktreePath as NSString).appendingPathComponent(wtpadTitleFile)
        return (titleFile, (titleFile as NSString).deletingLastPathComponent)
    }

    private static func readTitle(atWorktreePath path: String) -> String? {
        let file = wtpadPaths(for: path).titleFile
        guard let fh = FileHandle(forReadingAtPath: file) else { return nil }
        defer { fh.closeFile() }
        let data = fh.readData(ofLength: 1024)
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func watchFile(at path: String, worktreePath: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let flags = source.data
            let title = Self.readTitle(atWorktreePath: worktreePath)
            // File was deleted/renamed — cancel so directory watcher can re-establish
            if flags.contains(.delete) || flags.contains(.rename) {
                source.cancel()
                DispatchQueue.main.async {
                    self?.titleWatcherSource = nil
                    self?.applyTitle(title, for: worktreePath)
                }
                return
            }
            DispatchQueue.main.async {
                self?.applyTitle(title, for: worktreePath)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        titleWatcherSource = source
    }

    private func watchDirectory(at dirPath: String, worktreePath: String) {
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let titleFile = Self.wtpadPaths(for: worktreePath).titleFile
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let title = Self.readTitle(atWorktreePath: worktreePath)
            DispatchQueue.main.async {
                guard let self else { return }
                // If title.txt was just created, set up a file watcher for it
                if self.titleWatcherSource == nil {
                    self.watchFile(at: titleFile, worktreePath: worktreePath)
                }
                self.applyTitle(title, for: worktreePath)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        titleDirWatcherSource = source
    }

    /// Watches the worktree root for `.write` events to detect `.wtpad/` directory creation.
    /// Once `.wtpad/` appears, transitions to the proper directory + file watchers.
    private func watchWorktreeRoot(at worktreePath: String) {
        let fd = open(worktreePath, O_EVTONLY)
        guard fd >= 0 else { return }

        let (titleFile, wtpadDir) = Self.wtpadPaths(for: worktreePath)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard access(wtpadDir, F_OK) == 0 else { return }

            let title = Self.readTitle(atWorktreePath: worktreePath)
            DispatchQueue.main.async {
                guard let self else { return }
                self.titleDirWatcherSource?.cancel()
                self.titleDirWatcherSource = nil
                self.watchFile(at: titleFile, worktreePath: worktreePath)
                self.watchDirectory(at: wtpadDir, worktreePath: worktreePath)
                self.applyTitle(title, for: worktreePath)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        titleDirWatcherSource = source
    }

    private func applyTitle(_ title: String?, for worktreePath: String) {
        if let title {
            worktreeTitles[worktreePath] = title
        } else {
            worktreeTitles.removeValue(forKey: worktreePath)
        }
    }

    // MARK: - Actions

    /// Create a new worktree: `git worktree add .worktrees/<branch> -b <branch> [<base>]`
    func createWorktree(branch: String, base: String? = nil) async {
        guard !branch.contains("..") && !branch.hasPrefix("/") else {
            self.error = "Invalid branch name"
            return
        }
        let projectPath = self.projectPath
        do {
            let worktreePath = (projectPath as NSString).appendingPathComponent(".worktrees/\(branch)")
            var args = ["git", "worktree", "add", worktreePath, "-b", branch]
            if let base { args.append(base) }
            _ = try await Task.detached { try await Self.runCommand(args, in: projectPath) }.value

            let wts = try await Task.detached { try await Self.fetchWorktrees(in: projectPath) }.value
            self.worktrees = wts
            self.loadTitles()
            self.lastCreatedBranch = branch
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Remove a worktree: `git worktree remove --force <path>`
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
                try await Self.runCommand(["git", "worktree", "remove", "--force", worktreePath], in: projectPath)
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
