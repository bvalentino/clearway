import Foundation

/// What a launch reported inside the watch window. `launched` also covers a child still running
/// at the deadline, which is the normal outcome for an editor that stays in the foreground.
enum OpenInLaunchOutcome: Equatable, Sendable {
    case launched
    case failed(message: String)
}

/// Runs a user-configured "Open in" command against a worktree folder.
///
/// Nothing here is `@MainActor`, and no `@convention(block)` or `@convention(c)` closure literal
/// is formed: the spawn, the stderr drain and `waitUntilExit()` all block, so they run off the
/// cooperative pool, and `Process.terminationHandler` is avoided entirely.
enum OpenInAppLauncher {

    /// How long a launch is watched for failure. `sh` reports `command not found` and exits 127
    /// in well under 100 ms, so a launch that works never waits this out.
    static let watchWindow: TimeInterval = 2

    /// The script handed to `/bin/sh -c`. The command text is interpolated raw — it is the user's
    /// and is meant to be read by the shell as typed, the same contract as `WorktreeHooks`. Only
    /// the appended folder is escaped; the PATH arrives through the child's environment.
    nonisolated static func buildOpenInScript(command: String, path: String) -> String {
        "\(command) \(shellEscape(path))"
    }

    /// What the failure alert shows below its title. Some failures say nothing at all — `false`
    /// exits 1 silently — so a blank stderr needs its own wording rather than an empty alert.
    nonisolated static func failureMessage(command: String, stderr: String) -> String {
        stderr.isEmpty ? "\"\(command)\" failed without reporting an error." : stderr
    }

    nonisolated static func launch(command: String, path: String) async -> OpenInLaunchOutcome {
        let script = buildOpenInScript(command: command, path: path)
        let outcome = LaunchOutcomeBox()

        DispatchQueue.global(qos: .userInitiated).async {
            outcome.settle(runToCompletion(script: script, directory: path))
        }

        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(watchWindow * 1_000_000_000))
            outcome.settle(.launched)
        }
        defer { deadline.cancel() }

        return await outcome.wait()
    }

    private nonisolated static func runToCompletion(script: String, directory: String) -> OpenInLaunchOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ShellEnvironment.processEnvironment

        let stderr = Pipe()
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failed(message: error.localizedDescription)
        }

        // Read the pipe before waiting for exit: a child that fills the ~64KB buffer would
        // block on the write while we block on its exit.
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return .launched }
        let message = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failed(message: message)
    }
}

/// Delivers whichever arrives first — the child's outcome or the watch window expiring — and drops
/// every later one, so the continuation resumes exactly once. The loser keeps running: the drain
/// finishes on its own when the child exits.
private final class LaunchOutcomeBox: @unchecked Sendable {

    private let lock = NSLock()
    private var settled: OpenInLaunchOutcome?
    private var waiter: CheckedContinuation<OpenInLaunchOutcome, Never>?

    func settle(_ outcome: OpenInLaunchOutcome) {
        let waiter: CheckedContinuation<OpenInLaunchOutcome, Never>? = lock.withLock {
            guard settled == nil else { return nil }
            settled = outcome
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: outcome)
    }

    func wait() async -> OpenInLaunchOutcome {
        await withCheckedContinuation { continuation in
            let alreadySettled: OpenInLaunchOutcome? = lock.withLock {
                guard let settled else {
                    waiter = continuation
                    return nil
                }
                return settled
            }
            if let alreadySettled { continuation.resume(returning: alreadySettled) }
        }
    }
}
