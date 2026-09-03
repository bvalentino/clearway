@preconcurrency import Dispatch
import Foundation

/// Generic Claude Code session-file watching + path helpers, used by ClaudeActivityMonitor.
enum ClaudeSessionFiles {
    private static let claudeDir: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }()

    // MARK: - Path Encoding

    /// Encodes a filesystem path to Claude Code's project directory name format.
    /// `/Users/foo/bar` → `-Users-foo-bar` (replaces `/` and `.` with `-`).
    static func encodePathForClaude(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// The `~/.claude/projects/` parent directory.
    static let projectsParentDir: String = {
        (claudeDir as NSString).appendingPathComponent("projects")
    }()

    /// Returns the Claude Code projects directory for a given worktree path.
    static func projectDir(forWorktreePath path: String) -> String {
        let encoded = encodePathForClaude(path)
        return (claudeDir as NSString)
            .appendingPathComponent("projects")
            .appending("/\(encoded)")
    }

    // MARK: - File Watching

    /// The default mask catches atomic file operations (write-to-temp → rename)
    /// and in-place rewrites that `.write` alone can miss. Directory watchers that only
    /// care about entries appearing and disappearing pass `.write` instead.
    static let defaultWatchMask: DispatchSource.FileSystemEvent =
        [.write, .attrib, .rename, .link, .extend, .delete]

    /// Builds a file-system watcher.
    ///
    /// `nonisolated` is load-bearing, and so is routing every watcher through here.
    /// `setEventHandler`/`setCancelHandler` take a `@convention(block)` closure, so a literal
    /// written inside an actor-isolated method inherits that isolation and gets a
    /// `swift_task_isCurrentExecutor` prologue — which traps when libdispatch runs it on the
    /// utility queue below. Formed here, outside the actor, the blocks carry no isolation, and
    /// `handler` is a plain Swift function type the compiler checks statically instead.
    nonisolated static func makeWatcher(
        path: String,
        eventMask: DispatchSource.FileSystemEvent = defaultWatchMask,
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
}
