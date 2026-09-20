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
        try await store.save(SavedCommandsPayload(commands: original, lastRunId: nil))

        let loaded = await store.load()

        XCTAssertEqual(
            loaded.commands,
            original,
            "Array order is display order — the store must not sort"
        )
        XCTAssertEqual(loaded.commands.map(\.name), ["Review the PR", "Dev server"])
    }

    func testSaveThenLoadPreservesTheLastRunId() async throws {
        let payload = SavedCommandsPayload(
            commands: [terminalCommand, agentCommand],
            lastRunId: agentCommand.id
        )
        try await store.save(payload)

        let loaded = await store.load()

        XCTAssertEqual(loaded, payload)
    }

    func testSaveCreatesDirectoryAndFileWithRestrictivePermissions() async throws {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: clearwayDir),
            "The commands directory must not exist before the first save"
        )

        try await store.save(SavedCommandsPayload(commands: [terminalCommand], lastRunId: nil))

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: commandsFile))
        let dirMode = try fm.attributesOfItem(atPath: clearwayDir)[.posixPermissions] as? NSNumber
        let fileMode = try fm.attributesOfItem(atPath: commandsFile)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirMode?.int16Value, 0o700)
        XCTAssertEqual(fileMode?.int16Value, 0o600)
    }

    func testSaveLeavesNoTempFileBehind() async throws {
        try await store.save(SavedCommandsPayload(commands: [terminalCommand], lastRunId: nil))

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

        try await storeA.save(SavedCommandsPayload(commands: [terminalCommand], lastRunId: nil))

        let loadedB = await storeB.load()
        XCTAssertEqual(loadedB, .empty, "Project B must not see project A's commands")
        let loadedA = await storeA.load()
        XCTAssertEqual(loadedA.commands, [terminalCommand], "Project A still loads its own list")

        try await storeB.save(SavedCommandsPayload(commands: [agentCommand], lastRunId: nil))

        let reloadedA = await storeA.load()
        XCTAssertEqual(
            reloadedA.commands,
            [terminalCommand],
            "A save through B must not reach project A"
        )
    }

    func testSaveOverwritesThePreviousList() async throws {
        try await store.save(
            SavedCommandsPayload(commands: [terminalCommand, agentCommand], lastRunId: nil)
        )
        try await store.save(SavedCommandsPayload(commands: [agentCommand], lastRunId: nil))

        let loaded = await store.load()
        XCTAssertEqual(loaded.commands, [agentCommand])
    }

    // MARK: - Legacy files and wire format

    /// Every `commands.json` written before the payload existed holds a bare array. `load()` moves
    /// what it cannot decode aside, so failing to read one would rename the user's list to
    /// `commands.json.corrupt` and log it as corruption.
    func testLegacyBareArrayLoadsWithNothingRemembered() async throws {
        try writeCommandsFile("""
        [{
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Dev server",
          "kind": "terminal",
          "text": "bin/dev",
          "agent": "claude",
          "autoRun": true
        }]
        """)

        let loaded = await store.load()

        XCTAssertEqual(loaded.commands, [terminalCommand])
        XCTAssertNil(loaded.lastRunId)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: corruptFile),
            "A legacy file is not corrupt and must not be moved aside"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: commandsFile))
    }

    /// `lastRunId` decodes leniently. The file is advertised as hand-repairable, so a typo in the
    /// one field the user never asked for must not throw and send a list of working commands down
    /// the corrupt path — losing the preference costs nothing, losing the list costs everything.
    func testAnUnparseableLastRunIdLoadsAsNothingRememberedAndKeepsTheList() async throws {
        try writeCommandsFile("""
        {
          "commands": [{
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Dev server",
            "kind": "terminal",
            "text": "bin/dev",
            "agent": "claude",
            "autoRun": true
          }],
          "lastRunId": "not-a-uuid"
        }
        """)

        let loaded = await store.load()

        XCTAssertEqual(loaded.commands, [terminalCommand])
        XCTAssertNil(loaded.lastRunId)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: corruptFile),
            "A bad id is not a corrupt document and must not take the command list with it"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: commandsFile))
    }

    /// Pins the stored document shape. A round-trip test cannot catch a renamed key.
    func testPayloadDecodesFromItsStoredBytes() throws {
        let decoded = try JSONDecoder().decode(SavedCommandsPayload.self, from: Data("""
        {
          "commands": [{
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Dev server",
            "kind": "terminal",
            "text": "bin/dev",
            "agent": "claude",
            "autoRun": true
          }],
          "lastRunId": "11111111-1111-1111-1111-111111111111"
        }
        """.utf8))

        XCTAssertEqual(decoded.commands, [terminalCommand])
        XCTAssertEqual(decoded.lastRunId, terminalCommand.id)
    }

    /// A document written before anything was run carries no `lastRunId` key at all.
    func testPayloadWithoutTheLastRunIdKeyDecodesAsNothingRemembered() throws {
        let decoded = try JSONDecoder().decode(SavedCommandsPayload.self, from: Data("""
        {
          "commands": [{
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Dev server",
            "kind": "terminal",
            "text": "bin/dev",
            "agent": "claude",
            "autoRun": true
          }]
        }
        """.utf8))

        XCTAssertEqual(decoded.commands, [terminalCommand])
        XCTAssertNil(decoded.lastRunId)
    }

    // MARK: - Degraded files

    func testLoadMissingFileReturnsEmpty() async {
        let loaded = await store.load()
        XCTAssertEqual(loaded, .empty)
    }

    func testLoadCorruptFileReturnsEmpty() async throws {
        try writeCommandsFile("not valid json {{{")

        let loaded = await store.load()
        XCTAssertEqual(loaded, .empty, "Corrupt JSON loads as empty rather than throwing")
    }

    func testLoadFileWithMissingFieldReturnsEmpty() async throws {
        try writeCommandsFile(#"[{"id":"11111111-1111-1111-1111-111111111111","name":"Dev"}]"#)

        let loaded = await store.load()
        XCTAssertEqual(loaded, .empty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: corruptFile),
            "A malformed element fails the legacy decode too, so the file is genuinely corrupt"
        )
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

        XCTAssertEqual(
            loaded,
            .empty,
            "An unknown kind takes the file down rather than losing its kind"
        )
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
        try await store.save(SavedCommandsPayload(commands: [terminalCommand], lastRunId: nil))

        _ = await store.load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptFile))
    }
}
