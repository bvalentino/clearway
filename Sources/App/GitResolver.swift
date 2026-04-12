import Foundation
import os

/// Resolves the path to a usable `git` binary at startup.
///
/// Searches well-known installation locations in priority order so that
/// git operations work even when the app is launched from Finder with a
/// minimal PATH that doesn't include Homebrew or mise directories.
///
/// Each candidate is probed with `git --version` — a path that merely
/// exists (e.g. the Xcode CLT shim when tools aren't installed) is
/// skipped in favor of the next candidate or the bundled runtime.
enum GitResolver {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.getclearway.mac",
        category: "git-resolver"
    )

    /// Well-known git locations, checked in order.
    static let searchPaths: [String] = [
        "/opt/homebrew/bin/git",   // Homebrew on Apple Silicon
        "/usr/local/bin/git",      // Homebrew on Intel
        "/usr/bin/git",            // Xcode Command Line Tools
    ]

    /// Returns true if the binary at `path` can successfully run `git --version`.
    /// This catches shim binaries (e.g. `/usr/bin/git` without Xcode CLT) that are
    /// executable but non-functional.
    static func isUsableGit(at path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// The resolved git binary path, computed once at startup.
    static let resolvedPath: String = {
        for candidate in searchPaths where isUsableGit(at: candidate) {
            logger.info("Using git at \(candidate, privacy: .public)")
            return candidate
        }

        // Fallback: bundled git inside the app bundle
        if let bundled = bundledGitPath, isUsableGit(at: bundled) {
            logger.warning("No usable system git found; using bundled git at \(bundled, privacy: .public)")
            return bundled
        }

        // Last resort: return the Xcode CLT path and let process.run() throw if it
        // doesn't exist — callers already handle errors from runCommand.
        logger.error("No usable git binary found in well-known locations or app bundle")
        return "/usr/bin/git"
    }()

    /// Path to the bundled git binary, or nil if not present.
    private static let bundledGitPath: String? = {
        Bundle.main.resourceURL?
            .appendingPathComponent("git-dist")
            .appendingPathComponent("git")
            .path
    }()

    /// `GIT_EXEC_PATH` for the bundled git runtime (points to the git-core
    /// directory containing transport helpers like git-remote-https).
    /// Nil when using a system git installation.
    static let execPath: String? = {
        guard let bundled = bundledGitPath,
              resolvedPath == bundled else {
            return nil
        }
        let gitCorePath = (bundled as NSString)
            .deletingLastPathComponent
            .appending("/git-core")
        guard FileManager.default.fileExists(atPath: gitCorePath) else {
            logger.warning("Bundled git-core directory missing at \(gitCorePath, privacy: .public)")
            return nil
        }
        logger.info("Using bundled GIT_EXEC_PATH: \(gitCorePath, privacy: .public)")
        return gitCorePath
    }()
}
