import Foundation
import SwiftUI

// MARK: - Model

/// A worktree entry from `wt list --format json`.
struct Worktree: Identifiable, Codable, Hashable {
    var id: String { path ?? branch ?? "" }

    let branch: String?
    let path: String?
    let kind: String
    let commit: Commit
    let workingTree: WorkingTree?
    let mainState: String?
    let integrationReason: String?
    let operationState: String?
    let main: MainDivergence?
    let remote: Remote?
    let worktree: WorktreeMeta?
    let ci: CI?
    let isMain: Bool
    let isCurrent: Bool
    let isPrevious: Bool
    let symbols: String?

    enum CodingKeys: String, CodingKey {
        case branch, path, kind, commit, main, remote, worktree, ci, symbols
        case workingTree = "working_tree"
        case mainState = "main_state"
        case integrationReason = "integration_reason"
        case operationState = "operation_state"
        case isMain = "is_main"
        case isCurrent = "is_current"
        case isPrevious = "is_previous"
    }

    struct Commit: Codable, Hashable {
        let sha: String
        let shortSha: String
        let message: String
        let timestamp: Int

        enum CodingKeys: String, CodingKey {
            case sha
            case shortSha = "short_sha"
            case message, timestamp
        }
    }

    struct WorkingTree: Codable, Hashable {
        let staged: Bool
        let modified: Bool
        let untracked: Bool
        let renamed: Bool?
        let deleted: Bool?
        let diff: LineDiff?
    }

    struct LineDiff: Codable, Hashable {
        let added: Int
        let deleted: Int
    }

    struct MainDivergence: Codable, Hashable {
        let ahead: Int
        let behind: Int
        let diff: LineDiff?
    }

    struct Remote: Codable, Hashable {
        let name: String
        let branch: String
        let ahead: Int
        let behind: Int
    }

    struct WorktreeMeta: Codable, Hashable {
        let state: String?
        let reason: String?
        let detached: Bool
    }

    struct CI: Codable, Hashable {
        let status: String
        let source: String?
        let stale: Bool?
        let url: String?

        var statusColor: Color {
            switch status {
            case "passed": return .green
            case "running": return .blue
            case "failed": return .red
            case "conflicts": return .yellow
            case "no-ci": return .gray
            case "error": return .orange
            default: return .gray
            }
        }

        var statusLabel: String {
            switch status {
            case "passed": return "CI passed"
            case "running": return "CI running"
            case "failed": return "CI failed"
            case "conflicts": return "Merge conflicts"
            case "no-ci": return "No CI"
            case "error": return "CI error"
            default: return status
            }
        }
    }

    // MARK: - Computed

    var displayName: String { branch ?? "(detached)" }

    var isDimmed: Bool {
        mainState == "empty" || mainState == "integrated"
    }

    var hasConflicts: Bool {
        operationState == "conflicts"
    }

    var isRebase: Bool {
        operationState == "rebase"
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
    /// Uses `.wtpad/title.txt` if available; falls back to commit message (empty for main).
    func subtitle(for worktree: Worktree) -> String? {
        if let path = worktree.path, let title = worktreeTitles[path] {
            return title
        }
        if worktree.isMain { return nil }
        return worktree.commit.message
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

        let titleFile = (worktreePath as NSString).appendingPathComponent(Self.wtpadTitleFile)
        let wtpadDir = (titleFile as NSString).deletingLastPathComponent

        watchFile(at: titleFile, worktreePath: worktreePath)
        watchDirectory(at: wtpadDir, worktreePath: worktreePath)
    }

    private static func readTitle(atWorktreePath path: String) -> String? {
        let file = (path as NSString).appendingPathComponent(wtpadTitleFile)
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

        let titleFile = (worktreePath as NSString).appendingPathComponent(Self.wtpadTitleFile)
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

    private func applyTitle(_ title: String?, for worktreePath: String) {
        if let title {
            worktreeTitles[worktreePath] = title
        } else {
            worktreeTitles.removeValue(forKey: worktreePath)
        }
    }

    // MARK: - Actions

    /// Create a new worktree: `wt switch --create --no-cd -y <branch>`
    func createWorktree(branch: String, base: String? = nil) async {
        let projectPath = self.projectPath
        do {
            var args = ["wt", "switch", "--create", "--no-cd", "-y"]
            if let base { args += ["--base", base] }
            args.append(branch)
            _ = try await Task.detached { try await Self.runCommand(args, in: projectPath) }.value
            let wts = try await Task.detached { try await Self.fetchWorktrees(in: projectPath) }.value
            self.worktrees = wts
            self.lastCreatedBranch = branch
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Remove a worktree: `wt remove <branch> -y`
    func removeWorktree(branch: String, force: Bool = false) {
        let projectPath = self.projectPath
        worktrees.removeAll { $0.branch == branch }
        Task.detached { [weak self] in
            do {
                var args = ["wt", "remove", "-y"]
                if force { args.append("--force") }
                args += ["--", branch]
                try await Self.runCommand(args, in: projectPath)
            } catch {
                let wts = (try? await Self.fetchWorktrees(in: projectPath)) ?? []
                await MainActor.run {
                    self?.worktrees = wts
                    self?.error = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Process helpers

    private static func fetchWorktrees(in directory: String) async throws -> [Worktree] {
        let data = try await runCommand(["wt", "list", "--format", "json"], in: directory)
        return try JSONDecoder().decode([Worktree].self, from: data)
    }

    @discardableResult
    private static func runCommand(_ args: [String], in directory: String) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw WorktreeError.commandFailed(args.joined(separator: " "))
        }

        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    enum WorktreeError: LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let cmd): return "Command failed: \(cmd)"
            }
        }
    }
}
