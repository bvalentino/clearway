import Foundation

enum TaskCommand {

    struct Result: Equatable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static let usage = """
        Usage:
          cway task create --title <title> [--body <text>]
          cway task list
          cway task show <id>
          cway help

        --body - reads the body from stdin.

        """

    static func run(arguments: [String], workingDirectory: String, readStdin: () -> Data) -> Result {
        guard let command = arguments.first, command != "help", command != "--help" else {
            return Result(stdout: usage, stderr: "", exitCode: 0)
        }
        do throws(Failure) {
            let output: String
            let rest = Array(arguments.dropFirst(2))
            switch (command, arguments.dropFirst().first) {
            case ("task", "create"):
                output = try create(rest, workingDirectory: workingDirectory, readStdin: readStdin)
            case ("task", "list"):
                output = try list(rest, workingDirectory: workingDirectory)
            case ("task", "show"):
                output = try show(rest, workingDirectory: workingDirectory)
            default:
                throw Failure.usage("unknown command '\(arguments.prefix(2).joined(separator: " "))'.")
            }
            return Result(stdout: output, stderr: "", exitCode: 0)
        } catch {
            return Result(stdout: "", stderr: "cway: \(error.message)\n", exitCode: error.exitCode)
        }
    }

    private struct Failure: Error {
        let message: String
        let exitCode: Int32

        static func usage(_ message: String) -> Failure { Failure(message: message + " Run 'cway help' for usage.", exitCode: 2) }
        static func strayArgument(_ argument: String, to command: String) -> Failure {
            .usage("'\(command)' does not take the argument '\(argument)'.")
        }
        static func runtime(_ message: String) -> Failure { Failure(message: message, exitCode: 1) }
    }

    private struct Project {
        let mainPath: String
        let worktreePaths: [String]
    }

    // MARK: - task create

    private struct Created: Encodable {
        let id: String
        let path: String
    }

    private static func create(_ arguments: [String], workingDirectory: String, readStdin: () -> Data) throws(Failure) -> String {
        let options = try parseOptions(arguments, allowed: ["--title", "--body"], command: "task create")
        guard let rawTitle = options["--title"] else { throw .usage("'task create' needs --title <title>.") }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw .usage("--title is empty; give the task a title.") }

        var body = options["--body"] ?? ""
        if body == "-" {
            guard let stdin = String(data: readStdin(), encoding: .utf8) else { throw .runtime("the body read from stdin (--body -) is not valid UTF-8.") }
            body = stdin
        }

