import XCTest
@testable import Clearway

final class TaskCommandTests: XCTestCase {

    private func run(_ arguments: [String]) -> TaskCommand.Result {
        TaskCommand.run(arguments: arguments, workingDirectory: NSTemporaryDirectory()) {
            XCTFail("stdin must not be read")
            return Data()
        }
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
}
