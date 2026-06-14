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

    nonisolated static func makeWatcher(
        path: String,
        handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        // Broad mask catches atomic file operations (write-to-temp → rename)
        // that .write alone can miss.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .attrib, .rename, .link, .extend],
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
