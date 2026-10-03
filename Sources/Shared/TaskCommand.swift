import Foundation

enum TaskCommand {

    struct Result: Equatable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static let usage = """
        Usage:
          clearway task create --title <title> [--body <text>]
          clearway task list
          clearway task show <id>
          clearway help

        --body - reads the body from stdin.

        """

    static func run(arguments: [String], workingDirectory: String, readStdin: () -> Data) -> Result {
        guard let command = arguments.first, command != "help", command != "--help" else {
            return Result(stdout: usage, stderr: "", exitCode: 0)
        }
        do throws(Failure) {
            let output: String
            switch (command, arguments.dropFirst().first) {
            case ("task", "create"):
                output = try create(Array(arguments.dropFirst(2)), workingDirectory: workingDirectory, readStdin: readStdin)
            default:
                throw Failure.usage("unknown command '\(arguments.prefix(2).joined(separator: " "))'")
            }
            return Result(stdout: output, stderr: "", exitCode: 0)
        } catch {
            return Result(stdout: "", stderr: "clearway: \(error.message)\n", exitCode: error.exitCode)
        }
    }

    private struct Failure: Error {
        let message: String
        let exitCode: Int32

        static func usage(_ message: String) -> Failure { Failure(message: message, exitCode: 2) }
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
        let options = try parseOptions(arguments, allowed: ["--title", "--body"])
        guard let rawTitle = options["--title"] else { throw .usage("missing --title") }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw .usage("--title is empty") }

        var body = options["--body"] ?? ""
        if body == "-" {
            guard let stdin = String(data: readStdin(), encoding: .utf8) else { throw .runtime("stdin is not valid UTF-8") }
            body = stdin
        }

        let project = try resolveProject(in: workingDirectory)
        let task = WorkTask(title: title, body: body)
        let path = TaskFiles.centralPath(for: task.id, tasksDirectory: TaskFiles.tasksDirectory(inProject: project.mainPath))
        do {
            try TaskFiles.write(task, toPath: path)
        } catch {
            throw .runtime("cannot write \(path): \(error.localizedDescription)")
        }
        return try json(Created(id: task.id.uuidString, path: path))
    }

    /// Parses `--flag value` pairs. Every flag takes exactly one value, which may itself start
    /// with `-` (a title like `-leading dash`, or `--body -`).
    private static func parseOptions(_ arguments: [String], allowed: Set<String>) throws(Failure) -> [String: String] {
        var options: [String: String] = [:]
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            guard allowed.contains(argument) else {
                throw .usage(argument.hasPrefix("-") ? "unknown option '\(argument)'" : "unexpected argument '\(argument)'")
            }
            guard let value = remaining.popFirst() else { throw .usage("\(argument) needs a value") }
            guard options.updateValue(value, forKey: argument) == nil else { throw .usage("\(argument) given more than once") }
        }
        return options
    }

    // MARK: - Project resolution

    private static func resolveProject(in workingDirectory: String) throws(Failure) -> Project {
        let output = try git(["worktree", "list", "--porcelain"], in: workingDirectory)
        let mainBlock = output.components(separatedBy: "\n\n").first ?? ""
        guard !mainBlock.components(separatedBy: "\n").contains("bare") else {
            throw .runtime("the main worktree is a bare repository, which has no task backlog")
        }
        let paths = Worktree.parseList(output).compactMap(\.path)
        guard let mainPath = paths.first else { throw .runtime("git listed no worktrees") }
        return Project(mainPath: mainPath, worktreePaths: paths)
    }

    private static func git(_ arguments: [String], in directory: String) throws(Failure) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw .runtime("git not found: \(error.localizedDescription)")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let envCommandNotFound: Int32 = 127
        guard process.terminationStatus != envCommandNotFound else { throw .runtime("git not found") }
        guard process.terminationStatus == 0 else {
            let firstLine = (String(bytes: errorOutput, encoding: .utf8) ?? "")
                .split(separator: "\n").first.map(String.init) ?? "git exited with status \(process.terminationStatus)"
            throw .runtime("not a git repository: \(firstLine)")
        }
        guard let text = String(bytes: output, encoding: .utf8) else { throw .runtime("git printed output that is not UTF-8") }
        return text
    }

    // MARK: - Output

    private static func json(_ value: some Encodable) throws(Failure) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            return (String(bytes: data, encoding: .utf8) ?? "") + "\n"
        } catch {
            throw .runtime("cannot encode output: \(error.localizedDescription)")
        }
    }
}
