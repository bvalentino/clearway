import XCTest
@testable import Clearway

@MainActor
final class SavedCommandStoreTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-command-store-tests" }

    private var store: SavedCommandStore!

    override func setUp() async throws {
        try await super.setUp()
        store = SavedCommandStore(projectPath: tempRoot)
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    private var clearwayDir: String {
        (tempRoot as NSString).appendingPathComponent(".clearway")
    }

    private var commandsFile: String {
        (clearwayDir as NSString).appendingPathComponent("commands.json")
    }

    private var corruptFile: String {
        (clearwayDir as NSString).appendingPathComponent("commands.json.corrupt")
    }

    private func writeCommandsFile(_ contents: String) throws {
        try FileManager.default.createDirectory(atPath: clearwayDir, withIntermediateDirectories: true)
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
            FileManager.default.fileExists(atPath: clearwayDir),
            "The commands directory must not exist before the first save"
        )

        try await store.save([terminalCommand])

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: commandsFile))
        let dirMode = try fm.attributesOfItem(atPath: clearwayDir)[.posixPermissions] as? NSNumber
        let fileMode = try fm.attributesOfItem(atPath: commandsFile)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirMode?.int16Value, 0o700)
        XCTAssertEqual(fileMode?.int16Value, 0o600)
    }

    func testSaveLeavesNoTempFileBehind() async throws {
        try await store.save([terminalCommand])

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (clearwayDir as NSString).appendingPathComponent("commands.json.tmp")
            ),
            "commands.json.tmp should be renamed away by the atomic save"
        )
    }

    /// The reason the store takes a project path at all: one project's list is invisible to
    /// another's, and nothing else in the suite pins that.
    func testStoresOnDifferentProjectPathsDoNotSeeEachOther() async throws {
        let projectA = (tempRoot as NSString).appendingPathComponent("a")
        let projectB = (tempRoot as NSString).appendingPathComponent("b")
        let storeA = SavedCommandStore(projectPath: projectA)
        let storeB = SavedCommandStore(projectPath: projectB)

        try await storeA.save([terminalCommand])

        let loadedB = await storeB.load()
        XCTAssertEqual(loadedB, [], "Project B must not see project A's commands")
        let loadedA = await storeA.load()
        XCTAssertEqual(loadedA, [terminalCommand], "Project A still loads its own list")

        try await storeB.save([agentCommand])

        let reloadedA = await storeA.load()
        XCTAssertEqual(reloadedA, [terminalCommand], "A save through B must not reach project A")
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

    /// An unrecognized kind is a decode error like any other, so the whole file is unreadable and
    /// goes the way every unreadable file goes.
    func testLoadUnknownKindIsTreatedAsCorrupt() async throws {
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

        XCTAssertEqual(loaded, [], "An unknown kind takes the file down rather than losing its kind")
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandsFile))
    }

    // MARK: - Quarantine

    /// The next save writes a fresh `commands.json`, so the unreadable one has to survive under
    /// another name or the user loses the only copy they could have repaired.
    func testLoadMovesACorruptFileAsideWithItsOriginalBytes() async throws {
        let original = "not valid json {{{"
        try writeCommandsFile(original)

        _ = await store.load()

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: commandsFile), "The unreadable file is renamed, not copied")
        XCTAssertEqual(fm.contents(atPath: corruptFile), Data(original.utf8))
    }

    func testLoadOverwritesAnOlderCorruptFile() async throws {
        try writeCommandsFile("first corruption")
        _ = await store.load()

        try writeCommandsFile("second corruption")
        _ = await store.load()

        XCTAssertEqual(
            FileManager.default.contents(atPath: corruptFile),
            Data("second corruption".utf8),
            "The list Clearway was last unable to read is the one worth keeping"
        )
    }

    func testLoadMissingFileLeavesNoCorruptFileBehind() async {
        _ = await store.load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptFile))
    }

    func testLoadValidFileLeavesNoCorruptFileBehind() async throws {
        try await store.save([terminalCommand])

        _ = await store.load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptFile))
    }
}
