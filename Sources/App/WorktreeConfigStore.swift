import Foundation
import os

/// Reads and writes Clearway's git config in two scopes: the per-worktree keys in each worktree's
/// own `config.worktree`, which `git worktree remove` deletes along with the worktree, and the
/// repo-level keys in the shared `.git/config`, which `--local` reaches identically from every
/// worktree. Nothing here needs pruning, reconciling or a watcher.
///
/// Nonisolated and `Sendable`: the manager holds the published state, the store holds the commands.
final class WorktreeConfigStore: Sendable {

    static let nameKey = "clearway.name"
    static let statusKey = "clearway.status"

    /// Single lowercase words on purpose: `git config --list` lowercases key names and `parseList`
    /// keys its dictionary on what git printed, while callers look up these constants. Renaming
    /// either to camel case would silently stop every per-worktree read finding it.
    static let groupKey = "clearway.group"
    static let positionKey = "clearway.position"

    /// Repo scope, read with `--get`/`--get-all`, which return values and never key names, so the
    /// lowercasing above does not apply.
    static let groupingKey = "clearway.grouping"
    static let groupOrderKey = "clearway.groupOrder"

    private static let keyPrefix = "clearway."
    private static let extensionKey = "extensions.worktreeConfig"

    /// The two keys git-worktree(1) requires be moved out of `$GIT_DIR/config` before the
    /// extension is enabled: "If they exist in `$GIT_DIR/config`, you must move them to the
    /// `config.worktree` of the main worktree."
    private static let keysMovedByBootstrap = ["core.bare", "core.worktree"]

    /// Whether `extensions.worktreeConfig` is on. `unknown` is not a third kind of "off": it means
    /// git never answered, so nothing may be concluded about what is stored.
    private enum ExtensionState {
        case on
        case off
        case unknown
    }

    private let projectPath: String

    /// `nil` until probed. While `extensions.worktreeConfig` is off, git-config(1) documents
    /// `--worktree` as "the same as `--local`", so a write would land in the shared `.git/config`
    /// where every worktree then reads one value. Reads answer `[:]` rather than falling back,
    /// which also costs a project that never used the feature zero processes per refresh.
    ///
    /// The probe is held as the `Task` rather than its result so the callers that arrive while it
    /// is still running await that one subprocess instead of each spawning their own: a reload
    /// reads every worktree concurrently, and all of them start on a cold cache. An `unknown`
    /// answer is dropped from the cache instead of being kept: memoising a failed probe would
    /// blank every name and status for the store's whole lifetime.
    private let extensionProbe = OSAllocatedUnfairLock<Task<ExtensionState, Never>?>(initialState: nil)

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

    /// No `-C`: a repo-level command reaches the same shared `.git/config` from any worktree, and
    /// `run` already starts every process in `projectPath`.
    static func localGetArgs(key: String) -> [String] {
        ["git", "config", "--local", "--get", "--null", key]
    }

    static func localGetAllArgs(key: String) -> [String] {
        ["git", "config", "--local", "--get-all", "--null", key]
    }

    static func localSetArgs(key: String, value: String) -> [String] {
        ["git", "config", "--local", key, value]
    }

    static func localAddArgs(key: String, value: String) -> [String] {
        ["git", "config", "--local", "--add", key, value]
    }

    static func localUnsetAllArgs(key: String) -> [String] {
        ["git", "config", "--local", "--unset-all", key]
    }

    /// Parses `--null` value output: each value is NUL-terminated, so the record after the final
    /// NUL is dropped rather than reported as an empty value. Nothing splits on newlines, which is
    /// what lets a group name containing one survive whole.
    static func parseNullSeparated(_ output: String) -> [String] {
        var values = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if values.last?.isEmpty == true { values.removeLast() }
        return values
    }

    // MARK: - Read

    /// The `clearway.*` values stored against the worktree at `path`, `[:]` when there are none or
    /// the extension is off, and `nil` when git could not answer.
    ///
    /// `nil` and `[:]` are kept apart because the caller publishes the result: a worktree whose
    /// read could not be performed must keep the name and status it is already showing, while one
    /// that genuinely holds nothing must lose them. Any refusal git chose is the second kind —
    /// `--list` exits 128 on a worktree that has no `config.worktree` yet, and that is the common
    /// case for a worktree Clearway has never written to.
    func values(forWorktreeAt path: String) async -> [String: String]? {
        switch await extensionState() {
        case .off: return [:]
        case .unknown: return nil
        case .on: break
        }
        switch await run(Self.listArgs(worktreePath: path)) {
        case .output(let data):
            return Self.parseList(String(decoding: data, as: UTF8.self))
        case .refused:
            return [:]
        case .unavailable(let message):
            log("read \(path)", message)
            return nil
        }
    }

