import XCTest
@testable import Clearway

@MainActor
final class SavedCommandManagerTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-command-manager-tests" }

    private var store: SavedCommandStore!
    private var manager: SavedCommandManager!

    override func setUp() async throws {
        try await super.setUp()
        store = SavedCommandStore(projectPath: tempRoot)
        manager = SavedCommandManager(projectPath: tempRoot)
    }

    override func tearDown() async throws {
        manager = nil
        store = nil
        try await super.tearDown()
    }

    private func makeCommand(
        name: String,
        kind: SavedCommand.Kind = .terminal,
        text: String = "bin/dev",
        autoRun: Bool = true
    ) -> SavedCommand {
        SavedCommand(id: UUID(), name: name, kind: kind, text: text, agent: "claude", autoRun: autoRun)
    }

    /// Mutations persist through a fire-and-forget `Task`, so read the file back until it settles
    /// rather than assuming a fixed delay is enough.
    private func persisted<Value: Equatable>(
        _ field: KeyPath<SavedCommandsPayload, Value>,
        matching expected: Value
    ) async -> Value {
        let deadline = Date().addingTimeInterval(2)
        var loaded = await store.load()[keyPath: field]
        while loaded != expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            loaded = await store.load()[keyPath: field]
        }
        return loaded
    }

    private func persistedCommands(matching expected: [SavedCommand]) async -> [SavedCommand] {
        await persisted(\.commands, matching: expected)
    }

    private func persistedLastRunId(matching expected: UUID?) async -> UUID? {
        await persisted(\.lastRunId, matching: expected)
    }

    private func persistedDefaults(matching expected: CommandDefaults) async -> CommandDefaults {
        let deadline = Date().addingTimeInterval(2)
        var loaded = await store.loadDefaults()
        while loaded != expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            loaded = await store.loadDefaults()
        }
        return loaded
    }

    // MARK: - load

    func testLoadPopulatesTheListInFileOrder() async throws {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Review", kind: .agent, text: "Review the diff.")
        try await store.save(SavedCommandsPayload(commands: [first, second], lastRunId: nil))

        await manager.load()

        XCTAssertEqual(manager.commands, [first, second])
    }

    func testLoadOfAMissingFileLeavesTheListEmpty() async {
        await manager.load()
        XCTAssertEqual(manager.commands, [])
    }

    /// Only the first read happens, so a later one landing while a save is still in flight cannot
    /// revert the live list.
    func testASecondLoadDoesNotRereadTheFile() async throws {
        let existing = makeCommand(name: "Dev")
        try await store.save(SavedCommandsPayload(commands: [existing], lastRunId: nil))
        await manager.load()

        try await store.save(.empty)
        await manager.load()

        XCTAssertEqual(manager.commands, [existing])
    }

    // MARK: - Mutations

    func testAddAppendsAndPersists() async {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")

        manager.add(first)
        manager.add(second)

        XCTAssertEqual(manager.commands, [first, second])
        let persisted = await persistedCommands(matching: [first, second])
        XCTAssertEqual(persisted, [first, second])
    }

    func testUpdateReplacesInPlaceAndPersists() async {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        manager.add(first)
        manager.add(second)

        var edited = first
        edited.name = "Dev server"
        edited.autoRun = false
        manager.update(edited)

        XCTAssertEqual(manager.commands, [edited, second], "An edit keeps the command's position")
        let persisted = await persistedCommands(matching: [edited, second])
        XCTAssertEqual(persisted, [edited, second])
    }

    func testUpdateOfAnUnknownIdChangesNothing() async {
        let existing = makeCommand(name: "Dev")
        manager.add(existing)

        manager.update(makeCommand(name: "Ghost"))

        XCTAssertEqual(manager.commands, [existing])
        let persisted = await persistedCommands(matching: [existing])
        XCTAssertEqual(persisted, [existing])
    }

    func testDeleteRemovesAndPersists() async {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        manager.add(first)
        manager.add(second)

        manager.delete(first)

        XCTAssertEqual(manager.commands, [second])
        let persisted = await persistedCommands(matching: [second])
        XCTAssertEqual(persisted, [second])
    }

    func testMoveReordersAndPersists() async {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        let third = makeCommand(name: "Review", kind: .agent, text: "Review the diff.")
        manager.add(first)
        manager.add(second)
        manager.add(third)

        manager.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, filter: .all)

        XCTAssertEqual(manager.commands, [third, first, second])
        let persisted = await persistedCommands(matching: [third, first, second])
        XCTAssertEqual(persisted, [third, first, second])
    }

    /// Offsets arrive against the visible subset, so applying them to the full array would
    /// reorder commands the user cannot see — and persist it.
    func testMoveUnderAnActiveFilterIsRefused() async {
        let agent = makeCommand(name: "Review", kind: .agent, text: "Review the diff.")
        let firstTerminal = makeCommand(name: "Dev")
        let secondTerminal = makeCommand(name: "Test", text: "bin/test")
        manager.add(agent)
        manager.add(firstTerminal)
        manager.add(secondTerminal)

        // Dragging the second visible row above the first under the `.terminal` filter: offsets
        // 1 → 0 would swap `agent` and `firstTerminal` in the full array.
        manager.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, filter: .terminal)

        XCTAssertEqual(manager.commands, [agent, firstTerminal, secondTerminal])
        let persisted = await persistedCommands(matching: [agent, firstTerminal, secondTerminal])
        XCTAssertEqual(persisted, [agent, firstTerminal, secondTerminal])
    }

    // MARK: - Last run

    func testLastRunCommandIsNilBeforeAnythingIsRecorded() {
        manager.add(makeCommand(name: "Dev"))

        XCTAssertNil(manager.lastRunCommand)
    }

    func testRecordLastRunResolvesToTheRecordedCommand() {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        manager.add(first)
        manager.add(second)

        manager.recordLastRun(second)

        XCTAssertEqual(manager.lastRunCommand, second)
    }

    /// No delete path clears the id — the resolution against the live list is what makes a deleted
    /// command read as nothing remembered.
    func testDeletingTheRecordedCommandLeavesNothingRemembered() {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        manager.add(first)
        manager.add(second)
        manager.recordLastRun(second)

        manager.delete(first)
        XCTAssertEqual(manager.lastRunCommand, second, "Deleting a different command changes nothing")

        manager.delete(second)
        XCTAssertNil(manager.lastRunCommand)
    }

    func testRecordLastRunSurvivesAReload() async {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        manager.add(first)
        manager.add(second)

        manager.recordLastRun(second)

        let persisted = await persistedLastRunId(matching: second.id)
        XCTAssertEqual(persisted, second.id)

        let reloaded = SavedCommandManager(projectPath: tempRoot)
        await reloaded.load()

        XCTAssertEqual(reloaded.lastRunCommand, second)
    }

    /// Upgrade day for every project that already had commands: the bare array loads, the first
    /// run rewrites the file as a payload, and a later window reads back both halves. The store
    /// covers the legacy decode and the record/reload covers an empty file, but neither walks the
    /// transition, where losing the commands would leave both of them green.
    func testALegacyFileKeepsItsCommandsOnceSomethingIsRun() async throws {
        let clearwayDir = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearwayDir, withIntermediateDirectories: true)
        let legacy = makeCommand(name: "Dev")
        let encoded = try JSONEncoder().encode([legacy])
        FileManager.default.createFile(
            atPath: (clearwayDir as NSString).appendingPathComponent("commands.json"),
            contents: encoded
        )

        await manager.load()
        XCTAssertEqual(manager.commands, [legacy])

        manager.recordLastRun(legacy)
        let persisted = await persistedLastRunId(matching: legacy.id)
        XCTAssertEqual(persisted, legacy.id, "The first run rewrites the bare array as a payload")

        let reopened = SavedCommandManager(projectPath: tempRoot)
        await reopened.load()

        XCTAssertEqual(reopened.commands, [legacy])
        XCTAssertEqual(reopened.lastRunCommand, legacy)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (clearwayDir as NSString).appendingPathComponent("commands.json.corrupt")
            ),
            "The upgrade must not quarantine the list it just read"
        )
    }

    // MARK: - Primary command

    func testPrimaryCommandIsNilWhenThereAreNoCommands() {
        XCTAssertNil(manager.primaryCommand)
    }

    func testPrimaryCommandIsTheFirstCommandBeforeAnythingIsRecorded() {
        let first = makeCommand(name: "Dev")
        manager.add(first)
        manager.add(makeCommand(name: "Test", text: "bin/test"))

        XCTAssertEqual(manager.primaryCommand, first)
    }

    func testPrimaryCommandIsTheRecordedCommand() {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        manager.add(first)
        manager.add(second)

        manager.recordLastRun(second)

        XCTAssertEqual(manager.primaryCommand, second)
    }

    /// `update` keeps the command's id, so the memory survives an edit and everything derived from
    /// it has to carry the new value — the label half runs `text`, and running the pre-edit one is
    /// the regression this resolves-on-read rule exists to prevent.
    func testPrimaryCommandCarriesAnEditToTheRecordedCommand() {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        manager.add(first)
        manager.add(second)
        manager.recordLastRun(second)

        var edited = second
        edited.name = "Test (watch)"
        edited.text = "bin/test --watch"
        manager.update(edited)

        XCTAssertEqual(manager.lastRunCommand, edited)
        XCTAssertEqual(manager.primaryCommand, edited)
        XCTAssertEqual(manager.runButtonTitle, "Test (watch)")
    }

    func testPrimaryCommandFallsBackToTheFirstOnceTheRecordedCommandIsDeleted() {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        manager.add(first)
        manager.add(second)
        manager.recordLastRun(second)

        manager.delete(second)

        XCTAssertEqual(manager.primaryCommand, first)
    }

    // MARK: - Run button title

    func testRunButtonTitleIsRunWhenThereAreNoCommands() {
        XCTAssertEqual(manager.runButtonTitle, "Run")
    }

    func testRunButtonTitleNamesTheFirstCommandBeforeAnythingIsRecorded() {
        manager.add(makeCommand(name: "Dev"))
        manager.add(makeCommand(name: "Test", text: "bin/test"))

        XCTAssertEqual(manager.runButtonTitle, "Dev")
    }

    func testRunButtonTitleNamesTheRecordedCommand() {
        let second = makeCommand(name: "Test", text: "bin/test")
        manager.add(makeCommand(name: "Dev"))
        manager.add(second)

        manager.recordLastRun(second)

        XCTAssertEqual(manager.runButtonTitle, "Test")
    }

    // MARK: - Menu commands

    func testMenuCommandsIsEmptyWhenThereAreNoCommands() {
        XCTAssertTrue(manager.menuCommands.isEmpty)
    }

    func testMenuCommandsIsEmptyForASingleCommand() {
        manager.add(makeCommand(name: "Dev"))

        XCTAssertTrue(manager.menuCommands.isEmpty)
    }

    func testMenuCommandsOmitsThePrimaryCommand() {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        let third = makeCommand(name: "Lint", text: "bin/lint")
        manager.add(first)
        manager.add(second)
        manager.add(third)

        XCTAssertEqual(manager.menuCommands, [second, third])
    }

    func testMenuCommandsOmitsTheRecordedCommandAndKeepsDisplayOrder() {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        let third = makeCommand(name: "Lint", text: "bin/lint")
        manager.add(first)
        manager.add(second)
        manager.add(third)

        manager.recordLastRun(second)

        XCTAssertEqual(manager.menuCommands, [first, third])
    }

    // MARK: - Defaults

    func testLoadPublishesTheDefaultsOnDisk() async throws {
        let stored = CommandDefaults(afterCreate: UUID())
        try await store.saveDefaults(stored)

        await manager.load()

        XCTAssertEqual(manager.defaults, stored)
    }

    func testLoadOfAMissingDefaultsFileLeavesTheSlotUnset() async {
        await manager.load()
        XCTAssertEqual(manager.defaults, CommandDefaults())
    }

    func testSetAfterCreateDefaultPersistsForTheNextManager() async {
        let agent = makeCommand(name: "Kickoff", kind: .agent, text: "Start on {{ task_path }}.")
        manager.add(agent)

        manager.setAfterCreateDefault(agent.id)

        XCTAssertEqual(manager.defaults.afterCreate, agent.id)
        let persisted = await persistedDefaults(matching: CommandDefaults(afterCreate: agent.id))
        XCTAssertEqual(persisted.afterCreate, agent.id)

        let reopened = SavedCommandManager(projectPath: tempRoot)
        await reopened.load()
        XCTAssertEqual(reopened.defaults.afterCreate, agent.id)
        XCTAssertEqual(reopened.afterCreateCommand, agent)
    }

    func testSetAfterCreateDefaultToNilPersistsTheClearedSlot() async {
        let agent = makeCommand(name: "Kickoff", kind: .agent, text: "Start on {{ task_path }}.")
        manager.add(agent)
        manager.setAfterCreateDefault(agent.id)
        _ = await persistedDefaults(matching: CommandDefaults(afterCreate: agent.id))

        manager.setAfterCreateDefault(nil)

        XCTAssertNil(manager.defaults.afterCreate)
        let persisted = await persistedDefaults(matching: CommandDefaults())
        XCTAssertEqual(persisted, CommandDefaults())

        let reopened = SavedCommandManager(projectPath: tempRoot)
        await reopened.load()
        XCTAssertNil(reopened.defaults.afterCreate)
    }

    /// The sheet's picker is seeded from `afterCreateCommand`, so a stale id reads as None there
    /// and an untouched picker looks exactly like the operator choosing None. Clearing is
    /// therefore refused while the slot resolves to nothing: the id survives for the day the
    /// operator reverts the `commands.json` edit that hid it.
    func testSetAfterCreateDefaultToNilKeepsAStaleId() async {
        let stale = UUID()
        manager.add(makeCommand(name: "Kickoff", kind: .agent, text: "Start."))
        manager.setAfterCreateDefault(stale)
        _ = await persistedDefaults(matching: CommandDefaults(afterCreate: stale))
        XCTAssertNil(manager.afterCreateCommand, "the id names no live agent command")

        manager.setAfterCreateDefault(nil)

        XCTAssertEqual(manager.defaults.afterCreate, stale)
        let persisted = await persistedDefaults(matching: CommandDefaults(afterCreate: stale))
        XCTAssertEqual(persisted.afterCreate, stale, "the stored id is not rewritten away")
    }

    func testAfterCreateCommandIsNilForAnUnsetSlot() {
        manager.add(makeCommand(name: "Kickoff", kind: .agent, text: "Start."))

        XCTAssertNil(manager.afterCreateCommand)
    }

    func testAfterCreateCommandIsNilForAnIdNamingNoCommand() {
        manager.add(makeCommand(name: "Kickoff", kind: .agent, text: "Start."))

        manager.setAfterCreateDefault(UUID())

        XCTAssertNil(manager.afterCreateCommand)
    }

    func testAfterCreateCommandIsNilForATerminalKindCommand() {
        let terminal = makeCommand(name: "Dev")
        manager.add(terminal)

        manager.setAfterCreateDefault(terminal.id)

        XCTAssertNil(manager.afterCreateCommand)
    }

    func testAfterCreateCommandResolvesALiveAgentCommand() {
        let agent = makeCommand(name: "Kickoff", kind: .agent, text: "Start on {{ task_path }}.")
        manager.add(makeCommand(name: "Dev"))
        manager.add(agent)

        manager.setAfterCreateDefault(agent.id)

        XCTAssertEqual(manager.afterCreateCommand, agent)
    }
}
