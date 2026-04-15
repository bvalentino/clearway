import XCTest
@testable import Clearway

final class GhosttyShellTests: XCTestCase {

    // MARK: - Basic cases

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual(Ghostty.Shell.escape(""), "")
    }

    func testPlainAsciiUnchanged() {
        XCTAssertEqual(Ghostty.Shell.escape("foo/bar"), "foo/bar")
    }

    // MARK: - Individual characters

    func testSpaceIsEscaped() {
        XCTAssertEqual(Ghostty.Shell.escape("/Users/a b/c.txt"), "/Users/a\\ b/c.txt")
    }

    func testSingleQuoteIsEscaped() {
        XCTAssertEqual(Ghostty.Shell.escape("/Users/a'b"), "/Users/a\\'b")
    }

    func testNewlineIsNotEscaped() {
        // Newline is intentionally not in the escape set: `\<newline>` is a
        // shell line-continuation sequence, so escaping would corrupt paths.
        XCTAssertEqual(Ghostty.Shell.escape("a\nb"), "a\nb")
    }

    // MARK: - Unicode

    func testUnicodePathUnchanged() {
        XCTAssertEqual(Ghostty.Shell.escape("/tmp/café.txt"), "/tmp/café.txt")
    }

    // MARK: - Every escape character, backslash escaped first

    func testAllEscapeCharactersEscapedExactlyOnce() {
        // Build expected output by pairing each input character with its escaped form.
        // Verifies every character in the escape set is prefixed with exactly one backslash.
        let pairs: [(String, String)] = [
            ("\\", "\\\\"),
            (" ", "\\ "),
            ("\t", "\\\t"),
            ("(", "\\("),
            (")", "\\)"),
            ("[", "\\["),
            ("]", "\\]"),
            ("{", "\\{"),
            ("}", "\\}"),
            ("<", "\\<"),
            (">", "\\>"),
            ("\"", "\\\""),
            ("'", "\\'"),
            ("`", "\\`"),
            ("!", "\\!"),
            ("#", "\\#"),
            ("$", "\\$"),
            ("&", "\\&"),
            (";", "\\;"),
            ("|", "\\|"),
            ("*", "\\*"),
            ("?", "\\?")
        ]
        let input = pairs.map(\.0).joined()
        let expected = pairs.map(\.1).joined()
        XCTAssertEqual(Ghostty.Shell.escape(input), expected)
    }

    func testBackslashEscapedFirst_noDoubleEscape() {
        // Input has a literal backslash followed by a space: a, \, space, b
        // Step 1 (backslash escaped first): \  → \\   →  a, \, \, space, b
        // Step 2 (space escaped):           sp → \ sp →  a, \, \, \, space, b
        // Expected output chars: a \ \ \ space b  →  Swift literal "a\\\\\\ b"
        let input = "a\\ b"
        let result = Ghostty.Shell.escape(input)
        XCTAssertEqual(result, "a\\\\\\ b")
    }
}
