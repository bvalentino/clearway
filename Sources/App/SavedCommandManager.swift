import Foundation
import SwiftUI

/// One project's ordered list of saved commands and the default slot that indexes it, owned by
/// that project's window.
///
/// Every mutation rewrites the whole array through `SavedCommandStore`. The file is not watched, so
/// an edit made outside the app — in a text editor, or by `git pull` — shows once the window is
/// reopened.
@MainActor
final class SavedCommandManager: ObservableObject {
    @Published private(set) var commands: [SavedCommand] = []

    /// The id from `command-defaults.json`, held raw. Reading it goes through `afterCreateCommand`,
    /// so an id that no longer names a live agent command reads as None without the stored id being
    /// rewritten away.
    @Published private(set) var defaults = CommandDefaults()

    private let store: SavedCommandStore

    /// The save in flight, if any. Each new save awaits it before writing.
    private var pendingSave: Task<Void, Never>?

    private var hasLoaded = false

    init(projectPath: String) {
        self.store = SavedCommandStore(projectPath: projectPath)
    }

    /// Reads the file once, and marks itself done before the read starts: a second read could land
    /// while a save is still in flight and replace the live list with the pre-save file. There is
    /// no reload path.
    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        commands = await store.load()
        defaults = await store.loadDefaults()
    }

    var afterCreateCommand: SavedCommand? {
        CommandDefaults.resolve(defaults.afterCreate, in: commands)
    }

    // MARK: - Mutations

    func add(_ command: SavedCommand) {
        commands.append(command)
        save()
    }

    /// Replaces the command with the same id, keeping its position. No-ops if the id is not found.
    func update(_ command: SavedCommand) {
        guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return }
        commands[index] = command
        save()
    }

    func delete(_ command: SavedCommand) {
        commands.removeAll { $0.id == command.id }
        save()
    }

    /// Offsets are against the unfiltered array, so a move is refused outright while a filter is
    /// on: one computed against a visible subset would rewrite the wrong positions in the full
    /// array.
    func move(fromOffsets source: IndexSet, toOffset destination: Int, filter: CommandFilter) {
        guard !filter.isActive else { return }
        commands.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func setAfterCreateDefault(_ id: UUID?) {
        defaults.afterCreate = id
        saveDefaults()
    }

    // MARK: - Persistence

    private func save() {
        let snapshot = commands
        let store = self.store
        enqueue("commands") { try await store.save(snapshot) }
    }

    private func saveDefaults() {
        let snapshot = defaults
        let store = self.store
        enqueue("defaults") { try await store.saveDefaults(snapshot) }
    }

    /// Chains each write onto the one before it — commands and defaults share the chain, so two
    /// writes cannot reach the store's queue out of order. Independent `Task`s are handed over in
    /// whatever order the scheduler picks, so two quick mutations could otherwise land with the
    /// earlier snapshot last and drop the newer one from disk.
    private func enqueue(_ label: String, _ write: @escaping @Sendable () async throws -> Void) {
        let previous = pendingSave
        pendingSave = Task { @MainActor in
            await previous?.value
            do {
                try await write()
            } catch {
                Ghostty.logger.error("SavedCommandManager: failed to save \(label): \(error)")
            }
        }
    }
}
