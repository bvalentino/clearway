import Foundation
import os

/// Reads and writes Clearway's per-worktree git config — `clearway.name` and `clearway.status` in
/// each worktree's own `config.worktree`, which `git worktree remove` deletes along with the
/// worktree, so nothing here needs pruning, reconciling or a watcher.
///
/// Nonisolated and `Sendable`, the shape `WorktreeGroupStore` has: the manager holds the published
/// state, the store holds the commands.
final class WorktreeConfigStore: Sendable {

    static let nameKey = "clearway.name"
    static let statusKey = "clearway.status"

    private static let keyPrefix = "clearway."
    private static let extensionKey = "extensions.worktreeConfig"

    /// The two keys git-worktree(1) requires be moved out of `$GIT_DIR/config` before the
    /// extension is enabled: "If they exist in `$GIT_DIR/config`, you must move them to the
    /// `config.worktree` of the main worktree."
    private static let keysMovedByBootstrap = ["core.bare", "core.worktree"]

    private let projectPath: String

    /// `nil` until probed. While `extensions.worktreeConfig` is off, git-config(1) documents
    /// `--worktree` as "the same as `--local`", so a write would land in the shared `.git/config`
    /// where every worktree then reads one value. Reads answer `[:]` rather than falling back,
    /// which also costs a project that never used the feature zero processes per refresh.
    ///
    /// The probe is held as the `Task` rather than its result so the callers that arrive while it
    /// is still running await that one subprocess instead of each spawning their own: a reload
    /// reads every worktree concurrently, and all of them start on a cold cache.
    private let extensionProbe = OSAllocatedUnfairLock<Task<Bool, Never>?>(initialState: nil)

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    // MARK: - Arguments and parsing

    /// `-C` rather than the process's working directory: every command runs in `projectPath`, a
    /// directory that exists, so a vanished worktree is a git error rather than a `Process.run()`
    /// throw about the current directory.
    static func listArgs(worktreePath: String) -> [String] {
        ["git", "-C", worktreePath, "config", "--worktree", "--list", "--null"]
    }

    static func setArgs(worktreePath: String, key: String, value: String) -> [String] {
        ["git", "-C", worktreePath, "config", "--worktree", key, value]
    }

    static func unsetArgs(worktreePath: String, key: String) -> [String] {
        ["git", "-C", worktreePath, "config", "--worktree", "--unset", key]
    }

    /// Parses `--list --null` output: NUL-separated records of `key\nvalue`, split at the *first*
    /// newline only so a multi-line value survives. Keys outside `clearway.` are dropped —
    /// `git worktree add` seeds `core.bare` into a new worktree's `config.worktree` once the
    /// extension is on, and this filter is what stops that reaching the app.
    static func parseList(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for record in output.split(separator: "\0") {
            guard let separator = record.firstIndex(of: "\n") else { continue }
            let key = String(record[..<separator])
            guard key.hasPrefix(keyPrefix) else { continue }
            values[key] = String(record[record.index(after: separator)...])
        }
        return values
    }

    // MARK: - Read

    /// The `clearway.*` values stored against the worktree at `path`, or `[:]` when there are
    /// none, when the extension is off, or when the worktree has no `config.worktree` yet.
    func values(forWorktreeAt path: String) async -> [String: String] {
        guard await isExtensionEnabled() else { return [:] }
        guard let data = await run(Self.listArgs(worktreePath: path)) else { return [:] }
        return Self.parseList(String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Write

    /// Stores `value` against the worktree at `path`, or clears the key when it is `nil` or empty.
    /// Only a store enables the extension: while it is off no `clearway.*` value can exist, so a
    /// clear has nothing to unset and bootstrapping for one would relocate the repository's
    /// `core.bare` for nothing. Throws nothing either way: a config write is not worth failing a
    /// worktree creation over, and the next reload corrects the published map.
    func set(_ value: String?, forKey key: String, worktreeAt path: String) async {
        guard let value, !value.isEmpty else {
            guard await isExtensionEnabled() else { return }
            await run(Self.unsetArgs(worktreePath: path, key: key))
            return
        }
        guard await enableExtension() else { return }
        await run(Self.setArgs(worktreePath: path, key: key, value: value), reportingFailure: true)
    }

    // MARK: - Extension bootstrap

    private func isExtensionEnabled() async -> Bool {
        let probe = extensionProbe.withLock { stored -> Task<Bool, Never> in
            if let stored { return stored }
            let task = Task {
                let data = await self.run(
                    ["git", "config", "--local", "--get", "--type=bool", Self.extensionKey]
                )
                return data.map { self.trimmed($0) == "true" } ?? false
            }
            stored = task
            return task
        }
        return await probe.value
    }

    /// Copy, then enable, then unset: no window exists in which `core.bare` is live in neither
    /// file. Every step is idempotent, so two concurrent writers both running the bootstrap is
    /// benign and cheaper than serialising it.
    ///
    /// The common dir is the same absolute path from a linked worktree as from the main one, so
    /// this never needs main's worktree path — which matters, because `projectPath` is routinely
    /// a linked worktree.
    private func enableExtension() async -> Bool {
        if await isExtensionEnabled() { return true }

        guard let commonDirData = await run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            reportingFailure: true
        ) else { return false }
        let commonDir = trimmed(commonDirData)
        guard !commonDir.isEmpty else { return false }
        let worktreeConfig = (commonDir as NSString).appendingPathComponent("config.worktree")

        var moved: [String] = []
        for key in Self.keysMovedByBootstrap {
            guard let data = await run(["git", "config", "--local", "--get", key]) else { continue }
            let value = trimmed(data)
            guard !value.isEmpty else { continue }
            guard await run(
                ["git", "config", "--file", worktreeConfig, key, value],
                reportingFailure: true
            ) != nil else { return false }
            moved.append(key)
        }

        guard await run(
            ["git", "config", "--local", Self.extensionKey, "true"],
            reportingFailure: true
        ) != nil else { return false }

        for key in moved {
            await run(["git", "config", "--local", "--unset", key])
        }
        extensionProbe.withLock { $0 = Task { true } }
        return true
    }

    // MARK: - Process helpers

    /// Returns nil when git fails. A miss is an ordinary answer on the read and clear paths —
    /// `--get` exits 1 on an absent key, `--unset` exits 5, and `--list` fails outright on a
    /// worktree that has no `config.worktree` yet — so only the callers that must change state
    /// pass `reportingFailure`.
    @discardableResult
    private func run(_ args: [String], reportingFailure: Bool = false) async -> Data? {
        do {
            return try await WorktreeManager.runCommand(args, in: projectPath)
        } catch {
            if reportingFailure {
                let command = args.joined(separator: " ")
                Ghostty.logger.warning("worktree config: \(command) failed: \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func trimmed(_ data: Data) -> String {
        (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
