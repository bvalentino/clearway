import XCTest
import GhosttyKit
@testable import Clearway

final class GhosttyConfigTests: TempRootTestCase {

    private func makeConfig(userLine: String? = nil) throws -> ghostty_config_t {
        let cfg = try XCTUnwrap(ghostty_config_new())
        if let userLine {
            try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
            let file = (tempRoot as NSString).appendingPathComponent("config")
            try "\(userLine)\n".write(toFile: file, atomically: true, encoding: .utf8)
            ghostty_config_load_file(cfg, file)
        }
        return cfg
    }

    /// The live config: `Ghostty.App` builds its config through this, so the `path` feature being
    /// off here is what keeps `Contents/MacOS` off every terminal's `PATH`.
    func testTheLoadedConfigHasThePathFeatureOff() throws {
        let config = Ghostty.Config()
        let cfg = try XCTUnwrap(config.config)

        let enabled = try XCTUnwrap(Ghostty.Config.enabledShellIntegrationFeatures(cfg))

        XCTAssertFalse(enabled.contains("path"))
    }

    func testDisablingPathKeepsTheDefaultFeatures() throws {
        let cfg = try makeConfig()
        defer { ghostty_config_free(cfg) }

        Ghostty.Config.disableShellPathFeature(cfg)
        ghostty_config_finalize(cfg)

        XCTAssertEqual(Ghostty.Config.enabledShellIntegrationFeatures(cfg), ["cursor", "title"])
    }

    /// Ghostty's parser resets every unnamed feature to its default, so a bare `no-path` would undo a
    /// user's own `shell-integration-features` line. Also pins the bit order the reader assumes: a
    /// reordered upstream struct reads back the wrong names here.
    func testDisablingPathKeepsTheUsersOwnFeatures() throws {
        let cfg = try makeConfig(userLine: "shell-integration-features = sudo,no-title,ssh-terminfo")
        defer { ghostty_config_free(cfg) }

        Ghostty.Config.disableShellPathFeature(cfg)
        ghostty_config_finalize(cfg)

        XCTAssertEqual(Ghostty.Config.enabledShellIntegrationFeatures(cfg), ["cursor", "sudo", "ssh-terminfo"])
    }

    func testAUserConfigLineIsReadBackAsWritten() throws {
        let cfg = try makeConfig(userLine: "shell-integration-features = no-cursor,sudo,ssh-env")
        defer { ghostty_config_free(cfg) }
        ghostty_config_finalize(cfg)

        XCTAssertEqual(Ghostty.Config.enabledShellIntegrationFeatures(cfg), ["sudo", "title", "ssh-env", "path"])
    }
}
