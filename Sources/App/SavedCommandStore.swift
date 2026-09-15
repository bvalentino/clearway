import Foundation
import os

/// Reads and writes the global command list at `~/.clearway/commands.json`.
///
/// The array is stored and returned in order — that order is the display order, so nothing here
/// sorts or re-keys. A missing, unreadable or undecodable file loads as empty and is only
/// overwritten when the user next changes something, so a transient read failure loses nothing.
final class SavedCommandStore: Sendable {

    private let directory: String

    /// Serialises writes so two mutations in flight cannot interleave on the same file.
    private let writeQueue = DispatchQueue(label: "app.getclearway.mac.SavedCommandStore.write")

    /// `directory` is a test seam, not a setting: the global path is the default and the only one
    /// the app ever passes.
    init(directory: String = "~/.clearway") {
        self.directory = (directory as NSString).expandingTildeInPath
    }

    // MARK: - Paths

    private var commandsFile: String {
        (directory as NSString).appendingPathComponent("commands.json")
    }

    private var commandsTempFile: String {
        (directory as NSString).appendingPathComponent("commands.json.tmp")
    }

    // MARK: - Load

    func load() async -> [SavedCommand] {
        let path = commandsFile
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: path) else { return [] }
            guard let data = fm.contents(atPath: path) else {
                Ghostty.logger.warning("commands.json is unreadable — loading as empty.")
                return []
            }
            guard let commands = try? JSONDecoder().decode([SavedCommand].self, from: data) else {
                Ghostty.logger.warning("commands.json is corrupt — loading as empty.")
                return []
            }
            return commands
        }.value
    }

    // MARK: - Save

    func save(_ commands: [SavedCommand]) async throws {
        let data = try JSONEncoder().encode(commands)
        let dir = directory
        let tmpPath = commandsTempFile
        let finalPath = commandsFile

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
                    fm.createFile(atPath: tmpPath, contents: data, attributes: [.posixPermissions: 0o600])
                    _ = try fm.replaceItemAt(URL(fileURLWithPath: finalPath), withItemAt: URL(fileURLWithPath: tmpPath))
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