    /// Every value stored against the repo-level multivar `key`, in file order. `[]` when the key
    /// is absent or the extension is off, `nil` when git could not answer — the same three-way
    /// answer `values(forWorktreeAt:)` gives, for the same reason.
    ///
    /// The extension gate is what makes "a project where `extensions.worktreeConfig` cannot be
    /// enabled shows no groups" one rule rather than two: a registry no worktree could ever join
    /// is not worth reading.
    func localValues(forKey key: String) async -> [String]? {
        await readLocal(Self.localGetAllArgs(key: key), what: "read \(key)")
    }

    /// The single value stored against the repo-level `key`, or `nil` when it is absent, the
    /// extension is off, or git could not answer. The three are not kept apart: a single-valued
    /// key has no caller that would publish "unknown" differently from "unset".
    func localValue(forKey key: String) async -> String? {
        await readLocal(Self.localGetArgs(key: key), what: "read \(key)")?.first
    }

    private func readLocal(_ args: [String], what: String) async -> [String]? {
        switch await extensionState() {
        case .off: return []
        case .unknown: return nil
        case .on: break
        }
        switch await run(args) {
        case .output(let data):
            return Self.parseNullSeparated(String(decoding: data, as: UTF8.self))
        // git-config(1): "Returns error code 1 if key is not present."
        case .refused:
            return []
        case .unavailable(let message):
            log(what, message)
            return nil
        }
    }

    // MARK: - Write

    /// Stores `value` against the worktree at `path`, or clears the key when it is `nil` or empty,
    /// and reports whether git holds what was asked for. Only a store enables the extension: while
    /// it is off no `clearway.*` value can exist, so a clear has nothing to unset and
    /// bootstrapping for one would relocate the repository's `core.bare` for nothing.
    ///
    /// Throws nothing either way — a config write is not worth failing a worktree creation over —
    /// but it does answer, because the one caller that cannot simply be corrected by the next
    /// reload is a group rename or delete, which rewrites every member before the registry and
    /// must abandon the registry write when a member did not land.
    @discardableResult
    func set(_ value: String?, forKey key: String, worktreeAt path: String) async -> Bool {
        guard let value, !value.isEmpty else {
            switch await extensionState() {
            case .off: return true
            case .unknown: return false
            case .on: break
            }
            switch await run(Self.unsetArgs(worktreePath: path, key: key)) {
            // git-config(1): `--unset` exits 5 when the key is not there, which is the state asked for.
            case .output, .refused(5, _): return true
            case .refused(_, let message), .unavailable(let message):
                log("unset \(key) at \(path)", message)
                return false
            }
        }
        guard await enableExtension() else { return false }
        switch await run(Self.setArgs(worktreePath: path, key: key, value: value)) {
        case .output: return true
        case .refused(_, let message), .unavailable(let message):
            log("set \(key) at \(path)", message)
            return false
        }
    }

    /// Stores `value` against the repo-level `key`, or clears it when `nil` or empty, on the same
    /// terms as `set`: only a store enables the extension, and a clear with the extension off has
    /// nothing to remove. Single-valued keys only — a store replaces whatever is there, so a
    /// multivar would be left holding one value of several.
    @discardableResult
    func setLocal(_ value: String?, forKey key: String) async -> Bool {
        guard let value, !value.isEmpty else {
            switch await extensionState() {
            case .off: return true
            case .unknown: return false
            case .on: break
            }
            return await unsetAllLocal(key)
        }
        guard await enableExtension() else { return false }
        switch await run(Self.localSetArgs(key: key, value: value)) {
        case .output: return true
        case .refused(_, let message), .unavailable(let message):
            log("set \(key)", message)
            return false
        }
    }

    /// Rewrites the repo-level multivar `key` whole: unset every value, then add each of `values`
    /// in order. Never `--replace-all` or a value-regex — these values are arbitrary user text and
    /// escaping one into a POSIX ERE is a correctness hazard for the saving of two subprocesses.
    /// An empty array leaves the key unset.
    @discardableResult
    func replaceLocalValues(_ values: [String], forKey key: String) async -> Bool {
        guard await enableExtension() else { return false }
        guard await unsetAllLocal(key) else { return false }
        for value in values {
            switch await run(Self.localAddArgs(key: key, value: value)) {
            case .output: continue
            case .refused(_, let message), .unavailable(let message):
                log("add \(key)", message)
                return false
            }
        }
        return true
    }

