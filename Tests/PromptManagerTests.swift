import XCTest
@testable import Clearway

@MainActor
final class PromptManagerTests: XCTestCase {
    private var tempDir: URL!
    private var manager: PromptManager!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager = PromptManager(directory: tempDir.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testEmptyTitleSortsFirst() async throws {
        writePromptFile(filename: "a.md", title: "Zebra")
        writePromptFile(filename: "b.md", title: "")
        writePromptFile(filename: "c.md", title: "Apple")

        await reloadAndWait()

        XCTAssertEqual(manager.prompts.map(\.title), ["", "Apple", "Zebra"])
    }

    func testAlphabeticalSort() async throws {
        writePromptFile(filename: "a.md", title: "Zebra")
        writePromptFile(filename: "b.md", title: "mango")
        writePromptFile(filename: "c.md", title: "apple")

        await reloadAndWait()

        XCTAssertEqual(manager.prompts.map(\.title), ["apple", "mango", "Zebra"])
    }

    func testMultipleEmptyTitlesSortFirst() async throws {
        writePromptFile(filename: "a.md", title: "")
        writePromptFile(filename: "b.md", title: "Beta")
        writePromptFile(filename: "c.md", title: "")

        await reloadAndWait()

        let titles = manager.prompts.map(\.title)
        XCTAssertEqual(titles.prefix(2).filter(\.isEmpty).count, 2)
        XCTAssertEqual(titles.last, "Beta")
    }

    func testCreatePromptInsertsInOrder() {
        _ = manager.createPrompt(title: "Zebra")
        _ = manager.createPrompt(title: "")
        _ = manager.createPrompt(title: "Apple")

        XCTAssertEqual(manager.prompts.map(\.title), ["", "Apple", "Zebra"])
    }

    func testUpdatePromptResorts() {
        let p = manager.createPrompt(title: "Mango")!
        _ = manager.createPrompt(title: "Apple")
        _ = manager.createPrompt(title: "Zebra")

        var updated = p
        updated.title = ""
        manager.updatePrompt(updated)

        XCTAssertEqual(manager.prompts.first?.title, "")
    }

    // MARK: - Helpers

    private func writePromptFile(filename: String, title: String) {
        let content = "---\ntitle: \"\(title)\"\n---\n"
        let url = tempDir.appendingPathComponent(filename)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func reloadAndWait() async {
        manager.reload()
        // Give the detached task time to complete
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}
