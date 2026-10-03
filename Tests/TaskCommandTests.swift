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
        XCTAssertTrue(result.stderr.hasPrefix("cway: "), result.stderr, file: file, line: line)
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
        XCTAssertTrue(usage.contains("cway task create --title <title> [--body <text>]"))
        XCTAssertTrue(usage.contains("cway task list"))
        XCTAssertTrue(usage.contains("cway task show <id>"))
    }

    func testUnknownCommandExitsTwoWithEmptyStdout() {
        let result = run(["frobnicate"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "cway: unknown command 'frobnicate'\n")
    }

    func testEmbeddedHelperExistsAndRunsHelp() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cway")
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

    // MARK: - task list, task show

    private struct Pool {
        let repo: GitRepoFixture
        let backlog: WorkTask
        let linked: WorkTask
        let hidden: WorkTask
        let linkedWorktree: String
    }

    /// A backlog task (oldest), a task in a linked worktree's `TASK.md` (newest) and a hidden
    /// shadow task in a second worktree.
    private func makePool() throws -> Pool {
        let repo = try makeRepo()
        let linkedWorktree = try repo.addWorktree(branch: "feature")
        let shadowWorktree = try repo.addWorktree(branch: "shadow")

        let backlog = WorkTask(title: "Backlog task", body: "Backlog body")
        let linked = WorkTask(title: "Linked task", worktree: "feature", body: "Linked body")
        var hidden = WorkTask(title: "Shadow task", worktree: "shadow")
        hidden.hidden = true

        let now = Date()
        let files: [(WorkTask, String, Date)] = [
            (backlog, TaskFiles.centralPath(for: backlog.id, tasksDirectory: TaskFiles.tasksDirectory(inProject: repo.root)), now.addingTimeInterval(-200)),
            (linked, TaskFiles.taskMarkdownPath(inWorktree: linkedWorktree), now.addingTimeInterval(-100)),
            (hidden, TaskFiles.taskMarkdownPath(inWorktree: shadowWorktree), now),
        ]
        for (task, path, created) in files {
            try TaskFiles.write(task, toPath: path)
            try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: path)
        }
        return Pool(repo: repo, backlog: backlog, linked: linked, hidden: hidden, linkedWorktree: linkedWorktree)
    }

    private func jsonObject(_ result: TaskCommand.Result, file: StaticString = #filePath, line: UInt = #line) throws -> Any {
        XCTAssertEqual(result.exitCode, 0, result.stderr, file: file, line: line)
        XCTAssertEqual(result.stderr, "", file: file, line: line)
        XCTAssertTrue(result.stdout.hasSuffix("\n"), file: file, line: line)
        return try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
    }

    func testListReturnsVisibleTasksWithLocationAndWorktreeNewestFirst() throws {
        let pool = try makePool()

        let entries = try XCTUnwrap(try jsonObject(run(["task", "list"], in: pool.repo.root)) as? [[String: Any]])

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0["id"] as? String }, [pool.linked.id.uuidString, pool.backlog.id.uuidString])
        for entry in entries {
            XCTAssertEqual(Set(entry.keys), ["id", "title", "location", "worktree", "path"])
        }

        let linked = entries[0]
        XCTAssertEqual(linked["title"] as? String, "Linked task")
        XCTAssertEqual(linked["location"] as? String, "worktree")
        XCTAssertEqual(linked["worktree"] as? String, "feature")
        XCTAssertEqual(canonical(try XCTUnwrap(linked["path"] as? String)), TaskFiles.taskMarkdownPath(inWorktree: pool.linkedWorktree))

        let backlog = entries[1]
        XCTAssertEqual(backlog["title"] as? String, "Backlog task")
        XCTAssertEqual(backlog["location"] as? String, "backlog")
        XCTAssertTrue(backlog["worktree"] is NSNull)
        XCTAssertEqual(
            canonical(try XCTUnwrap(backlog["path"] as? String)),
            TaskFiles.centralPath(for: pool.backlog.id, tasksDirectory: TaskFiles.tasksDirectory(inProject: pool.repo.root))
        )
    }

    func testListWithNoTasksPrintsEmptyArray() throws {
        let repo = try makeRepo()

        let entries = try XCTUnwrap(try jsonObject(run(["task", "list"], in: repo.root)) as? [Any])

        XCTAssertTrue(entries.isEmpty)
    }

    func testListFromLinkedWorktreeSeesTheWholePool() throws {
        let pool = try makePool()

        let entries = try XCTUnwrap(try jsonObject(run(["task", "list"], in: pool.linkedWorktree)) as? [[String: Any]])

        XCTAssertEqual(entries.map { $0["id"] as? String }, [pool.linked.id.uuidString, pool.backlog.id.uuidString])
    }

    func testShowFindsBacklogWorktreeHiddenAndLowercasedIds() throws {
        let pool = try makePool()
        let cases: [(String, WorkTask, String)] = [
            (pool.backlog.id.uuidString, pool.backlog, "backlog"),
            (pool.linked.id.uuidString, pool.linked, "worktree"),
            (pool.hidden.id.uuidString, pool.hidden, "worktree"),
            (pool.backlog.id.uuidString.lowercased(), pool.backlog, "backlog"),
        ]

        for (argument, task, location) in cases {
            let object = try XCTUnwrap(try jsonObject(run(["task", "show", argument], in: pool.repo.root)) as? [String: Any], argument)
            XCTAssertEqual(Set(object.keys), ["id", "title", "location", "worktree", "path", "body"], argument)
            XCTAssertEqual(object["id"] as? String, task.id.uuidString, argument)
            XCTAssertEqual(object["title"] as? String, task.title, argument)
            XCTAssertEqual(object["body"] as? String, task.body, argument)
            XCTAssertEqual(object["location"] as? String, location, argument)
            if let worktree = task.worktree {
                XCTAssertEqual(object["worktree"] as? String, worktree, argument)
            } else {
                XCTAssertTrue(object["worktree"] is NSNull, argument)
            }
        }
    }

    func testShowUnknownOrMalformedIdExitsOne() throws {
        let pool = try makePool()

        assertFailed(run(["task", "show", UUID().uuidString], in: pool.repo.root), exitCode: 1)
        assertFailed(run(["task", "show", "not-a-uuid"], in: pool.repo.root), exitCode: 1)
    }

    func testListAndShowArgumentErrorsExitTwo() throws {
        let pool = try makePool()

        assertFailed(run(["task", "show"], in: pool.repo.root), exitCode: 2)
        assertFailed(run(["task", "show", pool.backlog.id.uuidString, "extra"], in: pool.repo.root), exitCode: 2)
        assertFailed(run(["task", "list", "extra"], in: pool.repo.root), exitCode: 2)
    }

    func testListAndShowOutsideGitRepositoryExitOneAndWriteNothing() throws {
        let directory = (tempRoot as NSString).appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        assertFailed(run(["task", "list"], in: directory), exitCode: 1)
        assertFailed(run(["task", "show", UUID().uuidString], in: directory), exitCode: 1)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory), [])
    }

    // MARK: - End to end

    private func runHelper(_ arguments: [String], in directory: String) throws -> (stdout: String, status: Int32) {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cway")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(bytes: output, encoding: .utf8) ?? "", process.terminationStatus)
    }

    func testEmbeddedHelperCreatesThenShowsATask() throws {
        let repo = try makeRepo()

        let create = try runHelper(["task", "create", "--title", "e2e"], in: repo.root)
        XCTAssertEqual(create.status, 0)
        let createdObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(create.stdout.utf8)) as? [String: String])
        let id = try XCTUnwrap(createdObject["id"])

        let show = try runHelper(["task", "show", id], in: repo.root)
        XCTAssertEqual(show.status, 0)
        let shown = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(show.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(shown["id"] as? String, id)
        XCTAssertEqual(shown["title"] as? String, "e2e")
        XCTAssertEqual(shown["location"] as? String, "backlog")
    }
}
