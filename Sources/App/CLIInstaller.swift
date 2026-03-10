import AppKit

/// Manages installation of the wtpad CLI symlink to /usr/local/bin.
@MainActor
class CLIInstaller: ObservableObject {
    static let installPath = "/usr/local/bin/wtpad"

    @Published private(set) var isInstalled = false

    init() {
        checkInstallStatus()
    }

    func checkInstallStatus() {
        isInstalled = Self.symlinkPointsToBundle()
    }

    func install() {
        guard let source = WtpadBinary.bundledPath else { return }

        // Try unprivileged first, escalate via osascript if needed
        if !runProcesses([
            ("/bin/mkdir", ["-p", "/usr/local/bin"]),
            ("/bin/ln", ["-sf", source, Self.installPath]),
        ]) {
            let escaped = shellEscape(source)
            runElevated("mkdir -p /usr/local/bin && ln -sf \(escaped) \(shellEscape(Self.installPath))")
        }

        WtpadBinary.refresh()
        checkInstallStatus()
    }

    func uninstall() {
        guard Self.symlinkPointsToBundle() else { return }

        if !runProcesses([("/bin/rm", ["-f", Self.installPath])]) {
            runElevated("rm -f \(shellEscape(Self.installPath))")
        }

        WtpadBinary.refresh()
        checkInstallStatus()
    }

    // MARK: - Private

    private static func symlinkPointsToBundle() -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: installPath) else {
            return false
        }
        return target.hasPrefix(Bundle.main.bundlePath)
    }

    /// Run a sequence of processes. Returns true if all succeed.
    @discardableResult
    private func runProcesses(_ commands: [(String, [String])]) -> Bool {
        for (executable, args) in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                _ = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
                _ = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return false }
            } catch {
                return false
            }
        }
        return true
    }

    /// Run a shell command with administrator privileges via osascript.
    private func runElevated(_ commands: String) {
        let escaped = commands.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            _ = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let msg = String(data: errData, encoding: .utf8) ?? ""
                Ghostty.logger.warning("CLI elevated command failed: \(msg)")
            }
        } catch {
            Ghostty.logger.warning("CLI osascript failed: \(error.localizedDescription)")
        }
    }
}
