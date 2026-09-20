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
    private func persistedCommands(matching expected: [SavedCommand]) async -> [SavedCommand] {
        let deadline = Date().addingTimeInterval(2)
        var loaded = await store.load().commands
        while loaded != expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            loaded = await store.load().commands
        }
        return loaded
    }

    private func persistedLastRunId(matching expected: UUID?) async -> UUID? {
        let deadline = Date().addingTimeInterval(2)
        var loaded = await store.load().lastRunId
        while loaded != expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            loaded = await store.load().lastRunId
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

    func testPrimaryCommandFallsBackToTheFirstOnceTheRecordedCommandIsDeleted() {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Test", text: "bin/test")
        manager.add(first)
        manager.add(second)
        manager.recordLastRun(second)

        manager.delete(second)

        XCTAssertEqual(manager.primaryCommand, first)
    }
}
