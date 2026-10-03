import XCTest
@testable import Clearway

final class CLIHelperPathTests: XCTestCase {

    private let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path

    private func firstEntry(_ path: String?) -> String? {
        path?.split(separator: ":").first.map(String.init)
    }

    func testPrependingPutsTheDirectoryFirstOnceOnly() {
        XCTAssertEqual(CLIHelperPath.prepended(to: "/usr/bin:/h:/bin", directory: "/h"), "/h:/usr/bin:/bin")
        XCTAssertEqual(CLIHelperPath.prepended(to: "", directory: "/h"), "/h")
    }

    func testTheDirectoryHoldsTheHelper() {
        XCTAssertEqual(CLIHelperPath.directory, helpers)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "\(helpers)/clearway"))
    }

    /// Plain shell tabs run with the surface's own environment, so `PATH` arrives through the provider.
    @MainActor
    func testEverySurfaceHasTheHelpersFirstOnPath() {
        let pairs = Ghostty.SurfaceView.childEnvironment(UUID(), nil)

        XCTAssertEqual(firstEntry(pairs.first(where: { $0.key == "PATH" })?.value), helpers)
    }

    /// Agent, task, setup and hook terminals `export PATH=` from `ShellEnvironment`, replacing the
    /// surface's own `PATH`, so the helpers have to be on that one too.
    func testCommandTerminalsHaveTheHelpersFirstOnPath() async {
        XCTAssertEqual(firstEntry(ShellEnvironment.path), helpers)
        let awaited = await ShellEnvironment.awaitPath()
        XCTAssertEqual(firstEntry(awaited), helpers)
    }

    @MainActor
    func testAShellOnTheSurfacePathResolvesClearwayToTheHelper() throws {
        let path = try XCTUnwrap(Ghostty.SurfaceView.childEnvironment(UUID(), nil).first(where: { $0.key == "PATH" })?.value)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "command -v clearway"]
        process.environment = ["PATH": path]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(String(bytes: output, encoding: .utf8), "\(helpers)/clearway\n")
    }
}
