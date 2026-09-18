import XCTest
@testable import Clearway

@MainActor
final class WorktreeGroupStoreTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-store-tests" }

    private var store: WorktreeGroupStore!

    override func setUp() async throws {
        try await super.setUp()
        store = WorktreeGroupStore(projectPath: tempRoot)
    }

    override func tearDown() async throws {
        store.stopWatching()
        store = nil
        try await super.tearDown()
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let original = WorktreeGroup(
            id: UUID(),
            name: "Feature",
            worktreeIds: ["branch-a", "branch-b"],
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        )

        let encoded = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([WorktreeGroup].self, from: encoded)

        XCTAssertEqual(decoded, [original])
        XCTAssertEqual(decoded.first?.id, original.id)
        XCTAssertEqual(decoded.first?.name, original.name)
        XCTAssertEqual(decoded.first?.worktreeIds, original.worktreeIds)
        XCTAssertEqual(decoded.first?.createdAt, original.createdAt)
    }

    // MARK: - Payload wire format
    //
    // These cases assert over literal bytes rather than a round trip: a round trip
    // cannot catch a renamed key or a renamed status slug, and a payload the decoder
    // rejects makes load() reset to .empty, wiping every group in the project.

    private static let groupJSON = """
    {"id":"1D2C3B4A-0000-4000-8000-000000000001","name":"Feature","worktreeIds":["/a"],"createdAt":123456789}
    """

    private static func payloadJSON(extraKeys: String = "") -> Data {
        Data("{\"groups\":[\(groupJSON)],\"defaultOrder\":[\"/a\",\"/b\"]\(extraKeys)}".utf8)
    }

    private func assertGroupsIntact(_ payload: WorktreeGroupsPayload, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(payload.groups.count, 1, file: file, line: line)
        XCTAssertEqual(payload.groups.first?.name, "Feature", file: file, line: line)
        XCTAssertEqual(payload.groups.first?.worktreeIds, ["/a"], file: file, line: line)
        XCTAssertEqual(payload.defaultOrder, ["/a", "/b"], file: file, line: line)
    }

    func testDecodesFileWrittenBeforeStatusesExisted() throws {
        let payload = try JSONDecoder().decode(WorktreeGroupsPayload.self, from: Self.payloadJSON())

        assertGroupsIntact(payload)
        XCTAssertEqual(payload.statuses, [:])
        XCTAssertEqual(payload.grouping, .group)
    }

    func testLoadKeepsGroupsOfFileWrittenBeforeStatusesExisted() async throws {
        try writeGroupsFile(Self.payloadJSON())

        let payload = await store.load()

        assertGroupsIntact(payload)
        XCTAssertEqual(payload.statuses, [:])
        XCTAssertEqual(payload.grouping, .group)
    }

    func testDecodeDropsUnrecognisedStatusSlug() throws {
        let data = Self.payloadJSON(extraKeys: ",\"statuses\":{\"/a\":\"todo\",\"/b\":\"bogus\"}")

        let payload = try JSONDecoder().decode(WorktreeGroupsPayload.self, from: data)

        assertGroupsIntact(payload)
        XCTAssertEqual(payload.statuses, ["/a": .todo])
    }

    /// A wrong-shaped value, not just a wrong slug: `groups.json` is hand-editable and the
    /// watcher fires on `.write`, so an editor that truncates before rewriting hands the
    /// decoder a value of the wrong type. That must cost the statuses, never the groups —
    /// `load()` answers a throw with `.empty`, which the next save writes over the file.
    func testDecodeKeepsGroupsWhenStatusesHasTheWrongShape() throws {
        let data = Self.payloadJSON(extraKeys: ",\"statuses\":[]")

        let payload = try JSONDecoder().decode(WorktreeGroupsPayload.self, from: data)

        assertGroupsIntact(payload)
        XCTAssertEqual(payload.statuses, [:])
    }

    func testDecodeKeepsGroupsWhenAStatusValueIsNotAString() throws {
        let data = Self.payloadJSON(extraKeys: ",\"statuses\":{\"/a\":1}")

        let payload = try JSONDecoder().decode(WorktreeGroupsPayload.self, from: data)

        assertGroupsIntact(payload)
        XCTAssertEqual(payload.statuses, [:])
    }

    func testDecodeKeepsGroupsWhenGroupingHasTheWrongShape() throws {
        let data = Self.payloadJSON(extraKeys: ",\"grouping\":0")

        let payload = try JSONDecoder().decode(WorktreeGroupsPayload.self, from: data)

        assertGroupsIntact(payload)
        XCTAssertEqual(payload.grouping, .group)
    }

    func testDecodeFallsBackToGroupForUnrecognisedGroupingSlug() throws {
        let data = Self.payloadJSON(extraKeys: ",\"grouping\":\"bogus\"")

        let payload = try JSONDecoder().decode(WorktreeGroupsPayload.self, from: data)

        assertGroupsIntact(payload)
        XCTAssertEqual(payload.grouping, .group)
    }

    func testDecodeReadsGroupingSlug() throws {
        let data = Self.payloadJSON(extraKeys: ",\"grouping\":\"status\"")

        let payload = try JSONDecoder().decode(WorktreeGroupsPayload.self, from: data)

        XCTAssertEqual(payload.grouping, .status)
    }

    func testPayloadRoundTripsStatusesAndGrouping() throws {
        let original = WorktreeGroupsPayload(
            groups: [],
            defaultOrder: ["/a"],
            statuses: ["/a": .inReview, "/b": .onHold],
            grouping: .none
        )

        let decoded = try JSONDecoder().decode(
            WorktreeGroupsPayload.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
    }

    func testLoadLegacyBareArrayFileKeepsGroups() async throws {
        try writeGroupsFile(Data("[\(Self.groupJSON)]".utf8))

        let payload = await store.load()

        XCTAssertEqual(payload.groups.count, 1)
        XCTAssertEqual(payload.groups.first?.name, "Feature")
        XCTAssertEqual(payload.defaultOrder, [])
        XCTAssertEqual(payload.statuses, [:])
        XCTAssertEqual(payload.grouping, .group)
    }

    private func writeGroupsFile(_ data: Data) throws {
        let clearwayDir = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearwayDir, withIntermediateDirectories: true)
        let groupsFile = (clearwayDir as NSString).appendingPathComponent("groups.json")
        FileManager.default.createFile(atPath: groupsFile, contents: data)
    }

    // MARK: - load() on missing file returns []

    func testLoadMissingFileReturnsEmpty() async {
        // tempRoot does not exist on disk — no .clearway directory created
        let result = await store.load()
        XCTAssertEqual(result, .empty)
    }

    // MARK: - load() on corrupt file returns [] (no crash)

    func testLoadCorruptFileReturnsEmpty() async throws {
        let clearwayDir = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(
            atPath: clearwayDir,
            withIntermediateDirectories: true
        )
        let groupsFile = (clearwayDir as NSString).appendingPathComponent("groups.json")
        FileManager.default.createFile(
            atPath: groupsFile,
            contents: Data("not valid json {{{".utf8)
        )

        let result = await store.load()
        XCTAssertEqual(result, .empty, "Corrupt JSON should return empty payload without crashing")
    }

    // MARK: - save(_:) creates .clearway directory and writes groups.json

    func testSaveCreatesClearwayDirectoryAndFile() async throws {
        let clearwayDir = (tempRoot as NSString).appendingPathComponent(".clearway")
        let groupsFile = (clearwayDir as NSString).appendingPathComponent("groups.json")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: clearwayDir),
            ".clearway dir must not exist before first save"
        )

        let group = WorktreeGroup(
            id: UUID(),
            name: "Test",
            worktreeIds: [],
            createdAt: Date()
        )
        let payload = WorktreeGroupsPayload(
            groups: [group],
            defaultOrder: ["main"],
            statuses: [:],
            grouping: .group
        )
        try await store.save(payload)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: clearwayDir),
            ".clearway dir should be created by save"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: groupsFile),
            "groups.json should exist after save"
        )

        // Verify the written content round-trips correctly.
        let loaded = await store.load()
        XCTAssertEqual(loaded, payload)
    }

    func testSaveIsAtomic_noTmpFileAfterSave() async throws {
        let clearwayDir = (tempRoot as NSString).appendingPathComponent(".clearway")
        let tmpFile = (clearwayDir as NSString).appendingPathComponent("groups.json.tmp")

        try await store.save(.empty)

        // After a completed save the .tmp file must have been renamed away.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tmpFile),
            "groups.json.tmp should not remain after atomic rename"
        )
    }

    // MARK: - startWatching fires on external write
    //
    // NOTE: This test is potentially flaky in CI because DispatchSourceFileSystemObject
    // event delivery is asynchronous and kernel-scheduled. The 3-second timeout gives
    // the kernel sufficient time to deliver the event in practice, but under heavy
    // machine load (e.g., parallel CI jobs) the event may arrive late. If this test
    // becomes a persistent source of CI failures, the retry allowance is:
    //   - Rerun the test suite once before marking it a real failure.
    //   - Consider moving it to a separate slow-tests scheme if flakiness exceeds 5%.

    func testWatcherFiresOnExternalWrite() async throws {
        // First save creates the .clearway dir and groups.json so the store can open
        // a file-level watcher (rather than a directory-level fallback).
        try await store.save(.empty)

        let expectation = XCTestExpectation(description: "onExternalChange fired")
        expectation.expectedFulfillmentCount = 1

        store.startWatching { expectation.fulfill() }

        // Give the watcher a moment to set up its fd before writing.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // Write a new groups.json from *outside* the store using a direct atomic write.
        // Using a separate FileManager write (not store.save) is intentional: store.save
        // also triggers the watcher callback; using an external writer cleanly tests the
        // "another process wrote the file" path without self-trigger ambiguity.
        let clearwayDir = (tempRoot as NSString).appendingPathComponent(".clearway")
        let groupsFile = (clearwayDir as NSString).appendingPathComponent("groups.json")
        let externalData = try JSONEncoder().encode([WorktreeGroup]())
        try externalData.write(to: URL(fileURLWithPath: groupsFile), options: .atomic)

        await fulfillment(of: [expectation], timeout: 3)
    }
}
