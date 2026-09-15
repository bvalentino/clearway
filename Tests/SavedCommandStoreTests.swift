import XCTest
@testable import Clearway

@MainActor
final class SavedCommandStoreTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-command-store-tests" }

    private var store: SavedCommandStore!

    override func setUp() async throws {
        try await super.setUp()
        store = SavedCommandStore(directory: tempRoot)
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    private var commandsFile: String {
        (tempRoot as NSString).appendingPathComponent("commands.json")
    }

    private func writeCommandsFile(_ contents: String) throws {
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: commandsFile, contents: Data(contents.utf8))
    }

    private let terminalCommand = SavedCommand(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "Dev server",
        kind: .terminal,
        text: "bin/dev",
        agent: "claude",
        autoRun: true
    )

    private let agentCommand = SavedCommand(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        name: "Review the PR",
        kind: .agent,
        text: "Review the current diff for correctness.",
        agent: "codex",
        autoRun: false
    )

    // MARK: - Codable round-trip

    func testCodableRoundTripPreservesEveryField() throws {
        let original = [terminalCommand, agentCommand]
        let decoded = try JSONDecoder().decode(
            [SavedCommand].self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.first?.kind, .terminal)
        XCTAssertEqual(decoded.last?.kind, .agent)
        XCTAssertEqual(decoded.last?.agent, "codex")
        XCTAssertEqual(decoded.last?.autoRun, false)
    }

    /// Pins the on-disk shape: a flat object per command with `kind` as its raw string. A renamed
    /// or restructured field would silently orphan every existing `commands.json`.
    func testEncodedShapeIsAFlatObjectPerCommand() throws {
        let data = try JSONEncoder().encode([agentCommand])
        let array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )

        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(
            Set(try XCTUnwrap(array.first).keys),
            ["id", "name", "kind", "text", "agent", "autoRun"]
        )
        XCTAssertEqual(array.first?["kind"] as? String, "agent")
    }

    // MARK: - save / load

    func testSaveThenLoadPreservesArrayOrder() async throws {
        let original = [agentCommand, terminalCommand]
        try await store.save(original)

        let loaded = await store.load()

        XCTAssertEqual(loaded, original, "Array order is display order — the store must not sort")
        XCTAssertEqual(loaded.map(\.name), ["Review the PR", "Dev server"])
    }

    func testSaveCreatesDirectoryAndFileWithRestrictivePermissions() async throws {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempRoot),
            "The commands directory must not exist before the first save"
        )

        try await store.save([terminalCommand])

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: commandsFile))
        let dirMode = try fm.attributesOfItem(atPath: tempRoot)[.posixPermissions] as? NSNumber
        let fileMode = try fm.attributesOfItem(atPath: commandsFile)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirMode?.int16Value, 0o700)
        XCTAssertEqual(fileMode?.int16Value, 0o600)
    }

    func testSaveLeavesNoTempFileBehind() async throws {
        try await store.save([terminalCommand])

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (tempRoot as NSString).appendingPathComponent("commands.json.tmp")
            ),
            "commands.json.tmp should be renamed away by the atomic save"
        )
    }

    func testSaveOverwritesThePreviousList() async throws {
        try await store.save([terminalCommand, agentCommand])
        try await store.save([agentCommand])

        let loaded = await store.load()
        XCTAssertEqual(loaded, [agentCommand])
    }

    // MARK: - Degraded files

    func testLoadMissingFileReturnsEmpty() async {
        let loaded = await store.load()
        XCTAssertEqual(loaded, [])
    }

    func testLoadCorruptFileReturnsEmpty() async throws {
        try writeCommandsFile("not valid json {{{")

        let loaded = await store.load()
        XCTAssertEqual(loaded, [], "Corrupt JSON loads as empty rather than throwing")
    }

    func testLoadFileWithMissingFieldReturnsEmpty() async throws {
        try writeCommandsFile(#"[{"id":"11111111-1111-1111-1111-111111111111","name":"Dev"}]"#)

        let loaded = await store.load()
        XCTAssertEqual(loaded, [])
    }

    func testLoadUnknownKindFallsBackToTerminal() async throws {
        try writeCommandsFile("""
        [{
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "From a newer Clearway",
          "kind": "wizard",
          "text": "bin/dev",
          "agent": "claude",
          "autoRun": true
        }]
        """)

        let loaded = await store.load()

        XCTAssertEqual(loaded.count, 1, "An unknown kind costs the command its kind, not the file")
        XCTAssertEqual(loaded.first?.kind, .terminal)
        XCTAssertEqual(loaded.first?.name, "From a newer Clearway")
    }
}