    private func unsetAllLocal(_ key: String) async -> Bool {
        switch await run(Self.localUnsetAllArgs(key: key)) {
        // git-config(1): exit 5 when the key is not there, which is the state asked for.
        case .output, .refused(5, _): return true
        case .refused(_, let message), .unavailable(let message):
            log("unset \(key)", message)
            return false
        }
    }

    // MARK: - Extension bootstrap

    private func extensionState() async -> ExtensionState {
        let probe = extensionProbe.withLock { stored -> Task<ExtensionState, Never> in
            if let stored { return stored }
            let task = Task { await self.probeExtension() }
            stored = task
            return task
        }
        let state = await probe.value
        if case .unknown = state {
            extensionProbe.withLock { if $0 == probe { $0 = nil } }
        }
        return state
    }

    private func probeExtension() async -> ExtensionState {
        switch await run(["git", "config", "--local", "--get", "--type=bool", Self.extensionKey]) {
        case .output(let data):
            return trimmed(data) == "true" ? .on : .off
        // git-config(1): "Returns error code 1 if key is not present."
        case .refused:
            return .off
        case .unavailable(let message):
            log("probe \(Self.extensionKey)", message)
            return .unknown
        }
    }

    /// Copy, then enable, then unset: no window exists in which `core.bare` is live in neither
    /// file. Every step is idempotent, so two concurrent writers both running the bootstrap is
    /// benign and cheaper than serialising it.
    ///
    /// The common dir is the same absolute path from a linked worktree as from the main one, so
    /// this never needs main's worktree path — which matters, because `projectPath` is routinely
    /// a linked worktree.
    private func enableExtension() async -> Bool {
        switch await extensionState() {
        case .on: return true
        case .unknown: return false
        case .off: break
        }

        guard case .output(let commonDirData) = await run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            reportingFailure: true
        ) else { return false }
        let commonDir = trimmed(commonDirData)
        guard !commonDir.isEmpty else {
            log("locate the common dir", "git printed no path")
            return false
        }
        let worktreeConfig = (commonDir as NSString).appendingPathComponent("config.worktree")

        var moved: [String] = []
        for key in Self.keysMovedByBootstrap {
            guard case .output(let data) = await run(["git", "config", "--local", "--get", key]) else { continue }
            let value = trimmed(data)
            guard !value.isEmpty else { continue }
            guard case .output = await run(
                ["git", "config", "--file", worktreeConfig, key, value],
                reportingFailure: true
            ) else { return false }
            moved.append(key)
        }

        guard case .output = await run(
            ["git", "config", "--local", Self.extensionKey, "true"],
            reportingFailure: true
        ) else { return false }

        // Reported, not fatal: the extension is on and the copy landed, so the repository works.
        // Leaving `core.worktree` behind in `$GIT_DIR/config` is the state git-worktree(1) warns
        // about, though, and it is invisible in the app — the log is the only way to find it.
        for key in moved {
            await run(["git", "config", "--local", "--unset", key], reportingFailure: true)
        }
        extensionProbe.withLock { $0 = Task<ExtensionState, Never> { .on } }
        return true
    }

    // MARK: - Process helpers

    /// One `git` invocation's outcome, split by the question the callers actually ask: did git
    /// answer?
    ///
    /// A refusal is an answer. Every "nothing to report" git has is a non-zero exit — `--get`
    /// exits 1, `--unset` exits 5, `--list` exits 128 on a worktree with no `config.worktree` at
    /// all — so a read treats one as "stores nothing" and only a write treats one as a failure.
    /// `unavailable` is the case that is not an answer: git never ran, so nothing may be
    /// concluded, and publishing "no value" from it would clear the sidebar on a spawn failure.
    private enum GitOutcome {
        case output(Data)
        case refused(status: Int32, message: String)
        case unavailable(String)
    }

    @discardableResult
    private func run(_ args: [String], reportingFailure: Bool = false) async -> GitOutcome {
        let outcome: GitOutcome
        do {
            outcome = .output(try await WorktreeManager.runCommand(args, in: projectPath))
        } catch WorktreeManager.WorktreeError.commandFailed(_, let stderr, let status) {
            outcome = .refused(status: status, message: stderr.isEmpty ? "exit \(status)" : stderr)
        } catch {
            outcome = .unavailable(error.localizedDescription)
        }
        if reportingFailure {
            switch outcome {
            case .output: break
            case .refused(_, let message), .unavailable(let message):
                log(args.joined(separator: " "), message)
            }
        }
        return outcome
    }

    private func log(_ what: String, _ message: String) {
        Ghostty.logger.warning("worktree config: \(what) failed: \(message)")
    }

    private func trimmed(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
