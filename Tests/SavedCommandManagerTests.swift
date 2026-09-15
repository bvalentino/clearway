import XCTest
@testable import Clearway

@MainActor
final class SavedCommandManagerTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-command-manager-tests" }

    private var store: SavedCommandStore!
    private var manager: SavedCommandManager!

    override func setUp() async throws {
        try await super.setUp()
        store = SavedCommandStore(directory: tempRoot)
        manager = SavedCommandManager(store: store)
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
        var loaded = await store.load()
        while loaded != expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            loaded = await store.load()
        }
        return loaded
    }

    // MARK: - load

    func testLoadPopulatesTheListInFileOrder() async throws {
        let first = makeCommand(name: "Dev")
        let second = makeCommand(name: "Review", kind: .agent, text: "Review the diff.")
        try await store.save([first, second])

        await manager.load()

        XCTAssertEqual(manager.commands, [first, second])
    }

    func testLoadOfAMissingFileLeavesTheListEmpty() async {
        await manager.load()
        XCTAssertEqual(manager.commands, [])
    }

    /// Every project window asks the process-wide manager to load; only the first read happens, so a
    /// window opened while another window's save is still in flight cannot revert the live list.
    func testASecondLoadDoesNotRereadTheFile() async throws {
        let existing = makeCommand(name: "Dev")
        try await store.save([existing])
        await manager.load()

        try await store.save([])
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

        manager.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(manager.commands, [third, first, second])
        let persisted = await persistedCommands(matching: [third, first, second])
        XCTAssertEqual(persisted, [third, first, second])
    }
}
