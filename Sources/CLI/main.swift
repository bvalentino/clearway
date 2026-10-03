import Foundation

let result = TaskCommand.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    workingDirectory: FileManager.default.currentDirectoryPath,
    readStdin: { FileHandle.standardInput.readDataToEndOfFile() }
)
FileHandle.standardOutput.write(Data(result.stdout.utf8))
FileHandle.standardError.write(Data(result.stderr.utf8))
exit(result.exitCode)
