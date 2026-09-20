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

    @Published private(set) var lastRunId: UUID?

    /// The id from `command-defaults.json`, held raw. Reading it goes through `afterCreateCommand`,
    /// so an id that no longer names a live agent command reads as None without the stored id being
    /// rewritten away.
    @Published private(set) var defaults = CommandDefaults()

    /// Resolved against the live list on every read, so an id naming a command that has since been
    /// deleted reads as nothing remembered. No delete path cleans it up.
    var lastRunCommand: SavedCommand? { commands.first { $0.id == lastRunId } }

    /// What the Run button's label half runs. The remembered command when one resolves, the first
    /// command in display order otherwise, so the button is a split button from the first launch
    /// and only an empty list leaves it without an action.
    var primaryCommand: SavedCommand? { lastRunCommand ?? commands.first }

    /// The Run button's label, which names what a click will do rather than reading "Run". An empty
    /// list has no primary command, so it keeps the generic word over the editor door alone.
    var runButtonTitle: String { primaryCommand?.name ?? "Run" }

    /// The dropdown half's items: everything the label half does not already run. A one-command
    /// list therefore lists no commands at all.
    var menuCommands: [SavedCommand] {
        let primaryId = primaryCommand?.id
        return commands.filter { $0.id != primaryId }
    }

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
        async let loadedPayload = store.load()
        async let loadedDefaults = store.loadDefaults()
        let (payload, slots) = await (loadedPayload, loadedDefaults)
        commands = payload.commands
        lastRunId = payload.lastRunId
        defaults = slots
    }

    var afterCreateCommand: SavedCommand? {
        CommandDefaults.resolve(defaults.afterCreate, in: commands)
    }

    /// The one answer to "which commands may run as an agent", so the Start Now menu, the Start
    /// Task sheet's picker and the default slot cannot disagree.
    var agentCommands: [SavedCommand] {
        SavedCommand.filter(commands, by: .agent)
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

    /// Records the command as the last one used, on pick rather than on a successful launch: a
    /// command that failed to start is still the last one the user reached for. Re-running the
    /// command already recorded writes nothing — that is the label half's every click, and the
    /// bytes would be identical.
    func recordLastRun(_ command: SavedCommand) {
        guard lastRunId != command.id else { return }
        lastRunId = command.id
        save()
    }

    /// Clearing is refused while the stored id resolves to nothing. The picker is seeded from
    /// `afterCreateCommand`, so a stale id already reads as None there and an untouched picker is
    /// indistinguishable from the operator choosing None — writing it back would drop an id the
    /// store keeps on purpose, one that may name a command a reverted `commands.json` edit brings
    /// back. Clearing a slot that does resolve is the operator's own pick and goes through.
    func setAfterCreateDefault(_ id: UUID?) {
        guard id != nil || afterCreateCommand != nil else { return }
        guard defaults.afterCreate != id else { return }
        defaults.afterCreate = id
        saveDefaults()
    }

    // MARK: - Persistence

    private func save() {
        let snapshot = SavedCommandsPayload(commands: commands, lastRunId: lastRunId)
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
