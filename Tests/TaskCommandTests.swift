import XCTest
@testable import Clearway

final class TaskCommandTests: TempRootTestCase {

    private func run(
        _ arguments: [String],
        in directory: String = NSTemporaryDirectory(),
        stdin: @escaping () -> Data = {
            XCTFail("stdin must not be read")
            return Data()
        }
    ) -> TaskCommand.Result {
        TaskCommand.run(arguments: arguments, workingDirectory: directory, readStdin: stdin)
    }

    private func makeRepo() throws -> GitRepoFixture {
        try GitRepoFixture.make(at: tempRoot)
    }

    /// git reports real paths (`/private/var/…`) while `resolvingSymlinksInPath` strips `/private`,
    /// so path assertions compare through the same resolution.
    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func clearwayDirectory(in root: String) -> String {
        (root as NSString).appendingPathComponent(".clearway")
    }

    /// Asserts a successful `create` and returns the id and path its JSON reports.
    private func created(_ result: TaskCommand.Result, file: StaticString = #filePath, line: UInt = #line) throws -> (id: UUID, path: String) {
        XCTAssertEqual(result.exitCode, 0, result.stderr, file: file, line: line)
        XCTAssertEqual(result.stderr, "", file: file, line: line)
        XCTAssertTrue(result.stdout.hasSuffix("\n"), file: file, line: line)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String],
            file: file, line: line
        )
        XCTAssertEqual(Set(object.keys), ["id", "path"], file: file, line: line)
        let idString = try XCTUnwrap(object["id"], file: file, line: line)
        let id = try XCTUnwrap(UUID(uuidString: idString), file: file, line: line)
        XCTAssertEqual(idString, id.uuidString, file: file, line: line)
        return (id, try XCTUnwrap(object["path"], file: file, line: line))
    }

    private func assertFailed(
        _ result: TaskCommand.Result, exitCode: Int32, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.exitCode, exitCode, file: file, line: line)
        XCTAssertEqual(result.stdout, "", file: file, line: line)
        XCTAssertTrue(result.stderr.hasPrefix("clearway: "), result.stderr, file: file, line: line)
        XCTAssertTrue(result.stderr.hasSuffix("\n"), file: file, line: line)
    }

    func testHelpPrintsUsageAndExitsZero() {
        for arguments in [["help"], ["--help"], []] {
            let result = run(arguments)
            XCTAssertEqual(result.exitCode, 0, "\(arguments)")
            XCTAssertFalse(result.stdout.isEmpty, "\(arguments)")
            XCTAssertEqual(result.stderr, "", "\(arguments)")
        }
    }

    func testUsageListsEveryTaskSubcommand() {
        let usage = run(["help"]).stdout
        XCTAssertTrue(usage.contains("clearway task create --title <title> [--body <text>]"))
        XCTAssertTrue(usage.contains("clearway task list"))
        XCTAssertTrue(usage.contains("clearway task show <id>"))
    }

    func testUnknownCommandExitsTwoWithEmptyStdout() {
        let result = run(["frobnicate"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "clearway: unknown command 'frobnicate'\n")
    }

    func testEmbeddedHelperExistsAndRunsHelp() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clearway")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path), helper.path)

        let process = Process()
        process.executableURL = helper
        process.arguments = ["help"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(bytes: output, encoding: .utf8), TaskCommand.usage)
    }

    // MARK: - task create

    func testCreateFromMainWorktreeWritesSharedSerializationIntoBacklog() throws {
        let repo = try makeRepo()

        let (id, path) = try created(run(["task", "create", "--title", "First"], in: repo.root))

        let tasksDirectory = TaskFiles.tasksDirectory(inProject: repo.root)
        XCTAssertEqual(canonical(path), TaskFiles.centralPath(for: id, tasksDirectory: tasksDirectory))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), WorkTask(id: id, title: "First").serialized())
    }

    func testCreateFromLinkedWorktreeWritesIntoMainBacklog() throws {
        let repo = try makeRepo()
        let worktree = try repo.addWorktree(branch: "feature")

        let (id, path) = try created(run(["task", "create", "--title", "From linked"], in: worktree))

        let tasksDirectory = TaskFiles.tasksDirectory(inProject: repo.root)
        XCTAssertEqual(canonical(path), TaskFiles.centralPath(for: id, tasksDirectory: tasksDirectory))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), WorkTask(id: id, title: "From linked").serialized())
        XCTAssertFalse(FileManager.default.fileExists(atPath: clearwayDirectory(in: worktree)))
    }

    func testCreateMakesMissingDirectoriesAndAnOwnerOnlyFile() throws {
        let repo = try makeRepo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: clearwayDirectory(in: repo.root)))

        let (_, path) = try created(run(["task", "create", "--title", "Fresh"], in: repo.root))

        let fm = FileManager.default
        let fileMode = try fm.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        let directoryMode = try fm.attributesOfItem(atPath: TaskFiles.tasksDirectory(inProject: repo.root))[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
    }

    func testTitlesRoundTripThroughParserAndManager() throws {
        let repo = try makeRepo()
        let titles = [#"a "quoted" title"#, "key: value", #"back\slash"#, "# hash", "-leading dash", "it's"]

        for title in titles {
            let (id, path) = try created(run(["task", "create", "--title", title], in: repo.root))
            let parsed = WorkTask.parse(from: try String(contentsOfFile: path, encoding: .utf8))
            XCTAssertEqual(parsed?.id, id, title)
            XCTAssertEqual(parsed?.title, title)
        }

        let manager = WorkTaskManager(projectPath: repo.root)
        XCTAssertEqual(Set(manager.tasks.map(\.title)), Set(titles))
    }

    func testTitleIsTrimmedOfWhitespaceAndNewlines() throws {
        let repo = try makeRepo()

        let (_, path) = try created(run(["task", "create", "--title", "  padded\n"], in: repo.root))

        XCTAssertEqual(WorkTask.parse(from: try String(contentsOfFile: path, encoding: .utf8))?.title, "padded")
    }

    func testMissingOrBlankTitleIsUsageErrorAndWritesNothing() throws {
        let repo = try makeRepo()

        for arguments in [["task", "create"], ["task", "create", "--title", ""], ["task", "create", "--title", " \n\t "]] {
            assertFailed(run(arguments, in: repo.root), exitCode: 2)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: clearwayDirectory(in: repo.root)))
    }

    func testMalformedCreateArgumentsAreUsageErrorsAndWriteNothing() throws {
        let repo = try makeRepo()
        let cases = [
            ["task", "create", "--title", "x", "--force"],
            ["task", "create", "--title"],
            ["task", "create", "--title", "x", "--body"],
            ["task", "create", "--title", "x", "--title", "y"],
            ["task", "create", "--title", "x", "stray"],
        ]

        for arguments in cases {
            assertFailed(run(arguments, in: repo.root), exitCode: 2)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: clearwayDirectory(in: repo.root)))
    }

    func testBodyFlagTextLandsAsBody() throws {
        let repo = try makeRepo()

        let (id, path) = try created(run(["task", "create", "--title", "With body", "--body", "Some details"], in: repo.root))

        XCTAssertEqual(
            try String(contentsOfFile: path, encoding: .utf8),
            WorkTask(id: id, title: "With body", body: "Some details").serialized()
        )
    }

    func testBodyDashReadsStdin() throws {
        let repo = try makeRepo()
        let body = "Line one\nLine two: \"quoted\"\n"

        let (id, path) = try created(
            run(["task", "create", "--title", "Piped", "--body", "-"], in: repo.root, stdin: { Data(body.utf8) })
        )

        XCTAssertEqual(
            try String(contentsOfFile: path, encoding: .utf8),
            WorkTask(id: id, title: "Piped", body: body).serialized()
        )
    }

    func testCreateOutsideGitRepositoryExitsOneAndWritesNothing() throws {
        let directory = (tempRoot as NSString).appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        assertFailed(run(["task", "create", "--title", "Nowhere"], in: directory), exitCode: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: clearwayDirectory(in: directory)))
    }
}
