import XCTest
@testable import Clearway

@MainActor
final class WorktreeGroupStoreTests: XCTestCase {

    private var tempRoot: String!
    private var store: WorktreeGroupStore!

    override func setUp() {
        super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-store-tests-\(UUID().uuidString)")
        store = WorktreeGroupStore(projectPath: tempRoot)
    }

    override func tearDown() {
        store.stopWatching()
        store = nil
        if let root = tempRoot {
            try? FileManager.default.removeItem(atPath: root)
        }
        tempRoot = nil
        super.tearDown()
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

    // MARK: - load() on missing file returns []

    func testLoadMissingFileReturnsEmpty() async {
        // tempRoot does not exist on disk — no .clearway directory created
        let result = await store.load()
        XCTAssertEqual(result, [])
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
        XCTAssertEqual(result, [], "Corrupt JSON should return [] without crashing")
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
        try await store.save([group])

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
        XCTAssertEqual(loaded, [group])
    }

    func testSaveIsAtomic_noTmpFileAfterSave() async throws {
        let clearwayDir = (tempRoot as NSString).appendingPathComponent(".clearway")
        let tmpFile = (clearwayDir as NSString).appendingPathComponent("groups.json.tmp")

        try await store.save([])

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
        try await store.save([])

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
