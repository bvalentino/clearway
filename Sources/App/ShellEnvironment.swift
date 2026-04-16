import Foundation
import os

/// Resolves the user's login shell PATH so subprocesses can find tools like `gh`
/// even when the app is launched from Finder / Launchpad (which use a minimal PATH).
///
/// Note: git commands no longer depend on this — they use ``GitResolver`` to find
/// the git binary directly. This PATH is used for non-git tools (hooks, agent commands).
enum ShellEnvironment {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.getclearway.mac",
        category: "shell-environment"
    )

    /// The user's full PATH, resolved once at startup.
    static let path: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l: login shell (sources .zprofile/.bash_profile for PATH setup)
        // -i: interactive (sources .zshrc — needed for Homebrew/mise/nvm PATH entries)
        // -c: run command then exit
        // The 5-second timeout below protects against interactive shells that hang
        // without a PTY. The timeout covers the read, not just the process, so a
        // shell that spawns background children cannot block startup.
        process.arguments = ["-lic", "echo $PATH"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()

            let readHandle = pipe.fileHandleForReading
            let semaphore = DispatchSemaphore(value: 0)
            var readData: Data?

            // Read on a background thread so we can enforce the timeout on the
            // read itself — not just the shell process.
            DispatchQueue.global().async {
                readData = readHandle.readDataToEndOfFile()
                semaphore.signal()
            }

            let timedOut = semaphore.wait(timeout: .now() + 5) == .timedOut

            if timedOut {
                process.terminate()
                // Close the read end of the pipe to unblock readDataToEndOfFile.
                // This is necessary because a child process may have inherited the
                // pipe's write end, keeping it open after the shell is terminated.
                try? readHandle.close()
                logger.warning("Shell PATH resolution timed out (shell: \(shell, privacy: .public))")
            } else {
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    logger.warning("Shell PATH resolution exited with status \(process.terminationStatus) (shell: \(shell, privacy: .public))")
                }
            }

            // Take last non-empty line — shell profile may print other output before our echo
            if let data = readData,
               let output = String(data: data, encoding: .utf8),
               let resolved = output.split(separator: "\n").last
                .map({ String($0).trimmingCharacters(in: .whitespaces) }),
               !resolved.isEmpty {
                logger.info("Shell PATH resolved (shell: \(shell, privacy: .public)): \(resolved, privacy: .public)")
                return resolved
            }

            logger.warning("Shell PATH resolution returned empty output (shell: \(shell, privacy: .public))")
        } catch {
            logger.warning("Shell PATH resolution failed: \(error.localizedDescription, privacy: .public) (shell: \(shell, privacy: .public))")
        }

        // Fallback: current process PATH (minimal when launched from Finder)
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        logger.warning("Shell PATH using fallback: \(fallback, privacy: .public)")
        return fallback
    }()

    /// A process environment dictionary with the resolved PATH, computed once.
    static let processEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return env
    }()
}
