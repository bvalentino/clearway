import Foundation
import os

// MARK: - Payload

/// On-disk representation: the project's command list plus the id of the command last run from it.
/// Decodes older files that stored a bare `[SavedCommand]` array by leaving `lastRunId` nil.
struct SavedCommandsPayload: Codable, Equatable {
    var commands: [SavedCommand]
    var lastRunId: UUID?

    static let empty = SavedCommandsPayload(commands: [], lastRunId: nil)

    /// No defaults: `save()` builds the whole document, so a field added later must be a
    /// compile error there rather than an omission that erases it from disk on the next write.
    init(commands: [SavedCommand], lastRunId: UUID?) {
        self.commands = commands
        self.lastRunId = lastRunId
    }
}

/// Reads and writes one project's command document at `<projectPath>/.clearway/commands.json`,
/// beside that project's `groups.json`.
///
/// The command array is stored and returned in order — that order is the display order, so nothing
/// here sorts or re-keys. A missing file loads as empty. An unreadable or undecodable one loads as
/// empty too, but is moved aside to `commands.json.corrupt` first, so the next save cannot destroy
/// the only copy of a list the user can still repair by hand.
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

    // MARK: - Load

    func load() async -> SavedCommandsPayload {
        let path = commandsFile
        let corruptPath = commandsCorruptFile
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: path) else { return .empty }
            guard let data = fm.contents(atPath: path) else {
                Ghostty.logger.warning("commands.json is unreadable — loading as empty.")
                Self.moveAside(path, to: corruptPath)
                return .empty
            }
            do {
                return try JSONDecoder().decode(SavedCommandsPayload.self, from: data)
            } catch {
                // A file written before this store grew a payload holds a bare array. It is not
                // corrupt, and moving it aside would rename the user's list to `.corrupt`.
                if let legacy = try? JSONDecoder().decode([SavedCommand].self, from: data) {
                    return SavedCommandsPayload(commands: legacy, lastRunId: nil)
                }
                // The error names the offending key and index, which is what makes the file
                // hand-repairable — a bare "corrupt" tells its reader nothing.
                Ghostty.logger.warning("commands.json is corrupt — loading as empty: \(error)")
                Self.moveAside(path, to: corruptPath)
                return .empty
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

    // MARK: - Save

    func save(_ payload: SavedCommandsPayload) async throws {
        let data = try JSONEncoder().encode(payload)
        let dir = clearwayDir
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
