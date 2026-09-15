import Foundation
import SwiftUI

/// The process-wide ordered list of saved commands.
///
/// Every mutation rewrites the whole array through `SavedCommandStore`. There is no watcher: the
/// app is the only writer and there is one manager per process.
@MainActor
final class SavedCommandManager: ObservableObject {
    @Published private(set) var commands: [SavedCommand] = []

    private let store: SavedCommandStore

    /// The save in flight, if any. Each new save awaits it before writing.
    private var pendingSave: Task<Void, Never>?

    /// Set before the read starts, so a second window's `.task` cannot race the first one's.
    private var hasLoaded = false

    init(store: SavedCommandStore = SavedCommandStore()) {
        self.store = store
    }

    /// Reads the file once per process. Every project window asks, and only the first one reads:
    /// a later read could land while a save from another window is still in flight and replace the
    /// live list with the pre-save file. There is no reload path — the app is the only writer.
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

    /// Offsets are against the unfiltered array — the view refuses a move while a filter is on.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
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
