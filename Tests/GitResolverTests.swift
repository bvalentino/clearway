import XCTest
@testable import Clearway

final class GitResolverTests: XCTestCase {

    // MARK: - Search Path Order

    func testSearchPathsContainsExpectedLocations() {
        let paths = GitResolver.searchPaths
        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(paths[0], "/opt/homebrew/bin/git")
        XCTAssertEqual(paths[1], "/usr/local/bin/git")
        XCTAssertEqual(paths[2], "/usr/bin/git")
    }

    func testHomebrewAppleSiliconIsFirstPriority() {
        XCTAssertEqual(GitResolver.searchPaths.first, "/opt/homebrew/bin/git")
    }

    func testResolvedPathIsExecutable() {
        let resolved = GitResolver.resolvedPath
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: resolved),
            "Resolved git path '\(resolved)' should be executable"
        )
    }

    func testResolvedPathIsOneOfExpectedLocations() {
        let resolved = GitResolver.resolvedPath
        let allExpected = GitResolver.searchPaths + [
            Bundle.main.resourceURL?
                .appendingPathComponent("git-dist")
                .appendingPathComponent("git").path,
            "/usr/bin/git", // last-resort fallback
        ].compactMap { $0 }
        XCTAssertTrue(
            allExpected.contains(resolved),
            "Resolved path '\(resolved)' should be one of the expected locations"
        )
    }

    // MARK: - runCommand Git Dispatch

    func testRunCommandGitUsesResolvedPath() async throws {
        // Running `git --version` should succeed using the resolved git path
        let data = try await WorktreeManager.runCommand(["git", "--version"], in: NSTemporaryDirectory())
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.hasPrefix("git version"), "Expected git version output, got: \(output)")
    }

    func testRunCommandNonGitUsesEnv() async throws {
        // Running `echo hello` via /usr/bin/env should work
        let data = try await WorktreeManager.runCommand(["echo", "hello"], in: NSTemporaryDirectory())
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(output, "hello")
    }
}
