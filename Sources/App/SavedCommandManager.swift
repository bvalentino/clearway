import Foundation
import SwiftUI

/// One project's ordered list of saved commands, owned by that project's window.
///
/// Every mutation rewrites the whole array through `SavedCommandStore`. The file is not watched, so
/// an edit made outside the app — in a text editor, or by `git pull` — shows once the window is
/// reopened.
@MainActor
final class SavedCommandManager: ObservableObject {
    @Published private(set) var commands: [SavedCommand] = []

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

    // MARK: - Persistence

    /// Chains each write onto the one before it. Independent `Task`s reach the store's write queue
    /// in whatever order the scheduler hands them over, so two quick mutations could otherwise land
    /// with the earlier snapshot last and drop the newer one from disk.
    private func save() {
        let snapshot = commands
        let previous = pendingSave
        pendingSave = Task { @MainActor in
            await previous?.value
            do {
                try await store.save(snapshot)
            } catch {
                Ghostty.logger.error("SavedCommandManager: failed to save commands: \(error)")
            }
        }
    }
}
