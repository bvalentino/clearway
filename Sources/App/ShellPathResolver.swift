import Foundation
import os

/// Runs the login shell to read the user's `PATH`.
///
/// One resolution is up to two attempts. `-lic` sources `.zshrc`, which is where
/// Homebrew, `mise`, and `nvm` usually add their directories, but is also where a
/// profile script can block waiting for a human. `-lc` sources `.zprofile` only, so it
/// bypasses any interactive-only script that blocks or that prints junk; its value is
/// therefore usable but incomplete, and is marked degraded.
struct ShellPathResolver {

    /// The result of one resolution.
    enum Outcome: Equatable {
        /// The interactive attempt succeeded. This is the user's full `PATH`.
        case full(String)
        /// The interactive attempt failed and the login-only attempt succeeded. Usable,
        /// but it can be missing `.zshrc`-only entries, so it is worth retrying later.
        case degraded(String)
        /// Neither attempt produced a `PATH`.
        case failed
    }

    /// The limit for one attempt.
    ///
    /// The measured healthy path on the machine that reported the defect is 1.1 to 1.6
    /// seconds, so this is about three times the headroom needed. The failure mode is a
    /// profile that blocks waiting for a human, not a slow profile, so a longer limit
    /// only holds a hung shell for longer and delays the fallback.
    static let attemptTimeout: TimeInterval = 5

    /// Prefixes the printed `PATH` so it can be picked out of whatever else a profile writes to
    /// stdout, before it or after it. Without a marker the resolver has to guess which line is the
    /// `PATH` — "the last non-empty line" — and any trailing chatter that happens to be
    /// colon-separated is taken as the answer.
    static let outputMarker = "clearway-path:"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.getclearway.mac",
        category: "shell-environment"
    )

    private let shell: String
    private let timeout: TimeInterval

    init(
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        timeout: TimeInterval = attemptTimeout
    ) {
        self.shell = shell
        self.timeout = timeout
    }

    func resolve() -> Outcome {
        if let path = attempt(flags: "-lic") { return .full(path) }
        Self.logger.warning("Shell PATH falling back to the login-only shell (shell: \(shell, privacy: .public))")
        if let path = attempt(flags: "-lc") { return .degraded(path) }
        Self.logger.warning("Shell PATH resolution failed on both attempts (shell: \(shell, privacy: .public))")
        return .failed
    }

    /// Runs one attempt, and returns the sanitized `PATH` it printed, or `nil`.
    ///
    /// Both streams are captured to files (see `CapturedOutput`), and stdout is read only once the
    /// shell has exited. That makes "a timed-out read never produces a `PATH`" structural, rather
    /// than a rule the code has to keep.
    private func attempt(flags: String) -> String? {
        guard let output = CapturedOutput() else {
            Self.logger.warning("Shell PATH \(flags, privacy: .public) attempt could not open its stdout file")
            return nil
        }
        defer { output.discard() }
        guard let errors = CapturedOutput() else {
            Self.logger.warning("Shell PATH \(flags, privacy: .public) attempt could not open its stderr file")
            return nil
        }
        defer { errors.discard() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [flags, "echo \"\(Self.outputMarker)$PATH\""]
        process.standardOutput = output.handle
        // A file for the same reason as stdout, and never a pipe: an unread pipe fills at its
        // buffer size and blocks the shell mid-write, timing out a profile that is merely chatty.
        process.standardError = errors.handle

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            let message = error.localizedDescription
            Self.logger.warning("Shell PATH \(flags, privacy: .public) attempt could not start: \(message, privacy: .public)")
            return nil
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            // stdout stays unread: whatever it holds is profile output from a run that never
            // reached the echo, and accepting it is what produced terminals where even `cat` and
            // `rm` failed. stderr is read for the log alone — a shell that is still writing makes
            // that a partial view, which is fine for a diagnostic and is why the two differ.
            Self.logger.warning("""
            Shell PATH \(flags, privacy: .public) attempt timed out \
            (shell: \(shell, privacy: .public))\(errors.detail, privacy: .public)
            """)
            return nil
        }

        // Read only after the shell has exited, so nothing this attempt started is still writing.
        let printed = output.contents

        guard process.terminationStatus == 0 else {
            Self.logger.warning("""
            Shell PATH \(flags, privacy: .public) attempt exited with status \(process.terminationStatus) \
            (shell: \(shell, privacy: .public))\(errors.detail, privacy: .public)
            """)
            return nil
        }

        guard let candidate = Self.markedPath(in: printed) else {
            Self.logger.warning("""
            Shell PATH \(flags, privacy: .public) attempt printed no PATH line \
            (shell: \(shell, privacy: .public))\(errors.detail, privacy: .public)
            """)
            return nil
        }

        guard let sanitized = ShellPathValidation.sanitize(candidate) else {
            let refused = candidate.prefix(200)
            Self.logger.warning("""
            Shell PATH \(flags, privacy: .public) attempt refused, not a PATH: \
            \(refused, privacy: .public)\(errors.detail, privacy: .public)
            """)
            return nil
        }

        Self.logger.info("Shell PATH \(flags, privacy: .public) attempt resolved: \(sanitized, privacy: .public)")
        return sanitized
    }

    /// One stream of a shell attempt, captured to a file.
    ///
    /// A file rather than a pipe: a pipe needs a reader on another thread — the write end can be
    /// inherited by a grandchild, so the read outlives the shell's own exit — and unblocking that
    /// reader on a timeout means closing the descriptor underneath it, which races a blocked `read`
    /// and, once the number is reused, can consume another file's bytes. A file has no reader to
    /// unblock, cannot fill, and is simply left unread when an attempt is abandoned.
    private struct CapturedOutput {
        let url: URL
        let handle: FileHandle

        init?() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("clearway-shell-path-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: url) else { return nil }
            self.url = url
            self.handle = handle
        }

        var contents: String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        /// This stream as a log suffix, empty when the shell wrote nothing. Truncated from the end,
        /// where a profile that failed says why.
        var detail: String {
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "" : " stderr: \(trimmed.suffix(500))"
        }

        func discard() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The `PATH` the marked line carries, or `nil` when the shell never printed one — it blocked
    /// before reaching the echo, or wrote only profile output. Takes the last marked line, since the
    /// echo is the last thing the shell is asked to run.
    private static func markedPath(in output: String) -> String? {
        output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(outputMarker) else { return nil }
                return String(trimmed.dropFirst(outputMarker.count))
            }
            .last
    }
}
