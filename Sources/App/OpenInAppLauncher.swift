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
/// is formed: the watch window is a `Task.sleep` poll on the cooperative pool, so neither
/// `Process.terminationHandler` nor a `DispatchSource` is needed.
enum OpenInAppLauncher {

    /// How long a launch is watched for failure. `sh` reports `command not found` and exits 127
    /// in well under 100 ms, so a failure is never held up by this; a command that stays in the
    /// foreground waits it out, which nobody sees because success is silent.
    static let watchWindow: TimeInterval = 2

    private static let pollInterval: TimeInterval = 0.025

    /// The script handed to `/bin/sh -c`. The command text is interpolated raw — it is the user's
    /// and is meant to be read by the shell as typed, the same contract as `WorktreeHooks`. Only
    /// the appended folder is escaped; the PATH arrives through the child's environment.
    nonisolated static func buildOpenInScript(command: String, path: String) -> String {
        "\(command) \(shellEscape(path))"
    }

    /// What the failure alert shows below its title. Some failures say nothing at all — `false`
    /// exits 1 silently — so no output needs its own wording rather than an empty alert.
    nonisolated static func failureMessage(command: String, detail: String) -> String {
        detail.isEmpty ? "\"\(command)\" failed without reporting an error." : detail
    }

    /// A `run()` throw is about the working directory, never the command — the shell has not
    /// looked the command up yet. Naming the folder keeps the alert from reading as if the app
    /// were the thing missing, since its title already carries the app's label.
    nonisolated static func spawnFailureMessage(directory: String, error: Error) -> String {
        "Couldn't run in \(directory) — \(error.localizedDescription)"
    }

    nonisolated static func launch(command: String, path: String) async -> OpenInLaunchOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", buildOpenInScript(command: command, path: path)]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.environment = ShellEnvironment.processEnvironment
        process.standardInput = FileHandle.nullDevice

        // An unlinked temp file, not a pipe. A pipe's verdict arrives at EOF, and any grandchild
        // that inherits the descriptor — an editor the command backgrounds — holds the write end
        // open for its whole life, so the shell's exit status would stay unreadable behind it.
        // A regular file also has no 64KB buffer to fill, so nothing has to be drained to keep
        // the child from blocking. Unlinking at once means the space is reclaimed whenever the
        // last descriptor closes, including when this function abandons a child at the deadline.
        let output = makeOutputSink()
        let sink: FileHandle = output ?? .nullDevice
        process.standardOutput = sink
        process.standardError = sink

        do {
            try process.run()
        } catch {
            let message = spawnFailureMessage(directory: path, error: error)
            Ghostty.logger.error("OpenInAppLauncher: spawn failed: \(message)")
            return .failed(message: message)
        }

        let deadline = Date().addingTimeInterval(watchWindow)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        guard !process.isRunning else { return .launched }
        guard process.terminationStatus != 0 else { return .launched }

        let detail = output.map(readFromStart) ?? ""
        Ghostty.logger.error(
            "OpenInAppLauncher: \"\(command)\" exited \(process.terminationStatus): \(detail)"
        )
        return .failed(message: detail)
    }

    private nonisolated static func makeOutputSink() -> FileHandle? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clearway-open-in-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forUpdating: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return handle
    }

    private nonisolated static func readFromStart(_ handle: FileHandle) -> String {
        try? handle.seek(toOffset: 0)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
