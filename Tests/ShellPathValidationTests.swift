import XCTest
@testable import Clearway

final class ShellPathValidationTests: XCTestCase {

    // MARK: - Baseline

    func testBaselineIsTheKnownGoodConstant() {
        XCTAssertEqual(ShellPathValidation.baseline, "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    // MARK: - sanitize: accepted values

    func testSanitizeAcceptsAGoodPath() {
        XCTAssertEqual(
            ShellPathValidation.sanitize("/usr/local/bin:/usr/bin:/bin"),
            "/usr/local/bin:/usr/bin:/bin"
        )
    }

    func testSanitizeDropsATrailingColon() {
        XCTAssertEqual(ShellPathValidation.sanitize("/usr/bin:/bin:"), "/usr/bin:/bin")
    }

    func testSanitizeDropsALeadingColon() {
        XCTAssertEqual(ShellPathValidation.sanitize(":/usr/bin:/bin"), "/usr/bin:/bin")
    }

    func testSanitizeDropsADoubledColon() {
        XCTAssertEqual(ShellPathValidation.sanitize("/usr/bin::/bin"), "/usr/bin:/bin")
    }

    func testSanitizeKeepsAnAbsoluteComponentThatDoesNotExist() {
        XCTAssertEqual(
            ShellPathValidation.sanitize("/does/not/exist:/usr/bin"),
            "/does/not/exist:/usr/bin"
        )
    }

    func testSanitizeTrimsSurroundingWhitespace() {
        XCTAssertEqual(ShellPathValidation.sanitize("  /usr/bin:/bin \n"), "/usr/bin:/bin")
    }

    func testSanitizeDropsARelativeComponent() {
        XCTAssertEqual(ShellPathValidation.sanitize("/usr/bin:relative/bin"), "/usr/bin")
    }

    func testSanitizeDropsAnExplicitCurrentDirectoryComponent() {
        XCTAssertEqual(ShellPathValidation.sanitize("/usr/bin:."), "/usr/bin")
    }

    /// A relative entry is common in real profiles. Refusing the whole value for one would send
    /// the resolution to its login-only attempt and strand the user on a degraded PATH for good.
    func testSanitizeKeepsAValueWhoseOnlyFaultIsARelativeComponent() {
        XCTAssertEqual(
            ShellPathValidation.sanitize("node_modules/.bin:/usr/bin:/bin"),
            "/usr/bin:/bin"
        )
    }

    // MARK: - sanitize: refused values

    func testSanitizeRefusesAValueWithNoExistingDirectory() {
        XCTAssertNil(ShellPathValidation.sanitize("/does/not/exist:/also/not/here"))
    }

    func testSanitizeRefusesABannerLine() {
        XCTAssertNil(ShellPathValidation.sanitize("Waiting for approval…"))
    }

    /// Dropping non-absolute components leaves the existing-directory check as the only thing
    /// standing between profile chatter and a `PATH`, so a banner whose colon splits it into
    /// path-shaped pieces must still be refused.
    func testSanitizeRefusesABannerLineContainingAColon() {
        XCTAssertNil(ShellPathValidation.sanitize("Note: /usr/bin is already on your path"))
        XCTAssertNil(ShellPathValidation.sanitize("error:/usr/bin/env no such file"))
    }

    func testSanitizeRefusesAnEmptyValue() {
        XCTAssertNil(ShellPathValidation.sanitize(""))
    }

    func testSanitizeRefusesAValueOfOnlyColons() {
        XCTAssertNil(ShellPathValidation.sanitize("::"))
    }

    func testSanitizeRefusesAFileThatIsNotADirectory() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-path-validation-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertNil(ShellPathValidation.sanitize(file.path))
    }

    // MARK: - unionWithBaseline

    func testUnionAppendsTheMissingBaselineDirectories() {
        XCTAssertEqual(
            ShellPathValidation.unionWithBaseline("/opt/homebrew/bin"),
            "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        )
    }

    func testUnionKeepsTheResolvedOrder() {
        XCTAssertEqual(
            ShellPathValidation.unionWithBaseline("/bin:/opt/homebrew/bin:/usr/bin"),
            "/bin:/opt/homebrew/bin:/usr/bin:/usr/sbin:/sbin"
        )
    }

    func testUnionRemovesDuplicates() {
        XCTAssertEqual(
            ShellPathValidation.unionWithBaseline("/usr/bin:/opt/homebrew/bin:/usr/bin"),
            "/usr/bin:/opt/homebrew/bin:/bin:/usr/sbin:/sbin"
        )
    }

    func testUnionIsANoOpOnACompleteValue() {
        XCTAssertEqual(
            ShellPathValidation.unionWithBaseline(ShellPathValidation.baseline),
            ShellPathValidation.baseline
        )
    }

    func testUnionOnAnEmptyValueGivesTheBaseline() {
        XCTAssertEqual(ShellPathValidation.unionWithBaseline(""), ShellPathValidation.baseline)
    }
}
