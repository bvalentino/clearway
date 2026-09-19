import Foundation
import os

// MARK: - Payload

/// On-disk representation. Wraps groups with a `defaultOrder` for ungrouped worktrees.
/// Decodes older files that stored a bare `[WorktreeGroup]` array by leaving `defaultOrder` empty.
struct WorktreeGroupsPayload: Codable, Equatable {
    var groups: [WorktreeGroup]
    var defaultOrder: [String]
    var grouping: WorktreeGrouping

    /// Statuses written by a version that kept them in this file. Populated only by
    /// `init(from:)`, through `LegacyCodingKeys`; there is no `CodingKeys` case for it, so the
    /// synthesised `encode(to:)` cannot write the key back. `WorktreeGroupManager` migrates a
    /// non-empty map into each worktree's own git config on load and saves at once.
    private(set) var legacyStatuses: [String: WorktreeStatus]

    /// `statuses` is deliberately absent: it is the key this payload no longer owns.
    enum CodingKeys: String, CodingKey {
        case groups
        case defaultOrder
        case grouping
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case statuses
    }

    static let empty = WorktreeGroupsPayload(groups: [], defaultOrder: [], grouping: .group)

    /// No defaults: `save()` builds the whole document, so a field added later must be a
    /// compile error there rather than an omission that erases it from disk on the next write.
    init(groups: [WorktreeGroup], defaultOrder: [String], grouping: WorktreeGrouping) {
        self.groups = groups
        self.defaultOrder = defaultOrder
        self.grouping = grouping
        self.legacyStatuses = [:]
    }

    /// Decodes leniently so no file this app has ever written is rejected: `groups` and
    /// `defaultOrder` stay required — their absence is what routes a legacy bare-array file to
    /// the fallback in `load()` — while anything unreadable under `statuses` or `grouping`
    /// degrades to the default. A throw here would take every group in the project with it, and
    /// `load()` would then write `.empty` back over the file.
    ///
    /// `try?` rather than `decodeIfPresent`, which throws on a value of the wrong shape:
    /// `"statuses": []` or a half-written file reaching the watcher is exactly the case that
    /// must not cost the user their groups.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decode([WorktreeGroup].self, forKey: .groups)
        defaultOrder = try container.decode([String].self, forKey: .defaultOrder)
        let groupingSlug = try? container.decode(String.self, forKey: .grouping)
        grouping = groupingSlug.flatMap(WorktreeGrouping.init(rawValue:)) ?? .group
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let statusSlugs = try? legacyContainer.decode([String: String].self, forKey: .statuses)
        legacyStatuses = statusSlugs?.compactMapValues(WorktreeStatus.init(rawValue:)) ?? [:]
    }
}

// MARK: - Store

final class WorktreeGroupStore: Sendable {
    /// Both watcher sources, held behind a lock so the store stays `Sendable` and a
    /// nonisolated `deinit` can cancel them from any thread.
    private struct WatcherSources {
        var dir: DispatchSourceFileSystemObject?
        var file: DispatchSourceFileSystemObject?
    }

    private let projectPath: String

    // Serialises all writes to prevent interleaved file mutations from the same process.
    private let writeQueue = DispatchQueue(label: "app.getclearway.mac.WorktreeGroupStore.write")

    private let sources = OSAllocatedUnfairLock(initialState: WatcherSources())

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    deinit {
        stopWatching()
    }

    // MARK: - Paths

    private var clearwayDir: String {
        (projectPath as NSString).appendingPathComponent(".clearway")
    }

    private var groupsFile: String {
        (clearwayDir as NSString).appendingPathComponent("groups.json")
    }

    private var groupsTempFile: String {
        (clearwayDir as NSString).appendingPathComponent("groups.json.tmp")
    }

    // MARK: - Load

    func load() async -> WorktreeGroupsPayload {
        let path = groupsFile
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: path) else { return .empty }
            guard let data = fm.contents(atPath: path) else { return .empty }
            // Prefer the current payload format; fall back to the legacy bare-array format
            // so existing projects keep their groups after upgrade.
            if let payload = try? JSONDecoder().decode(WorktreeGroupsPayload.self, from: data) {
                return payload
            }
            if let legacy = try? JSONDecoder().decode([WorktreeGroup].self, from: data) {
                return WorktreeGroupsPayload(groups: legacy, defaultOrder: [], grouping: .group)
            }
            Ghostty.logger.warning("groups.json is corrupt — resetting to empty.")
            return .empty
        }.value
    }

    // MARK: - Save

    func save(_ payload: WorktreeGroupsPayload) async throws {
        let data = try JSONEncoder().encode(payload)
        let dir = clearwayDir
        let tmpPath = groupsTempFile
        let finalPath = groupsFile

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    let fm = FileManager.default
                    // Create the .clearway directory lazily on first save.
                    if !fm.fileExists(atPath: dir) {
                        try fm.createDirectory(
                            atPath: dir,
                            withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700]
                        )
                    }
                    // Write to a temp file first, then atomically rename over the final path.
                    // This ensures the reader always sees a complete file, never a partial write.
                    fm.createFile(atPath: tmpPath, contents: data, attributes: [.posixPermissions: 0o600])
                    _ = try fm.replaceItemAt(URL(fileURLWithPath: finalPath), withItemAt: URL(fileURLWithPath: tmpPath))
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Watching

    func startWatching(onExternalChange: @escaping @Sendable () -> Void) {
        stopWatching()
        openFileWatcher(onExternalChange: onExternalChange)
    }

    func stopWatching() {
        let previous = sources.withLock { state in
            defer { state = WatcherSources() }
            return state
        }
        previous.file?.cancel()
        previous.dir?.cancel()
    }

    // MARK: - Private Watcher Helpers

    /// Attempts to open a file-level watcher. Falls back to a directory watcher if the file
    /// does not yet exist (e.g., before the first save).
    private func openFileWatcher(onExternalChange: @escaping @Sendable () -> Void) {
        let path = groupsFile
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            openDirWatcher(onExternalChange: onExternalChange)
            return
        }

        // File exists — cancel any directory watcher and watch the file directly.
        cancelDirWatcher()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )
        // Capture `source` weakly: a strong capture combined with the recursive
        // reopen below creates a retain cycle that libdispatch tears down twice
        // during cancellation, crashing in `_os_object_release`.
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let events = source.data
            let fileGone = events.contains(.delete) || events.contains(.rename)
            onExternalChange()
            // Reopen when the watched inode is gone (atomic save replaces the file),
            // but do it on the next tick so we don't swap out the file source
            // while the current handler is still running inside libdispatch.
            if fileGone {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.openFileWatcher(onExternalChange: onExternalChange)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.withLock { $0.file = source }
    }

    /// Watches the .clearway directory for entry changes. Switches to per-file watching
    /// once groups.json appears (created by another process or by the first save).
    private func openDirWatcher(onExternalChange: @escaping @Sendable () -> Void) {
        cancelDirWatcher()

        let dirPath = clearwayDir
        let filePath = groupsFile

        // Ensure the directory exists so we can open an fd for it.
        try? FileManager.default.createDirectory(
            atPath: dirPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard FileManager.default.fileExists(atPath: filePath) else { return }
            onExternalChange()
            // groups.json appeared — upgrade to a file-level watcher on the next
            // tick so we don't swap out the directory source from inside its own
            // handler (same teardown hazard as the file-level path).
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.openFileWatcher(onExternalChange: onExternalChange)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.withLock { $0.dir = source }
    }

    private func cancelDirWatcher() {
        let previous = sources.withLock { state in
            defer { state.dir = nil }
            return state.dir
        }
        previous?.cancel()
    }
}
