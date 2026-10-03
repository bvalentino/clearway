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
        return usageError("unknown command '\(command)'")
    }

    private static func usageError(_ message: String) -> Result {
        Result(stdout: "", stderr: "clearway: \(message)\n", exitCode: 2)
    }
}
