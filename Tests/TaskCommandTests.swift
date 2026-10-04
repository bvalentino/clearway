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
        _ result: TaskCommand.Result, exitCode: Int32, stderr: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.exitCode, exitCode, file: file, line: line)
        XCTAssertEqual(result.stdout, "", file: file, line: line)
        XCTAssertEqual(result.stderr, stderr, file: file, line: line)
    }

    private func usageError(_ message: String) -> String {
        "cway: \(message) Run 'cway help' for usage.\n"
    }

    private func outsideRepoMessage(_ directory: String) -> String {
        "cway: the current directory '\(directory)' is not inside a git repository. Run cway from inside a project or one of its worktrees.\n"
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
        XCTAssertEqual(result.stderr, usageError("unknown command 'frobnicate'."))
        assertFailed(run(["task", "frob", "x"]), exitCode: 2, stderr: usageError("unknown command 'task frob'."))
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

        let cases: [([String], String)] = [
            (["task", "create"], usageError("'task create' needs --title <title>.")),
            (["task", "create", "--body", "x"], usageError("'task create' needs --title <title>.")),
            (["task", "create", "--title", ""], usageError("--title is empty; give the task a title.")),
            (["task", "create", "--title", " \n\t "], usageError("--title is empty; give the task a title.")),
        ]
        for (arguments, message) in cases {
            assertFailed(run(arguments, in: repo.root), exitCode: 2, stderr: message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: clearwayDirectory(in: repo.root)))
    }

    func testMalformedCreateArgumentsAreUsageErrorsAndWriteNothing() throws {
        let repo = try makeRepo()
        let cases: [([String], String)] = [
            (["task", "create", "--title", "x", "--force"], usageError("'task create' has no option '--force'.")),
            (["task", "create", "--title"], usageError("--title needs a value.")),
            (["task", "create", "--title", "x", "--body"], usageError("--body needs a value.")),
            (["task", "create", "--title", "x", "--title", "y"], usageError("--title is given more than once.")),
            (["task", "create", "--title", "x", "stray"], usageError("'task create' does not take the argument 'stray'.")),
        ]

        for (arguments, message) in cases {
            assertFailed(run(arguments, in: repo.root), exitCode: 2, stderr: message)
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

    func testBodyDashWithNonUTF8StdinExitsOneAndWritesNothing() throws {
        let repo = try makeRepo()

        assertFailed(
            run(["task", "create", "--title", "Piped", "--body", "-"], in: repo.root, stdin: { Data([0xFF, 0xFE]) }),
            exitCode: 1,
            stderr: "cway: the body read from stdin (--body -) is not valid UTF-8.\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: clearwayDirectory(in: repo.root)))
    }

    func testUnwritableTasksDirectoryNamesTheTaskFile() throws {
        let repo = try makeRepo()
        let tasksDirectory = (repo.root as NSString).appendingPathComponent(".clearway/tasks")
        let fm = FileManager.default
        try fm.createDirectory(atPath: tasksDirectory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tasksDirectory)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tasksDirectory) }

        let result = run(["task", "create", "--title", "Blocked"], in: repo.root)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        let prefix = "cway: could not write the task file '"
        XCTAssertTrue(result.stderr.hasPrefix(prefix), result.stderr)
        let quotedPath = result.stderr.dropFirst(prefix.count).prefix { $0 != "'" }
        XCTAssertTrue(quotedPath.contains("/.clearway/tasks/"), result.stderr)
        XCTAssertTrue(result.stderr.hasSuffix("\n"), result.stderr)
    }

    func testCreateOutsideGitRepositoryExitsOneAndWritesNothing() throws {
        let directory = (tempRoot as NSString).appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let result = run(["task", "create", "--title", "Nowhere"], in: directory)

        assertFailed(result, exitCode: 1, stderr: outsideRepoMessage(directory))
        XCTAssertFalse(result.stderr.contains(".git"))
        XCTAssertFalse(result.stderr.contains("parent directories"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clearwayDirectory(in: directory)))
    }

    func testBrokenGitfileReportsGitsReasonNotOutsideRepository() throws {
        let directory = (tempRoot as NSString).appendingPathComponent("broken")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try "gitdir: /nonexistent/x\n".write(
            toFile: (directory as NSString).appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        let result = run(["task", "list"], in: directory)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        let framing = "cway: could not find the project for '\(directory)': 'git worktree list --porcelain' exited with status 128. git said:\n"
        XCTAssertTrue(result.stderr.hasPrefix(framing), result.stderr)
        XCTAssertTrue(result.stderr.contains("\n  fatal: not a git repository:"), result.stderr)
        XCTAssertFalse(result.stderr.contains("is not inside a git repository"), result.stderr)
        XCTAssertTrue(result.stderr.hasSuffix("\n"), result.stderr)
    }

    func testGitStderrThatIsNotUTF8StillShowsGitsReason() throws {
        let repo = try makeRepo()
        let config = (repo.root as NSString).appendingPathComponent(".git/config")
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: config))
        handle.seekToEndOfFile()
        handle.write(Data("[core]\n\trepositoryformatversion = ".utf8) + Data([0xFF]) + Data("\n".utf8))
        try handle.close()

        let result = run(["task", "list"], in: repo.root)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.stderr.contains("printed nothing"), result.stderr)
        XCTAssertTrue(result.stderr.contains("\n  fatal: bad numeric config value"), result.stderr)
    }

    func testMissingWorkingDirectoryIsReportedInsteadOfCrashing() {
        let missing = (tempRoot as NSString).appendingPathComponent("gone")

        assertFailed(
            run(["task", "list"], in: missing),
            exitCode: 1,
            stderr: "cway: the current directory '\(missing)' does not exist. cd into a project and run cway again.\n"
        )
        assertFailed(
            run(["task", "list"], in: ""),
            exitCode: 1,
            stderr: "cway: the current directory no longer exists. cd into a project and run cway again.\n"
        )
    }

    func testCommandsWhoseMainWorktreeIsBareExitOneAndWriteNothing() throws {
        let source = try GitRepoFixture.make(at: (tempRoot as NSString).appendingPathComponent("source"))
        let bare = canonical(tempRoot) + "/bare.git"
        let worktree = canonical(tempRoot) + "/linked"
        _ = try GitRepoFixture.git(["clone", "-q", "--bare", source.root, bare], in: tempRoot)
        _ = try GitRepoFixture.git(["worktree", "add", "-q", worktree, "-b", "feature"], in: bare)
        let listed = try GitRepoFixture.git(["worktree", "list", "--porcelain"], in: worktree)
        let mainPath = try XCTUnwrap(Worktree.parseList(listed).first?.path)
        let message = "cway: the main worktree of this repository, '\(mainPath)', is a bare repository with no task backlog. "
            + "cway needs a project whose main worktree is checked out.\n"

        assertFailed(run(["task", "create", "--title", "Nowhere"], in: worktree), exitCode: 1, stderr: message)
        assertFailed(run(["task", "list"], in: worktree), exitCode: 1, stderr: message)
        assertFailed(run(["task", "show", UUID().uuidString], in: worktree), exitCode: 1, stderr: message)

        XCTAssertFalse(FileManager.default.fileExists(atPath: clearwayDirectory(in: bare)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clearwayDirectory(in: worktree)))
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

        let unknown = UUID()
        let listed = try GitRepoFixture.git(["worktree", "list", "--porcelain"], in: pool.repo.root)
        let mainPath = try XCTUnwrap(Worktree.parseList(listed).first?.path)

        assertFailed(
            run(["task", "show", unknown.uuidString.lowercased()], in: pool.repo.root),
            exitCode: 1,
            stderr: "cway: no task with id \(unknown.uuidString) in the project at '\(mainPath)'. Run 'cway task list' to see the tasks.\n"
        )
        assertFailed(
            run(["task", "show", "not-a-uuid"], in: pool.repo.root),
            exitCode: 1,
            stderr: "cway: 'not-a-uuid' is not a task id. A task id is a UUID; run 'cway task list' to see the ids.\n"
        )
    }

    func testListAndShowArgumentErrorsExitTwo() throws {
        let pool = try makePool()

        assertFailed(run(["task", "show"], in: pool.repo.root), exitCode: 2, stderr: usageError("'task show' needs a task id."))
        assertFailed(
            run(["task", "show", pool.backlog.id.uuidString, "extra"], in: pool.repo.root),
            exitCode: 2,
            stderr: usageError("'task show' does not take the argument 'extra'.")
        )
        assertFailed(
            run(["task", "list", "extra"], in: pool.repo.root),
            exitCode: 2,
            stderr: usageError("'task list' does not take the argument 'extra'.")
        )
    }

    func testListAndShowOutsideGitRepositoryExitOneAndWriteNothing() throws {
        let directory = (tempRoot as NSString).appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        assertFailed(run(["task", "list"], in: directory), exitCode: 1, stderr: outsideRepoMessage(directory))
        assertFailed(run(["task", "show", UUID().uuidString], in: directory), exitCode: 1, stderr: outsideRepoMessage(directory))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory), [])
    }

    func testListAndShowWarnOnStderrForSkippedFilesAndKeepTheirOutput() throws {
        let pool = try makePool()
        let mainPath = try XCTUnwrap(Worktree.parseList(try GitRepoFixture.git(["worktree", "list", "--porcelain"], in: pool.repo.root)).first?.path)
        let unparseable = TaskFiles.centralPath(for: UUID(), tasksDirectory: TaskFiles.tasksDirectory(inProject: mainPath))
        XCTAssertTrue(FileManager.default.createFile(atPath: unparseable, contents: Data("Just a body".utf8)))
        _ = try pool.repo.addWorktree(branch: "idless")
        let idless = TaskFiles.taskMarkdownPath(inWorktree: (mainPath as NSString).appendingPathComponent(".worktrees/idless"))
        try FileManager.default.createDirectory(atPath: (idless as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: idless, contents: Data("---\ntitle: No id\n---".utf8)))
        let warnings = [(unparseable, "cannot parse the frontmatter"), (idless, "its frontmatter has no id")]
            .sorted { $0.0 < $1.0 }
            .map { "cway: warning: skipped '\($0.0)': \($0.1).\n" }
            .joined()

        let listed = run(["task", "list"], in: pool.repo.root)
        XCTAssertEqual(listed.exitCode, 0)
        XCTAssertEqual(listed.stderr, warnings)
        let entries = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["id"] as? String }, [pool.linked.id.uuidString, pool.backlog.id.uuidString])

        let shown = run(["task", "show", pool.backlog.id.uuidString], in: pool.repo.root)
        XCTAssertEqual(shown.exitCode, 0)
        XCTAssertEqual(shown.stderr, warnings)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any])?["title"] as? String, "Backlog task")

        let unknown = UUID()
        assertFailed(
            run(["task", "show", unknown.uuidString], in: pool.repo.root),
            exitCode: 1,
            stderr: warnings + "cway: no task with id \(unknown.uuidString) in the project at '\(mainPath)'. Run 'cway task list' to see the tasks.\n"
        )
    }

    private func addDetachedWorktree(_ name: String, to repo: GitRepoFixture) throws -> String {
        let path = (repo.root as NSString).appendingPathComponent(".worktrees/\(name)")
        try GitRepoFixture.git(["worktree", "add", "-q", "--detach", path], in: repo.root)
        return canonical(path)
    }

    func testListAndShowSkipADetachedWorktreesTask() throws {
        let repo = try makeRepo()
        let worktree = try addDetachedWorktree("loose", to: repo)
        let task = WorkTask(title: "Loose task")
        try TaskFiles.write(task, toPath: TaskFiles.taskMarkdownPath(inWorktree: worktree))

        let entries = try XCTUnwrap(try jsonObject(run(["task", "list"], in: repo.root)) as? [[String: Any]])
        XCTAssertFalse(entries.contains { $0["id"] as? String == task.id.uuidString })

        let listed = try GitRepoFixture.git(["worktree", "list", "--porcelain"], in: repo.root)
        let mainPath = try XCTUnwrap(Worktree.parseList(listed).first?.path)
        assertFailed(
            run(["task", "show", task.id.uuidString], in: repo.root),
            exitCode: 1,
            stderr: "cway: no task with id \(task.id.uuidString) in the project at '\(mainPath)'. Run 'cway task list' to see the tasks.\n"
        )
    }

    func testListAndShowIncludeAMidRebaseWorktreesTask() throws {
        let repo = try makeRepo()
        let worktree = try addDetachedWorktree("rebasing", to: repo)
        let rebaseDirectory = (try repo.gitDir(ofWorktreeAt: worktree) as NSString).appendingPathComponent("rebase-merge")
        try FileManager.default.createDirectory(atPath: rebaseDirectory, withIntermediateDirectories: true)
        try "refs/heads/feature\n".write(
            toFile: (rebaseDirectory as NSString).appendingPathComponent("head-name"), atomically: true, encoding: .utf8
        )
        let task = WorkTask(title: "Rebasing task")
        try TaskFiles.write(task, toPath: TaskFiles.taskMarkdownPath(inWorktree: worktree))

        let entries = try XCTUnwrap(try jsonObject(run(["task", "list"], in: repo.root)) as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first { $0["id"] as? String == task.id.uuidString })
        XCTAssertEqual(entry["location"] as? String, "worktree")
        XCTAssertEqual(canonical(try XCTUnwrap(entry["path"] as? String)), TaskFiles.taskMarkdownPath(inWorktree: worktree))

        let shown = try XCTUnwrap(try jsonObject(run(["task", "show", task.id.uuidString], in: repo.root)) as? [String: Any])
        XCTAssertEqual(shown["title"] as? String, "Rebasing task")
        XCTAssertEqual(shown["location"] as? String, "worktree")
    }

    func testShowReportsTheCentralCopyWhenTheWorktreeCopyIsInADetachedWorktree() throws {
        let repo = try makeRepo()
        let worktree = try addDetachedWorktree("loose", to: repo)
        let central = WorkTask(title: "Central title")
        var local = central
        local.title = "Worktree title"
        try TaskFiles.write(central, toPath: TaskFiles.centralPath(for: central.id, tasksDirectory: TaskFiles.tasksDirectory(inProject: repo.root)))
        try TaskFiles.write(local, toPath: TaskFiles.taskMarkdownPath(inWorktree: worktree))

        let shown = try XCTUnwrap(try jsonObject(run(["task", "show", central.id.uuidString], in: repo.root)) as? [String: Any])

        XCTAssertEqual(shown["title"] as? String, "Central title")
        XCTAssertEqual(shown["location"] as? String, "backlog")
    }

    func testDetachedMainWorktreeKeepsTheBacklogButNotItsOwnTask() throws {
        let repo = try makeRepo()
        _ = try repo.addWorktree(branch: "feature")
        try GitRepoFixture.git(["checkout", "-q", "--detach"], in: repo.root)
        let mainTask = WorkTask(title: "Main task")
        try TaskFiles.write(mainTask, toPath: TaskFiles.taskMarkdownPath(inWorktree: repo.root))

        let (id, path) = try created(run(["task", "create", "--title", "Backlog task"], in: repo.root))
        XCTAssertEqual(canonical(path), TaskFiles.centralPath(for: id, tasksDirectory: TaskFiles.tasksDirectory(inProject: repo.root)))

        let entries = try XCTUnwrap(try jsonObject(run(["task", "list"], in: repo.root)) as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["id"] as? String }, [id.uuidString])
        XCTAssertEqual(entries.first?["location"] as? String, "backlog")
    }

    // MARK: - End to end

    private func runHelper(
        _ arguments: [String],
        in directory: String,
        environment: [String: String] = [:]
    ) throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cway")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(bytes: output, encoding: .utf8) ?? "",
            String(bytes: errorOutput, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }

    func testEmbeddedHelperWithoutGitOnPathSaysGitWasNotFound() throws {
        let repo = try makeRepo()

        let result = try runHelper(["task", "list"], in: repo.root, environment: ["PATH": "/nonexistent"])

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(
            result.stderr,
            "cway: git was not found on PATH. cway runs git to find the project; install git or add it to PATH.\n"
        )
    }

    func testEmbeddedHelperSaysGitPrintedNothingWhenItsStderrIsBlank() throws {
        let bin = (tempRoot as NSString).appendingPathComponent("bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let fakeGit = (bin as NSString).appendingPathComponent("git")
        try "#!/bin/sh\nprintf '  \\n\\n' >&2\nexit 3\n".write(toFile: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit)

        let result = try runHelper(["task", "list"], in: tempRoot, environment: ["PATH": "\(bin):/usr/bin:/bin"])

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.hasPrefix("cway: could not find the project for '"), result.stderr)
        XCTAssertTrue(
            result.stderr.hasSuffix("': 'git worktree list --porcelain' exited with status 3 and printed nothing.\n"),
            result.stderr
        )
    }

    func testEmbeddedHelperShowsGitsDubiousOwnershipReasonNotOutsideRepository() throws {
        let repo = try makeRepo()

        // GitHub's macOS runner image sets `safe.directory = *` globally, which disarms the check.
        let result = try runHelper(["task", "list"], in: repo.root, environment: [
            "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null"
        ])

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.hasPrefix("cway: could not find the project for '"), result.stderr)
        XCTAssertTrue(
            result.stderr.contains("'git worktree list --porcelain' exited with status 128. git said:\n"),
            result.stderr
        )
        let lines = result.stderr.split(separator: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("  fatal: detected dubious ownership") }, result.stderr)
        XCTAssertTrue(lines.contains { $0.contains("safe.directory") }, result.stderr)
        XCTAssertFalse(result.stderr.contains("is not inside a git repository"), result.stderr)
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
