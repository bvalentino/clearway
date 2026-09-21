import Foundation
import os

/// The disk half of the hook install: the `~/.clearway` layout and the forwarder script, plus the
/// managed block inside each agent's own settings file. `AgentHookSettings` decides what that block
/// is and `AgentHookScript` holds the text; everything here is I/O.
///
/// Nothing is actor-isolated: it does no UI work, so the main-actor monitor calls it directly and
/// it stays free to be moved off the main actor without touching anything here.
enum AgentHookInstaller {

    /// Each agent's config directory and the file inside it that carries hooks. Clearway never
    /// creates the directory: its absence is how "this agent is not installed here" is spelled, and
    /// seeding a config folder for a tool the user does not have is a change nobody asked for.
    private static let agentFiles = [(directory: ".claude", name: "settings.json"), (directory: ".codex", name: "hooks.json")]

    /// `home` is a parameter, never `NSHomeDirectory()` read in here, so the whole install can be
    /// driven against a temp root.
    static func install(home: String) {
        installScript(AgentHookPaths(home: home))
        mergeAgentSettings(installing: true, home: home)
    }

    /// The forwarder stays on disk. It exits 0 on its first guard once nothing is listening, so
    /// leaving it costs nothing and re-enabling the toggle is one settings write.
    static func uninstall(home: String) {
        mergeAgentSettings(installing: false, home: home)
    }

    static func mergeAgentSettings(installing: Bool, home: String) {
        for agent in agentFiles {
            merge(
                installing: installing,
                directory: (home as NSString).appendingPathComponent(agent.directory),
                name: agent.name
            )
        }
    }

    // MARK: - The forwarder

    private static func installScript(_ paths: AgentHookPaths) {
        let fileManager = FileManager.default
        let path = paths.scriptPath
        do {
            for directory in [paths.clearwayDir, paths.hooksDir] {
                if !fileManager.fileExists(atPath: directory) {
                    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                }
                // Unconditional, for the same reason the script's mode below is: `0700` here is the
                // whole access control on the socket, and a `~/.clearway` that predates Clearway —
                // or one a umask left wider — is not narrowed by a create that never runs.
                try fileManager.setAttributes([.posixPermissions: AgentHookScript.dirMode], ofItemAtPath: directory)
            }

            let body = Data(AgentHookScript.body.utf8)
            if fileManager.contents(atPath: path) != body {
                try body.write(to: URL(fileURLWithPath: path), options: .atomic)
                Ghostty.logger.info("Wrote the agent hook forwarder to \(path, privacy: .public)")
            }
            // Unconditional: an atomic write lands a fresh inode with the process umask's mode, and
            // a forwarder that is not executable fails every hook with nothing to show for it.
            try fileManager.setAttributes([.posixPermissions: AgentHookScript.scriptMode], ofItemAtPath: path)
        } catch {
            Ghostty.logger.error("The agent hook forwarder could not be installed at \(path, privacy: .public): \(error)")
        }
    }

    // MARK: - The managed block

    private static func merge(installing: Bool, directory: String, name: String) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { return }

        let path = (directory as NSString).appendingPathComponent(name)
        let onDisk = fileManager.contents(atPath: path)
        // `contents` answers `nil` for a file that exists but cannot be read — mode `000`, one left
        // root-owned by a `sudo` run, an I/O error — as well as for one that is not there. Reading
        // that as "no file yet" is the destructive case, not a missed install: the merge would
        // start from an empty document, skip the backup because there is nothing to back up, and
        // replace the user's whole settings file with Clearway's block, which `rename(2)` is free
        // to do since it needs write permission on the directory rather than on the file.
        guard onDisk != nil || !fileManager.fileExists(atPath: path) else {
            Ghostty.logger.warning("\(path, privacy: .public) could not be read — leaving the agent hooks alone.")
            return
        }
        var settings: [String: Any] = [:]
        if let onDisk {
            // A file Clearway cannot read is a file it must not rewrite. No quarantine either: the
            // user can still repair it by hand, and renaming it away would take that chance.
            guard let object = (try? JSONSerialization.jsonObject(with: onDisk)) as? [String: Any] else {
                Ghostty.logger.warning("\(path, privacy: .public) is not a JSON object — leaving the agent hooks alone.")
                return
            }
            settings = object
        }

        let merged = installing
            ? AgentHookSettings.install(into: settings)
            : AgentHookSettings.uninstall(from: settings)

        guard let after = serialised(merged), let before = serialised(settings) else {
            Ghostty.logger.error("\(path, privacy: .public) holds a value that cannot be re-serialised — leaving it alone.")
            return
        }
        // Documents, not bytes: an uninstall on a file that never carried the block is a no-op, and
        // must not rewrite the user's own key order and whitespace to say so.
        guard after != before else { return }
        guard onDisk == nil || backUp(path) else { return }

        do {
            try after.write(to: URL(fileURLWithPath: path), options: .atomic)
            Ghostty.logger.info("\(installing ? "Installed" : "Removed", privacy: .public) the Clearway hooks in \(path, privacy: .public)")
        } catch {
            Ghostty.logger.error("\(path, privacy: .public) could not be written: \(error)")
        }
    }

    /// `.sortedKeys` as well as `.prettyPrinted`: the merge preserves values but not key order, so
    /// only a deterministic serialisation makes the second install a no-op.
    private static func serialised(_ settings: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    /// One copy, taken before the first modification and never refreshed, because after that the
    /// live file is already Clearway's spelling of it.
    ///
    /// Returns whether the write may go ahead: a backup that could not be taken is the whole reason
    /// the value-for-value merge is acceptable, so losing it silently is worse than not installing.
    private static func backUp(_ path: String) -> Bool {
        let backup = path + ".clearway-backup"
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: backup) else { return true }
        do {
            try fileManager.copyItem(atPath: path, toPath: backup)
            Ghostty.logger.info("Backed \(path, privacy: .public) up to \(backup, privacy: .public)")
            return true
        } catch {
            Ghostty.logger.error("\(path, privacy: .public) could not be backed up, so it was left alone: \(error)")
            return false
        }
    }
}
