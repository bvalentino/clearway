import Foundation

/// Resolves the user's login shell PATH so subprocesses can find tools like `wt` and `git`
/// even when the app is launched from Finder / Launchpad (which use a minimal PATH).
enum ShellEnvironment {
    /// The user's full PATH, resolved once at startup.
    static let path: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -li: login + interactive shell (sources both .zprofile and .zshrc)
        // -c: run command then exit
        process.arguments = ["-lic", "echo $PATH"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // Take last non-empty line — .zshrc may print other output before our echo
            if let output = String(data: data, encoding: .utf8),
               let resolved = output.split(separator: "\n").last
                .map({ String($0).trimmingCharacters(in: .whitespaces) }),
               !resolved.isEmpty {
                return resolved
            }
        } catch {}

        // Fallback: current process PATH (minimal when launched from Finder)
        return ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    /// A process environment dictionary with the resolved PATH, computed once.
    static let processEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return env
    }()
}
