import XCTest
@testable import Clearway

final class HookShellCommandTests: XCTestCase {
    private func wrapped(exporting exportedPath: String, hook: String) -> String {
        let banner = "printf '\\n\\033[31m[hook failed: exit %d]\\033[0m\\n' \"$s\""
        let script = "export PATH=\(exportedPath); (\(hook)); s=$?; if [ $s -ne 0 ]; then \(banner); fi; exit $s"
        return "/bin/sh -c \(shellEscape(script))"
    }

    func testExportsTheGivenPathAroundTheHook() {
        let line = hookShellCommand("make setup", path: "/opt/bin:/usr/bin")

        XCTAssertTrue(line.hasPrefix("/bin/sh -c '"))
        XCTAssertEqual(line, wrapped(exporting: "'/opt/bin:/usr/bin'", hook: "make setup"))
    }

    func testEscapesASingleQuoteInThePath() {
        let line = hookShellCommand("true", path: "/it's/bin")

        XCTAssertEqual(line, wrapped(exporting: #"'/it'\''s/bin'"#, hook: "true"))
    }
}
