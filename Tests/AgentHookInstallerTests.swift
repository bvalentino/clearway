import XCTest
@testable import Clearway

/// Drives the installer's settings half against a temp home, so nothing here can reach the
/// developer's real `~/.claude` or `~/.codex`. The forwarder half writes under `~/.clearway` at
/// fixed paths and is deliberately left to the operator's by-hand check.
///
/// The rules worth pinning are the ones that decide *not* to write: a second install, an uninstall
/// on a file that never carried the block, an unreadable file, an absent `~/.codex`, and a backup
/// that already exists.
final class AgentHookInstallerTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-hook-installer-tests" }

    private var claudeDir: String { (tempRoot as NSString).appendingPathComponent(".claude") }
    private var settingsPath: String { (claudeDir as NSString).appendingPathComponent("settings.json") }
    private var backupPath: String { settingsPath + ".clearway-backup" }
    private var codexDir: String { (tempRoot as NSString).appendingPathComponent(".codex") }
    private var codexHooksPath: String { (codexDir as NSString).appendingPathComponent("hooks.json") }

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
    }

    // MARK: - Install

    func testInstallWritesTheBlockAndTheSecondCallWritesNothing() throws {
        try write(userSettings, to: settingsPath)

        install()

        let settings = try decoded(settingsPath)
        XCTAssertEqual((settings["hooks"] as? [String: Any])?.count, 9)
        XCTAssertEqual(settings["model"] as? String, "opus")

        // Proof that the second call is a no-op, with nothing to sleep on: a write replaces the
        // file, so a modification date that survives it is a write that did not happen.
        let stamp = Date(timeIntervalSince1970: 0)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: settingsPath)
        install()
        XCTAssertEqual(try modificationDate(settingsPath), stamp, "the second install must find the document it wants and write nothing")
    }

    func testAnAbsentSettingsFileIsCreatedWithNoBackup() throws {
        install()

        XCTAssertEqual((try decoded(settingsPath)["hooks"] as? [String: Any])?.count, 9)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath), "there was no file to back up")
    }

    func testUninstallRestoresTheUsersOwnDocument() throws {
        try write(userSettings, to: settingsPath)

        install()
        uninstall()

        let original = (try JSONSerialization.jsonObject(with: Data(userSettings.utf8))) as? [String: Any] ?? [:]
        XCTAssertEqual(try decoded(settingsPath) as NSDictionary, original as NSDictionary)
    }

    /// The discriminating case for comparing documents rather than bytes: re-serialising sorts keys
    /// and reflows whitespace, so an uninstall that wrote whenever the bytes differed would rewrite
    /// the settings file of every user who never turned the feature on.
    func testUninstallDoesNotRewriteAFileThatNeverCarriedTheBlock() throws {
        try write(userSettings, to: settingsPath)
        let before = try Data(contentsOf: URL(fileURLWithPath: settingsPath))

        uninstall()

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: settingsPath)), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath), "nothing was modified, so nothing was backed up")
    }

    func testUninstallCreatesNoSettingsFileOfItsOwn() {
        uninstall()

        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsPath))
    }

    // MARK: - Files Clearway cannot read

    func testUnparseableSettingsAreLeftByteIdentical() throws {
        for contents in ["[1, 2, 3]", "not json at all", ""] {
            try write(contents, to: settingsPath)

            install()

            XCTAssertEqual(try String(contentsOfFile: settingsPath, encoding: .utf8), contents)
            XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath), "a file Clearway cannot read is a file it does not touch")
        }
    }

    /// The destructive reading of the same `nil`: `FileManager.contents` answers it for a file that
    /// cannot be read as well as for one that is not there, and "not there" is the branch that
    /// takes no backup. A file left root-owned by one `sudo claude` run would have had the user's
    /// whole settings replaced by the block alone, with no `.clearway-backup` beside it, because
    /// the atomic write renames over the path and needs the directory rather than the file.
    func testAnUnreadableSettingsFileIsLeftAloneAndNotBackedUp() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file, so the case cannot be staged")
        try write(userSettings, to: settingsPath)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: settingsPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsPath) }

        install()

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsPath)
        XCTAssertEqual(try String(contentsOfFile: settingsPath, encoding: .utf8), userSettings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath), "a file Clearway cannot read is a file it does not touch")
    }

    // MARK: - The backup

    func testTheBackupIsTakenOnceAndNeverRefreshed() throws {
        try write(userSettings, to: settingsPath)

        install()
        XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8), userSettings)

        uninstall()
        XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8), userSettings, "the backup is the file as the user wrote it, not as Clearway last left it")
    }

    // MARK: - Codex

    func testCodexIsSkippedWhenItsDirectoryIsAbsent() {
        install()

        XCTAssertFalse(FileManager.default.fileExists(atPath: codexDir), "an absent ~/.codex means Codex is not installed, and Clearway never creates it")
    }

    func testCodexHooksAreWrittenIntoAnExistingCodexDirectory() throws {
        try FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)

        install()

        XCTAssertEqual((try decoded(codexHooksPath)["hooks"] as? [String: Any])?.count, 9)
    }

    // MARK: - The forwarder

    /// `0700` on `~/.clearway` is the whole access control on the hook socket: the app is
    /// unsandboxed and binds under `$HOME` rather than on a port. A directory that already exists —
    /// one that predates the feature, or one a umask left wider — must be narrowed, so the mode is
    /// reasserted on every install rather than set only by the create that may never run.
    func testTheClearwayDirectoriesAreNarrowedEvenWhenTheyAlreadyExist() throws {
        let paths = AgentHookPaths(home: tempRoot)
        for directory in [paths.clearwayDir, paths.hooksDir] {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755]
            )
        }

        AgentHookInstaller.install(home: tempRoot)

        XCTAssertEqual(try mode(paths.clearwayDir), AgentHookScript.dirMode)
        XCTAssertEqual(try mode(paths.hooksDir), AgentHookScript.dirMode)
    }

    /// The forwarder is compared by content, not by existence, so a fix to it reaches the users who
    /// already have the old one. Narrowing this to "write it if it is missing" — the shape the
    /// directory create above uses — would ship every later forwarder change to nobody, and the
    /// only symptom is a dot that quietly stops lighting.
    func testAStaleForwarderIsReplacedAndItsModeReasserted() throws {
        let paths = AgentHookPaths(home: tempRoot)
        try FileManager.default.createDirectory(atPath: paths.hooksDir, withIntermediateDirectories: true)
        try write("#!/bin/sh\nexit 1\n", to: paths.scriptPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.scriptPath)

        AgentHookInstaller.install(home: tempRoot)

        XCTAssertEqual(try String(contentsOfFile: paths.scriptPath, encoding: .utf8), AgentHookScript.body)
        XCTAssertEqual(try mode(paths.scriptPath), AgentHookScript.scriptMode)
    }

    // MARK: - Helpers

    private func install() {
        AgentHookInstaller.mergeAgentSettings(installing: true, home: tempRoot)
    }

    private func uninstall() {
        AgentHookInstaller.mergeAgentSettings(installing: false, home: tempRoot)
    }

    private func write(_ contents: String, to path: String) throws {
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func decoded(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func modificationDate(_ path: String) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private func mode(_ path: String) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private let userSettings = """
    {
        "model": "opus",
        "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/my-hook.sh"}]}]}
    }
    """
}
