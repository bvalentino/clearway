import XCTest
@testable import Clearway

/// Covers `hookBannerCommand` — the banner wrapper fed into the persistent
/// secondary login shell via `sendPaste`.
final class HookCommandTests: XCTestCase {

    func test_hookBannerCommand_preservesMultilineCommand() {
        // `sendPaste` keeps embedded newlines, so a multi-line hook must reach the
        // subshell intact instead of being truncated at the first line.
        let out = hookBannerCommand("npm install\nnpm run codegen")
        XCTAssertTrue(out.contains("(npm install\nnpm run codegen)"),
                      "must keep both lines of a multi-line command; got: \(out)")
    }

    func test_hookBannerCommand_wrapsCommandInSubshell() {
        let out = hookBannerCommand("npm install && npm run codegen")
        XCTAssertTrue(out.contains("(npm install && npm run codegen)"),
                      "must run the chained command in a subshell; got: \(out)")
    }

    func test_hookBannerCommand_hasNoPathExportOrBinSh() {
        // pane.secondary is already a login shell with the user's PATH, so the wrapper
        // drops `hookShellCommand`'s `/bin/sh -c` and `export PATH=` boilerplate.
        let out = hookBannerCommand("npm install")
        XCTAssertFalse(out.contains("export PATH"), "no PATH export; got: \(out)")
        XCTAssertFalse(out.contains("/bin/sh -c"), "no /bin/sh -c wrapper; got: \(out)")
    }

    func test_hookBannerCommand_keepsRedFailureBanner() {
        let out = hookBannerCommand("false")
        XCTAssertTrue(out.contains("\\033[31m[hook failed: exit %d]\\033[0m"),
                      "must keep the red failure banner; got: \(out)")
        XCTAssertTrue(out.contains("[ $s -ne 0 ]"),
                      "banner must be gated on a non-zero exit status; got: \(out)")
    }

    func test_hookBannerCommand_endsCleanlyForUsablePrompt() {
        // A trailing `; true` forces a 0 status so the secondary returns to a clean prompt.
        let out = hookBannerCommand("false")
        XCTAssertTrue(out.hasSuffix("; true"),
                      "must end with `; true` so the shell stays at a clean prompt; got: \(out)")
    }
}
