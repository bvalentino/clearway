import Foundation

/// Resolves the wtpad CLI binary location using hybrid logic:
/// 1. Check user's PATH (power user override)
/// 2. Fall back to the copy embedded in the app bundle
/// 3. Return nil if neither is available
enum WtpadBinary {
    /// Resolved path to the wtpad binary, computed once at startup.
    static let path: String? = {
        if let pathResult = pathFromUserPATH() {
            return pathResult
        }
        if let bundled = pathFromBundle() {
            return bundled
        }
        return nil
    }()

    /// Whether wtpad is available (either in PATH or embedded).
    static var isAvailable: Bool { path != nil }

    // MARK: - Private

    private static func pathFromUserPATH() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["wtpad"]
        process.environment = ShellEnvironment.processEnvironment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            if let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !result.isEmpty,
               result.allSatisfy({ !$0.isNewline && ($0.asciiValue ?? 0x20) >= 0x20 }),
               FileManager.default.isExecutableFile(atPath: result) {
                return result
            }
        } catch {
            Ghostty.logger.debug("which wtpad failed: \(error.localizedDescription)")
        }
        return nil
    }

    private static func pathFromBundle() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let bundledPath = resourceURL.appendingPathComponent("wtpad-cli").path
        return FileManager.default.isExecutableFile(atPath: bundledPath) ? bundledPath : nil
    }
}
