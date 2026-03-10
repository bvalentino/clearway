import Foundation

/// Resolves the wtpad CLI binary location using hybrid logic:
/// 1. Check user's PATH (power user override)
/// 2. Fall back to the copy embedded in the app bundle
/// 3. Return nil if neither is available
enum WtpadBinary {
    /// Whether wtpad is available as a command in the user's PATH.
    /// Call `refresh()` after installing the CLI.
    private(set) static var isInPATH: Bool = checkPATH()

    /// Whether wtpad can be resolved at all (PATH or embedded bundle).
    static var isAvailable: Bool { isInPATH || bundledPath != nil }

    /// Absolute path to the CLI binary embedded in the app bundle, if present.
    static var bundledPath: String? {
        guard let execURL = Bundle.main.executableURL else { return nil }
        let path = execURL.deletingLastPathComponent().appendingPathComponent("cli").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Re-run binary resolution (e.g. after installing the CLI to /usr/local/bin).
    static func refresh() {
        isInPATH = checkPATH()
    }

    // MARK: - Private

    private static func checkPATH() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["wtpad"]
        process.environment = ShellEnvironment.processEnvironment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            _ = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
