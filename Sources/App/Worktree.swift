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

// MARK: - Defaults Keys

private enum DefaultsKey {
    static let projectPaths = "wtpad.projectPaths"
    static let activeProjectPath = "wtpad.activeProjectPath"
    static let legacyProjectPath = "wtpad.projectPath"
}

// MARK: - Manager

/// Manages worktree listing and actions for a project directory.
@MainActor
class WorktreeManager: ObservableObject {
    @Published var worktrees: [Worktree] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastCreatedBranch: String?
    @Published var projectPaths: [String] = [] {
        didSet {
            UserDefaults.standard.set(projectPaths, forKey: DefaultsKey.projectPaths)
        }
    }
    @Published var activeProjectPath: String? {
        didSet {
            if let path = activeProjectPath {
                UserDefaults.standard.set(path, forKey: DefaultsKey.activeProjectPath)
            }
            refresh()
        }
    }

    init() {
        // Migrate from single project path
        if let single = UserDefaults.standard.string(forKey: DefaultsKey.legacyProjectPath) {
            self.projectPaths = [single]
            self.activeProjectPath = single
            UserDefaults.standard.removeObject(forKey: DefaultsKey.legacyProjectPath)
            UserDefaults.standard.set(projectPaths, forKey: DefaultsKey.projectPaths)
            UserDefaults.standard.set(single, forKey: DefaultsKey.activeProjectPath)
        } else {
            self.projectPaths = UserDefaults.standard.stringArray(forKey: DefaultsKey.projectPaths) ?? []
            self.activeProjectPath = UserDefaults.standard.string(forKey: DefaultsKey.activeProjectPath)
        }

        if activeProjectPath != nil {
            refresh()
        }
    }

    func addProject(_ path: String) {
        if !projectPaths.contains(path) {
            projectPaths.append(path)
        }
        activeProjectPath = path
    }

    func removeProject(_ path: String) {
        projectPaths.removeAll { $0 == path }
        if activeProjectPath == path {
            activeProjectPath = projectPaths.first
        }
    }

    func refresh() {
        guard let projectPath = activeProjectPath else {
            worktrees = []
            return
        }
        isLoading = true
        error = nil

        Task {
            do {
                let wts = try await Self.fetchWorktrees(in: projectPath)
                self.worktrees = wts
                self.isLoading = false
            } catch {
                self.error = error.localizedDescription
                self.worktrees = []
                self.isLoading = false
            }
        }
    }

    // MARK: - Actions

    /// Create a new worktree: `wt switch --create <branch> --no-cd -y`
    func createWorktree(branch: String, base: String? = nil) {
        guard let projectPath = activeProjectPath else { return }
        Task.detached { [weak self] in
            do {
                var args = ["wt", "switch", "--create", branch, "--no-cd", "-y"]
                if let base { args += ["--base", base] }
                try await Self.runCommand(args, in: projectPath)
                let wts = try await Self.fetchWorktrees(in: projectPath)
                await MainActor.run {
                    self?.worktrees = wts
                    self?.lastCreatedBranch = branch
                }
            } catch {
                await MainActor.run {
                    self?.error = error.localizedDescription
                }
            }
        }
    }

    /// Remove a worktree: `wt remove <branch> -y`
    func removeWorktree(branch: String, force: Bool = false) {
        guard let projectPath = activeProjectPath else { return }
        worktrees.removeAll { $0.branch == branch }
        Task.detached { [weak self] in
            do {
                var args = ["wt", "remove", branch, "-y"]
                if force { args.append("--force") }
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
