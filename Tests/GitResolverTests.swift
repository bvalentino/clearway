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

    // MARK: - Usability Probe

    func testIsUsableGitAcceptsWorkingGit() {
        // The resolved path must be usable (it passed the probe at startup)
        let resolved = GitResolver.resolvedPath
        XCTAssertTrue(
            GitResolver.isUsableGit(at: resolved),
            "Resolved git '\(resolved)' should pass the usability probe"
        )
    }

    func testIsUsableGitRejectsNonexistentPath() {
        XCTAssertFalse(
            GitResolver.isUsableGit(at: "/nonexistent/path/git"),
            "A nonexistent path should fail the usability probe"
        )
    }

    func testIsUsableGitRejectsNonFunctionalExecutable() throws {
        // Simulate an unusable git shim: an executable that exits non-zero.
        // This is the exact failure mode of `/usr/bin/git` when Xcode CLT
        // is not installed — the shim exists and is executable but fails.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeGit = tmpDir.appendingPathComponent("git")
        try "#!/bin/sh\nexit 1\n".write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGit.path
        )

        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: fakeGit.path),
            "Fake git should be executable on disk"
        )
        XCTAssertFalse(
            GitResolver.isUsableGit(at: fakeGit.path),
            "A non-functional executable should fail the usability probe"
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
