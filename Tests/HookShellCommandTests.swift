import XCTest
@testable import Clearway

final class HookShellCommandTests: XCTestCase {
    private func runLine(_ line: String) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testExportsTheGivenPathToTheHook() throws {
        let result = try runLine(hookShellCommand(#"printf '%s' "$PATH""#, path: "/opt/bin:/usr/bin:/bin"))

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "/opt/bin:/usr/bin:/bin")
    }

    func testEscapesASingleQuoteInThePath() throws {
        let result = try runLine(hookShellCommand(#"printf '%s' "$PATH""#, path: "/it's/bin:/usr/bin:/bin"))

        XCTAssertEqual(result.stdout, "/it's/bin:/usr/bin:/bin")
    }

    func testSuccessPrintsNoBanner() throws {
        let result = try runLine(hookShellCommand("true", path: "/usr/bin:/bin"))

        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.stdout.contains("hook failed"))
    }

    func testFailurePrintsTheBannerAndKeepsTheStatus() throws {
        let result = try runLine(hookShellCommand("exit 3", path: "/usr/bin:/bin"))

        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.stdout.contains("[hook failed: exit 3]"))
    }

    func testRunsEveryLineOfAMultiLineHook() throws {
        let result = try runLine(hookShellCommand("echo 'a'\necho b", path: "/usr/bin:/bin"))

        XCTAssertEqual(result.stdout, "a\nb\n")
    }
}
