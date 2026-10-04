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

        XCTAssertEqual(install(), [])

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
        XCTAssertTrue(status.isInstalled)
        XCTAssertEqual(status.messages, [noAgentMessage])
    }

    func testAGateThatIsAFileReadsAsAgentAbsent() throws {
        try write("not a directory", to: path(".claude"))

        install()

        XCTAssertEqual(status().state(of: .claudeCode), .agentAbsent)
        XCTAssertNil(try? fileManager.attributesOfItem(atPath: claudeLink))
    }

    func testOneEntryFailingDoesNotStopTheOthers() throws {
        try makeAgents(claude: true, codex: true)
        try write("blocks the skills directory", to: path(".claude/skills"))

        let failures = install()

        XCTAssertEqual(try destination(cliLink), cliDestination)
        XCTAssertEqual(try destination(codexLink), skillDestination)
        XCTAssertEqual(failures, [])
        let status = status()
        XCTAssertEqual(status.state(of: .claudeCode), .unreadable(reason: "Not a directory"))
        XCTAssertTrue(status.messages.contains("~/.claude/skills/clearway could not be read: Not a directory."))
    }

    func testAnUnwritableSkillsDirectoryIsReportedAndTheOthersAreLinked() throws {
        try makeAgents(claude: true, codex: true)
        let skills = path(".claude/skills")
        try makeDirectory(skills)
        try setMode(0o555, of: skills)
        defer { try? setMode(0o755, of: skills) }

        let failures = install()

        let expected = SkillInstaller.Failure(displayPath: "~/.claude/skills/clearway", action: .link, reason: "Permission denied")
        XCTAssertEqual(failures, [expected])
        XCTAssertEqual(failures.first?.message, "~/.claude/skills/clearway could not be linked: Permission denied.")
        XCTAssertEqual(try destination(cliLink), cliDestination)
        XCTAssertEqual(try destination(codexLink), skillDestination)
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
        try fileManager.createSymbolicLink(atPath: codexLink, withDestinationPath: path("repo/Contents/Resources/Skills/clearway"))

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
        XCTAssertEqual(try? destination(codexLink), path("repo/Contents/Resources/Skills/clearway"), file: file, line: line)
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

        XCTAssertEqual(install(), [])
        XCTAssertEqual(try destination(cliLink), cliDestination)
        XCTAssertEqual(try destination(claudeLink), skillDestination)
        XCTAssertEqual(try destination(codexLink), skillDestination)
        for container in [".clearway", ".claude/skills", ".agents/skills"] {
            XCTAssertEqual(try temporaryEntries(in: path(container)), [], "\(container) must hold no temporary link")
        }

        try fileManager.removeItem(atPath: codexLink)
        try fileManager.createSymbolicLink(atPath: codexLink, withDestinationPath: path("Gone.app/Contents/Resources/Skills/clearway"))
        XCTAssertEqual(uninstall(), [])
        assertAllLinksGone()
    }

    func testAStaleLinkSurvivesAnInstallThatCannotCreateItsReplacement() throws {
        try makeAgents(claude: true, codex: true)
        let skills = path(".claude/skills")
        try makeDirectory(skills)
        let oldDestination = (otherBundle as NSString).appendingPathComponent("Contents/Resources/Skills/clearway")
        try fileManager.createSymbolicLink(atPath: claudeLink, withDestinationPath: oldDestination)
        defer { try? run("/bin/chmod", ["-N", skills]) }
        try run("/bin/chmod", ["+a", "user:\(NSUserName()) deny add_file", skills])

        let failures = install()

        XCTAssertEqual(try destination(claudeLink), oldDestination)
        XCTAssertEqual(failures, [SkillInstaller.Failure(displayPath: "~/.claude/skills/clearway", action: .link, reason: "Permission denied")])
        XCTAssertEqual(try temporaryEntries(in: skills), [])
    }

    func testAStaleLinkSurvivesAnInstallWhoseRenameFails() throws {
        try makeAgents(claude: true, codex: true)
        let skills = path(".claude/skills")
        try makeDirectory(skills)
        let oldDestination = (otherBundle as NSString).appendingPathComponent("Contents/Resources/Skills/clearway")
        try fileManager.createSymbolicLink(atPath: claudeLink, withDestinationPath: oldDestination)
        defer { try? run("/usr/bin/chflags", ["-h", "nouchg", claudeLink]) }
        try run("/usr/bin/chflags", ["-h", "uchg", claudeLink])

        let failures = install()

        XCTAssertEqual(try destination(claudeLink), oldDestination)
        XCTAssertEqual(failures, [SkillInstaller.Failure(displayPath: "~/.claude/skills/clearway", action: .link, reason: "Operation not permitted")])
        XCTAssertEqual(try temporaryEntries(in: skills), [])
    }

    func testUninstallRemovesLinksIntoAnotherExistingBundle() throws {
        try makeAgents(claude: true, codex: true)
        _ = SkillInstaller.install(home: tempRoot, bundlePath: otherBundle)
        XCTAssertEqual(status().entries.map(\.state), [.stale, .stale, .stale])

        uninstall()

        assertAllLinksGone()
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

        assertAllLinksGone()
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

    func testAnUnremovableLinkIsReportedAndTheOthersAreRemoved() throws {
        try makeAgents(claude: true, codex: true)
        install()
        let skills = path(".claude/skills")
        try setMode(0o555, of: skills)
        defer { try? setMode(0o755, of: skills) }

        let failures = uninstall()

        XCTAssertEqual(failures, [SkillInstaller.Failure(displayPath: "~/.claude/skills/clearway", action: .remove, reason: "Permission denied")])
        XCTAssertEqual(failures.first?.message, "~/.claude/skills/clearway could not be removed: Permission denied.")
        XCTAssertNil(try? fileManager.attributesOfItem(atPath: cliLink))
        XCTAssertNil(try? fileManager.attributesOfItem(atPath: codexLink))
    }

    func testUninstallLeavesAnAgentAbsentEntryAlone() throws {
        try makeAgents(claude: false, codex: false)
        try makeDirectory(path(".agents/skills"))
        try fileManager.createSymbolicLink(atPath: codexLink, withDestinationPath: skillDestination)

        uninstall()

        XCTAssertEqual(try destination(codexLink), skillDestination)
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

    func testAnEntryThatCannotBeStatedIsUnreadableAndSkippedByUninstall() throws {
        try makeAgents(claude: true, codex: true)
        install()
        let skills = path(".claude/skills")
        try setMode(0o600, of: skills)
        defer { try? setMode(0o755, of: skills) }

        let before = status()
        XCTAssertEqual(before.state(of: .claudeCode), .unreadable(reason: "Permission denied"))
        XCTAssertEqual(before.messages, ["~/.claude/skills/clearway could not be read: Permission denied."])
        XCTAssertTrue(before.isInstalled)

        XCTAssertEqual(uninstall(), [])

        XCTAssertNil(try? fileManager.attributesOfItem(atPath: cliLink))
        XCTAssertNil(try? fileManager.attributesOfItem(atPath: codexLink))
        try setMode(0o755, of: skills)
        XCTAssertEqual(try destination(claudeLink), skillDestination)
    }

    func testAMissingEntryBlocksInstalled() throws {
        try makeAgents(claude: true, codex: true)
        install()
        try fileManager.removeItem(atPath: codexLink)

        XCTAssertEqual(status().state(of: .codex), .missing)
        XCTAssertFalse(status().isInstalled)
    }

    // MARK: - Helpers

    private func assertAllLinksGone(file: StaticString = #filePath, line: UInt = #line) {
        for link in [cliLink, claudeLink, codexLink] {
            XCTAssertNil(try? fileManager.attributesOfItem(atPath: link), "\(link) should be gone", file: file, line: line)
        }
    }

    @discardableResult
    private func install() -> [SkillInstaller.Failure] { SkillInstaller.install(home: tempRoot, bundlePath: bundle) }
    @discardableResult
    private func uninstall() -> [SkillInstaller.Failure] { SkillInstaller.uninstall(home: tempRoot, bundlePath: bundle) }
    private func status() -> SkillInstallStatus { SkillInstaller.status(home: tempRoot, bundlePath: bundle) }

    private func path(_ relative: String) -> String {
        (tempRoot as NSString).appendingPathComponent(relative)
    }

    private func makeAgents(claude: Bool, codex: Bool) throws {
        if claude { try makeDirectory(path(".claude")) }
        if codex { try makeDirectory(path(".codex")) }
    }

    private func setMode(_ mode: Int, of path: String) throws {
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments.joined(separator: " ")) failed")
    }

    private func temporaryEntries(in container: String) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: container).filter { $0.hasPrefix(".cway.") || $0.hasPrefix(".clearway.") }
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

private extension SkillInstallStatus {
    func state(of target: SkillInstaller.Target) -> SkillInstaller.EntryState? {
        entries.first { $0.target == target }?.state
    }
}
