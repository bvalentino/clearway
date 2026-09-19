import Foundation
import os

/// Reads and writes one project's command list at `<projectPath>/.clearway/commands.json`, beside
/// that project's `groups.json`, and the two ids that index it in the sibling
/// `command-defaults.json`.
///
/// The array is stored and returned in order — that order is the display order, so nothing here
/// sorts or re-keys. A missing file loads as empty. An unreadable or undecodable one loads as empty
/// too, but is moved aside to `commands.json.corrupt` first, so the next save cannot destroy the
/// only copy of a list the user can still repair by hand.
final class SavedCommandStore: Sendable {

    private let projectPath: String

    /// Serialises writes so two mutations in flight cannot interleave on the same file.
    private let writeQueue = DispatchQueue(label: "app.getclearway.mac.SavedCommandStore.write")

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    // MARK: - Paths

    private var clearwayDir: String {
        (projectPath as NSString).appendingPathComponent(".clearway")
    }

    private var commandsFile: String {
        (clearwayDir as NSString).appendingPathComponent("commands.json")
    }

    private var commandsTempFile: String {
        (clearwayDir as NSString).appendingPathComponent("commands.json.tmp")
    }

    private var commandsCorruptFile: String {
        (clearwayDir as NSString).appendingPathComponent("commands.json.corrupt")
    }

    private var defaultsFile: String {
        (clearwayDir as NSString).appendingPathComponent("command-defaults.json")
    }

    private var defaultsTempFile: String {
        (clearwayDir as NSString).appendingPathComponent("command-defaults.json.tmp")
    }

    // MARK: - Load

    func load() async -> [SavedCommand] {
        let path = commandsFile
        let corruptPath = commandsCorruptFile
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: path) else { return [] }
            guard let data = fm.contents(atPath: path) else {
                Ghostty.logger.warning("commands.json is unreadable — loading as empty.")
                Self.moveAside(path, to: corruptPath)
                return []
            }
            do {
                return try JSONDecoder().decode([SavedCommand].self, from: data)
            } catch {
                // The error names the offending key and index, which is what makes the file
                // hand-repairable — a bare "corrupt" tells its reader nothing.
                Ghostty.logger.warning("commands.json is corrupt — loading as empty: \(error)")
                Self.moveAside(path, to: corruptPath)
                return []
            }
        }.value
    }

    /// Renames an unusable `commands.json` out of the way so the next save writes a fresh file
    /// instead of overwriting the one the user may still want to repair. An older `.corrupt` file
    /// is replaced — the list Clearway was last unable to read is the one worth keeping.
    private static func moveAside(_ path: String, to corruptPath: String) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: corruptPath) {
                try fm.removeItem(atPath: corruptPath)
            }
            try fm.moveItem(atPath: path, toPath: corruptPath)
            Ghostty.logger.warning("commands.json moved aside to \(corruptPath, privacy: .public)")
        } catch {
            Ghostty.logger.error("commands.json could not be moved aside: \(error)")
        }
    }

    /// The two defaults are ids the user cannot repair by hand, so a missing, unreadable or
    /// undecodable file reads as None and is left exactly where it is: losing them costs one
    /// re-pick, which is cheaper than a quarantined file nobody can use.
    func loadDefaults() async -> CommandDefaults {
        let path = defaultsFile
        return await Task.detached(priority: .utility) {
            guard let data = FileManager.default.contents(atPath: path) else { return CommandDefaults() }
            do {
                return try JSONDecoder().decode(CommandDefaults.self, from: data)
            } catch {
                Ghostty.logger.warning("command-defaults.json is unreadable — loading as unset: \(error)")
                return CommandDefaults()
            }
        }.value
    }

    // MARK: - Save

    func save(_ commands: [SavedCommand]) async throws {
        try await write(JSONEncoder().encode(commands), to: commandsFile, via: commandsTempFile)
    }

    func saveDefaults(_ defaults: CommandDefaults) async throws {
        try await write(JSONEncoder().encode(defaults), to: defaultsFile, via: defaultsTempFile)
    }

    private func write(_ data: Data, to finalPath: String, via tmpPath: String) async throws {
        let dir = clearwayDir

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    let fm = FileManager.default
                    if !fm.fileExists(atPath: dir) {
                        try fm.createDirectory(
                            atPath: dir,
                            withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700]
                        )
                    }
                    // Write to a temp file and rename over the final path, so a reader never
                    // sees a partial write.
                    // `createFile` reports failure by returning false, and a temp file that was
                    // never written makes `replaceItemAt` throw "no such file" against the temp
                    // path — naming the wrong file and hiding the full disk or unwritable
                    // directory that actually stopped the save.
                    guard fm.createFile(
                        atPath: tmpPath,
                        contents: data,
                        attributes: [.posixPermissions: 0o600]
                    ) else {
                        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmpPath])
                    }
                    _ = try fm.replaceItemAt(URL(fileURLWithPath: finalPath), withItemAt: URL(fileURLWithPath: tmpPath))
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
