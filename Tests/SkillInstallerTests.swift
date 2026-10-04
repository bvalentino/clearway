import XCTest
@testable import Clearway

/// Every call passes the temp root as `home` and a fake bundle under it as `bundlePath`, so nothing
/// here can reach the real `~/.clearway`, `~/.claude` or `~/.agents`.
final class SkillInstallerTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-skill-installer-tests" }

    private let fileManager = FileManager.default

    private var bundle: String { path("A.app") }
    private var otherBundle: String { path("B.app") }
    private var cliLink: String { path(".clearway/cway") }
    private var claudeLink: String { path(".claude/skills/clearway") }
    private var codexLink: String { path(".agents/skills/clearway") }
    private var cliDestination: String { (bundle as NSString).appendingPathComponent("Contents/MacOS/cway") }
    private var skillDestination: String { (bundle as NSString).appendingPathComponent("Contents/Resources/Skills/clearway") }

    private let noAgentMessage = "No ~/.claude or ~/.codex directory was found, so the skill was not installed."

    override func setUp() async throws {
        try await super.setUp()
        for root in [bundle, otherBundle] {
            try makeDirectory((root as NSString).appendingPathComponent("Contents/Resources/Skills/clearway"))
            try makeDirectory((root as NSString).appendingPathComponent("Contents/MacOS"))
            try write("skill", to: (root as NSString).appendingPathComponent("Contents/Resources/Skills/clearway/SKILL.md"))
            try write("cli", to: (root as NSString).appendingPathComponent("Contents/MacOS/cway"))
        }
    }

    // MARK: - Install

    func testInstallWithBothAgentsLinksAllThreeIntoTheBundle() throws {
        try makeAgents(claude: true, codex: true)

        install()

        XCTAssertEqual(try destination(cliLink), cliDestination)
        XCTAssertEqual(try destination(claudeLink), skillDestination)
        XCTAssertEqual(try destination(codexLink), skillDestination)
        let status = status()
        XCTAssertEqual(status.entries.map(\.state), [.current, .current, .current])
        XCTAssertTrue(status.isInstalled)
        XCTAssertEqual(status.messages, [])
    }

    func testOnlyClaudeCodeSkipsCodexAndCreatesNoAgentsDirectory() throws {
        try makeAgents(claude: true, codex: false)

        install()

        XCTAssertEqual(try destination(claudeLink), skillDestination)
        XCTAssertFalse(fileManager.fileExists(atPath: path(".agents")))
        XCTAssertFalse(fileManager.fileExists(atPath: path(".codex")))
        let status = status()
        XCTAssertEqual(status.state(of: .codex), .agentAbsent)
        XCTAssertTrue(status.isInstalled)
        XCTAssertEqual(status.messages, [])
    }

    func testOnlyCodexSkipsClaudeCodeAndCreatesNoClaudeDirectory() throws {
        try makeAgents(claude: false, codex: true)

        install()

        XCTAssertEqual(try destination(codexLink), skillDestination)
        XCTAssertFalse(fileManager.fileExists(atPath: path(".claude")))
        XCTAssertEqual(status().state(of: .claudeCode), .agentAbsent)
        XCTAssertTrue(status().isInstalled)
    }

    func testNeitherAgentStillLinksTheCliAndSaysSo() throws {
        install()

        XCTAssertEqual(try destination(cliLink), cliDestination)
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: path(".clearway"))[.posixPermissions] as? Int, 0o700)
        XCTAssertFalse(fileManager.fileExists(atPath: path(".claude")))
        XCTAssertFalse(fileManager.fileExists(atPath: path(".agents")))
        let status = status()
        XCTAssertEqual(status.entries.map(\.state), [.current, .agentAbsent, .agentAbsent])
        XCTAssertEqual(status.messages, [noAgentMessage])
    }

    func testInstallTwiceLeavesTheLinksAsTheFirstMadeThem() throws {
        try makeAgents(claude: true, codex: true)
        install()
        let inodes = try [cliLink, claudeLink, codexLink].map(inode)

        install()

        XCTAssertEqual(try [cliLink, claudeLink, codexLink].map(inode), inodes, "a current link must not be recreated")
    }

    // MARK: - Foreign entries

    func testForeignEntriesAreLeftAloneByInstallAndUninstallAndReported() throws {
        try makeAgents(claude: true, codex: true)
        try makeDirectory(path(".clearway"))
        try write("mine", to: cliLink)
        try makeDirectory(claudeLink)
        try write("my skill", to: (claudeLink as NSString).appendingPathComponent("SKILL.md"))
        try makeDirectory(path(".agents/skills"))
        try fileManager.createSymbolicLink(atPath: codexLink, withDestinationPath: path("elsewhere/clearway"))

        install()
        assertForeignEntriesUntouched()
        let status = status()
        XCTAssertEqual(status.entries.map(\.state), [.foreign, .foreign, .foreign])
        XCTAssertFalse(status.isInstalled)
        XCTAssertEqual(status.messages, [
            "~/.clearway/cway already exists and was left alone.",
            "~/.claude/skills/clearway already exists and was left alone.",
            "~/.agents/skills/clearway already exists and was left alone.",
        ])

        uninstall()
        assertForeignEntriesUntouched()
    }

    private func assertForeignEntriesUntouched(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fileManager.contents(atPath: cliLink), Data("mine".utf8), file: file, line: line)
        XCTAssertEqual(
            fileManager.contents(atPath: (claudeLink as NSString).appendingPathComponent("SKILL.md")),
            Data("my skill".utf8), file: file, line: line
        )
        XCTAssertEqual(try? destination(codexLink), path("elsewhere/clearway"), file: file, line: line)
    }

    func testInstalledWithAForeignEntryStillReadsInstalledAndReportsIt() throws {
        try makeAgents(claude: true, codex: true)
        try makeDirectory(path(".agents/skills"))
        try write("theirs", to: codexLink)

        install()

        let status = status()
        XCTAssertEqual(status.entries.map(\.state), [.current, .current, .foreign])
        XCTAssertTrue(status.isInstalled)
        XCTAssertEqual(status.messages, ["~/.agents/skills/clearway already exists and was left alone."])
    }

    // MARK: - Stale entries

    func testStaleAndDanglingLinksAreRepointedByInstallAndRemovedByUninstall() throws {
        try makeAgents(claude: true, codex: true)
        try makeDirectory(path(".clearway"))
        try makeDirectory(path(".claude/skills"))
        try makeDirectory(path(".agents/skills"))
        try fileManager.createSymbolicLink(
            atPath: cliLink,
            withDestinationPath: (otherBundle as NSString).appendingPathComponent("Contents/MacOS/cway")
        )
        try fileManager.createSymbolicLink(
            atPath: claudeLink,
            withDestinationPath: (otherBundle as NSString).appendingPathComponent("Contents/Resources/Skills/clearway")
        )
        try fileManager.createSymbolicLink(
            atPath: codexLink,
            withDestinationPath: path("Gone.app/Contents/Resources/Skills/clearway")
        )

        let before = status()
        XCTAssertEqual(before.entries.map(\.state), [.stale, .stale, .stale])
        XCTAssertFalse(before.isInstalled)
        XCTAssertEqual(before.messages, [])

        install()
        XCTAssertEqual(try destination(cliLink), cliDestination)
        XCTAssertEqual(try destination(claudeLink), skillDestination)
        XCTAssertEqual(try destination(codexLink), skillDestination)

        try fileManager.removeItem(atPath: codexLink)
        try fileManager.createSymbolicLink(atPath: codexLink, withDestinationPath: path("Gone.app/Contents/Resources/Skills/clearway"))
        uninstall()
        for link in [cliLink, claudeLink, codexLink] {
            XCTAssertNil(try? fileManager.attributesOfItem(atPath: link), "\(link) should be gone")
        }
    }

    func testAStaleEntryBlocksInstalled() throws {
        try makeAgents(claude: true, codex: true)
        install()
        try fileManager.removeItem(atPath: claudeLink)
        try fileManager.createSymbolicLink(
            atPath: claudeLink,
            withDestinationPath: (otherBundle as NSString).appendingPathComponent("Contents/Resources/Skills/clearway")
        )

        XCTAssertEqual(status().state(of: .claudeCode), .stale)
        XCTAssertFalse(status().isInstalled)
    }

    // MARK: - Uninstall

    func testUninstallRemovesOnlyClearwaysLinksAndNoDirectory() throws {
        try makeAgents(claude: true, codex: true)
        install()
        try write("hook", to: path(".clearway/hook.sock"))
        try makeDirectory(path(".claude/skills/other"))
        try fileManager.createSymbolicLink(atPath: path(".agents/skills/sibling"), withDestinationPath: path("elsewhere"))

        uninstall()

        for link in [cliLink, claudeLink, codexLink] {
            XCTAssertNil(try? fileManager.attributesOfItem(atPath: link), "\(link) should be gone")
        }
        XCTAssertTrue(fileManager.fileExists(atPath: path(".clearway/hook.sock")))
        XCTAssertTrue(fileManager.fileExists(atPath: path(".claude/skills/other")))
        XCTAssertNotNil(try? fileManager.attributesOfItem(atPath: path(".agents/skills/sibling")))
        XCTAssertTrue(fileManager.fileExists(atPath: path(".claude/skills")))
        XCTAssertTrue(fileManager.fileExists(atPath: path(".agents/skills")))
        XCTAssertTrue(fileManager.fileExists(atPath: skillDestination), "removing a link must not remove its target")

        let status = status()
        XCTAssertEqual(status.entries.map(\.state), [.missing, .missing, .missing])
        XCTAssertFalse(status.isInstalled)
    }

    // MARK: - Status

    func testNothingOnDiskIsMissingAndNotInstalled() throws {
        try makeAgents(claude: true, codex: true)

        let status = status()

        XCTAssertEqual(status.entries.map(\.state), [.missing, .missing, .missing])
        XCTAssertEqual(status.entries.map(\.displayPath), ["~/.clearway/cway", "~/.claude/skills/clearway", "~/.agents/skills/clearway"])
        XCTAssertFalse(status.isInstalled)
        XCTAssertEqual(status.messages, [])
    }

    func testAMissingEntryBlocksInstalled() throws {
        try makeAgents(claude: true, codex: true)
        install()
        try fileManager.removeItem(atPath: codexLink)

        XCTAssertEqual(status().state(of: .codex), .missing)
        XCTAssertFalse(status().isInstalled)
    }

    // MARK: - Helpers

    private func install() { SkillInstaller.install(home: tempRoot, bundlePath: bundle) }
    private func uninstall() { SkillInstaller.uninstall(home: tempRoot, bundlePath: bundle) }
    private func status() -> SkillInstallStatus { SkillInstaller.status(home: tempRoot, bundlePath: bundle) }

    private func path(_ relative: String) -> String {
        (tempRoot as NSString).appendingPathComponent(relative)
    }

    private func makeAgents(claude: Bool, codex: Bool) throws {
        if claude { try makeDirectory(path(".claude")) }
        if codex { try makeDirectory(path(".codex")) }
    }

    private func makeDirectory(_ path: String) throws {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func destination(_ link: String) throws -> String {
        let type = try fileManager.attributesOfItem(atPath: link)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink, "\(link) must be a symlink, not a copy")
        return try fileManager.destinationOfSymbolicLink(atPath: link)
    }

    private func inode(_ link: String) throws -> Int? {
        try fileManager.attributesOfItem(atPath: link)[.systemFileNumber] as? Int
    }
}