        let project = try resolveProject(in: workingDirectory)
        let task = WorkTask(title: title, body: body)
        let path = TaskFiles.centralPath(for: task.id, tasksDirectory: TaskFiles.tasksDirectory(inProject: project.mainPath))
        do {
            try TaskFiles.write(task, toPath: path)
        } catch {
            throw .runtime("could not write the task file '\(path)': \(error.localizedDescription)")
        }
        return try json(Created(id: task.id.uuidString, path: path))
    }

    /// Parses `--flag value` pairs. Every flag takes exactly one value, which may itself start
    /// with `-` (a title like `-leading dash`, or `--body -`).
    private static func parseOptions(_ arguments: [String], allowed: Set<String>, command: String) throws(Failure) -> [String: String] {
        var options: [String: String] = [:]
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            guard allowed.contains(argument) else {
                throw argument.hasPrefix("-")
                    ? .usage("'\(command)' has no option '\(argument)'.")
                    : .strayArgument(argument, to: command)
            }
            guard let value = remaining.popFirst() else { throw .usage("\(argument) needs a value.") }
            guard options.updateValue(value, forKey: argument) == nil else { throw .usage("\(argument) is given more than once.") }
        }
        return options
    }

    // MARK: - task list, task show

    private struct Entry: Encodable {
        let id: String
        let title: String
        let location: String
        let worktree: String?
        let path: String
        let body: String?

        init(_ loaded: TaskFiles.LoadedTask, tasksDirectory: String, includingBody: Bool) {
            id = loaded.task.id.uuidString
            title = loaded.task.title
            location = (loaded.path as NSString).deletingLastPathComponent == tasksDirectory ? "backlog" : "worktree"
            worktree = loaded.task.worktree
            path = loaded.path
            body = includingBody ? loaded.task.body : nil
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, location, worktree, path, body
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(location, forKey: .location)
            try container.encode(worktree, forKey: .worktree)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(body, forKey: .body)
        }
    }

    private static func list(_ arguments: [String], workingDirectory: String) throws(Failure) -> String {
        if let extra = arguments.first { throw .strayArgument(extra, to: "task list") }
        let (pool, tasksDirectory, _) = try loadPool(in: workingDirectory)
        return try json(pool.filter { !$0.task.hidden }.map { Entry($0, tasksDirectory: tasksDirectory, includingBody: false) })
    }

    private static func show(_ arguments: [String], workingDirectory: String) throws(Failure) -> String {
        guard let idArgument = arguments.first else { throw .usage("'task show' needs a task id.") }
        if let extra = arguments.dropFirst().first { throw .strayArgument(extra, to: "task show") }
        guard let id = UUID(uuidString: idArgument) else {
            throw .runtime("'\(idArgument)' is not a task id. A task id is a UUID; run 'cway task list' to see the ids.")
        }
        let (pool, tasksDirectory, mainPath) = try loadPool(in: workingDirectory)
        guard let loaded = pool.first(where: { $0.task.id == id }) else {
            throw .runtime("no task with id \(id.uuidString) in the project at '\(mainPath)'. Run 'cway task list' to see the tasks.")
        }
        return try json(Entry(loaded, tasksDirectory: tasksDirectory, includingBody: true))
    }

    private static func loadPool(
        in workingDirectory: String
    ) throws(Failure) -> (pool: [TaskFiles.LoadedTask], tasksDirectory: String, mainPath: String) {
        let project = try resolveProject(in: workingDirectory)
        let tasksDirectory = TaskFiles.tasksDirectory(inProject: project.mainPath)
        return (TaskFiles.loadPool(tasksDirectory: tasksDirectory, worktreePaths: project.worktreePaths), tasksDirectory, project.mainPath)
    }

    // MARK: - Project resolution

    private static func resolveProject(in workingDirectory: String) throws(Failure) -> Project {
        let arguments = ["worktree", "list", "--porcelain"]
        let output = try git(arguments, in: workingDirectory)
        let worktrees = Worktree.parseList(output)
        guard let mainPath = worktrees.first?.path else {
            throw .runtime("\(quoted(arguments)) in '\(workingDirectory)' listed no worktrees.")
        }
        let mainBlock = output.components(separatedBy: "\n\n").first ?? ""
        guard !mainBlock.components(separatedBy: "\n").contains("bare") else {
            throw .runtime(
                "the main worktree of this repository, '\(mainPath)', is a bare repository with no task backlog. "
                    + "cway needs a project whose main worktree is checked out."
            )
        }
        let carriers = Worktree.taskCarriers(Worktree.applyHeadResolution(to: worktrees))
        return Project(mainPath: mainPath, worktreePaths: carriers.map(\.path))
    }

    private static func quoted(_ gitArguments: [String]) -> String {
        "'git \(gitArguments.joined(separator: " "))'"
    }

    private static func git(_ arguments: [String], in directory: String) throws(Failure) -> String {
        // Checked before Process sees the path: a deleted working directory reaches here as "",
        // and Process raises an uncatchable Objective-C exception for it.
        guard !directory.isEmpty else {
            throw .runtime("the current directory no longer exists. cd into a project and run cway again.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .runtime("the current directory '\(directory)' does not exist. cd into a project and run cway again.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw .runtime("could not start git in '\(directory)': \(error.localizedDescription)")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let status = process.terminationStatus
        guard status == 0 else {
            throw gitFailure(status: status, stderr: errorOutput, directory: directory, command: quoted(arguments))
        }
        guard let text = String(bytes: output, encoding: .utf8) else {
            throw .runtime("\(quoted(arguments)) in '\(directory)' printed output that is not UTF-8.")
        }
        return text
    }

    private static func gitFailure(status: Int32, stderr: Data, directory: String, command: String) -> Failure {
        let envCommandNotFound: Int32 = 127
        let gitFatal: Int32 = 128
        if status == envCommandNotFound {
            return .runtime("git was not found on PATH. cway runs git to find the project; install git or add it to PATH.")
        }
        // swiftlint:disable:next optional_data_string_conversion
        let lines = String(decoding: stderr, as: UTF8.self) // shown, not parsed: git echoes non-UTF-8 config values
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if status == gitFatal, lines.first?.hasPrefix("fatal: not a git repository (or any ") == true {
            return .runtime(
                "the current directory '\(directory)' is not inside a git repository. "
                    + "Run cway from inside a project or one of its worktrees."
            )
        }
        let framing = "could not find the project for '\(directory)': \(command) exited with status \(status)"
        guard !lines.isEmpty else { return .runtime("\(framing) and printed nothing.") }
        return .runtime(([framing + ". git said:"] + lines.map { "  \($0)" }).joined(separator: "\n"))
    }

    // MARK: - Output

    private static func json(_ value: some Encodable) throws(Failure) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            return (String(bytes: data, encoding: .utf8) ?? "") + "\n"
        } catch {
            throw .runtime("could not encode the output as JSON: \(error.localizedDescription)")
        }
    }
}
