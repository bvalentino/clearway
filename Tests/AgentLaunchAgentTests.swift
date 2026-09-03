import XCTest
@testable import Clearway

/// `resolveAgentCommand` — the four-level chain (entry → workflow → Settings → default) and the
/// allowlist that gates the two `WORKFLOW.json` levels. An off-allowlist value is never an error:
/// it falls through, so a typo costs a step its agent rather than disabling the workflow.
final class AgentLaunchAgentTests: XCTestCase {

    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "resolveAgent.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func resolve(entry: String?, workflow: String?) -> String {
        resolveAgentCommand(entryCommand: entry, workflowCommand: workflow, defaults: defaults)
    }

    // MARK: - Level precedence

    func testEntryCommandWinsOverEveryOtherLevel() {
        defaults.set("grok", forKey: SettingsKey.mainTerminalCommand)
        XCTAssertEqual(resolve(entry: "codex", workflow: "claude"), "codex")
    }

    func testWorkflowCommandWinsWhenTheEntryNamesNoAgent() {
        defaults.set("grok", forKey: SettingsKey.mainTerminalCommand)
        XCTAssertEqual(resolve(entry: nil, workflow: "claude"), "claude")
        XCTAssertEqual(resolve(entry: "", workflow: "claude"), "claude")
        XCTAssertEqual(resolve(entry: "   ", workflow: "claude"), "claude")
    }

    func testSettingsWinsWhenNeitherWorkflowLevelNamesAnAgent() {
        defaults.set("grok", forKey: SettingsKey.mainTerminalCommand)
        XCTAssertEqual(resolve(entry: nil, workflow: nil), "grok")
        XCTAssertEqual(resolve(entry: nil, workflow: ""), "grok")
        XCTAssertEqual(resolve(entry: nil, workflow: "   "), "grok")
    }

    func testDefaultMainTerminalWinsWhenEveryLevelIsBlank() {
        XCTAssertEqual(resolve(entry: nil, workflow: nil), SettingsManager.defaultMainTerminalCommand)
        defaults.set("   ", forKey: SettingsKey.mainTerminalCommand)
        XCTAssertEqual(resolve(entry: nil, workflow: nil), SettingsManager.defaultMainTerminalCommand)
    }

    // MARK: - The allowlist gate

    func testEachAllowlistedAgentIsAdmittedAtBothWorkflowLevels() {
        defaults.set("aider", forKey: SettingsKey.mainTerminalCommand)
        for agent in ["claude", "grok", "codex"] {
            XCTAssertEqual(resolve(entry: agent, workflow: nil), agent)
            XCTAssertEqual(resolve(entry: nil, workflow: agent), agent)
        }
    }

    /// The last path component is used for the *check* only — the launch runs the string as written,
    /// so a deliberately-pinned binary is never silently rewritten to a bare `claude`.
    func testAPathToAnAllowlistedAgentIsAdmittedAndLaunchedVerbatim() {
        defaults.set("aider", forKey: SettingsKey.mainTerminalCommand)
        XCTAssertEqual(resolve(entry: "/opt/homebrew/bin/claude", workflow: nil), "/opt/homebrew/bin/claude")
        XCTAssertEqual(resolve(entry: nil, workflow: "/Users/me/.grok/bin/grok"), "/Users/me/.grok/bin/grok")
    }

    func testPaddedAllowlistedValueIsAdmittedTrimmed() {
        XCTAssertEqual(resolve(entry: "  codex  ", workflow: nil), "codex")
    }

    func testOffAllowlistEntryFallsThroughToTheWorkflowAgent() {
        for command in ["aider", "npx claude", "claude --foo", "env FOO=1 claude", "claude-code"] {
            XCTAssertEqual(resolve(entry: command, workflow: "codex"), "codex",
                           "\(command) is not an allowlisted agent")
        }
    }

    func testOffAllowlistWorkflowAgentFallsThroughToSettings() {
        defaults.set("aider", forKey: SettingsKey.mainTerminalCommand)
        for command in ["aider", "claude --dangerously-skip-permissions", "npx codex"] {
            XCTAssertEqual(resolve(entry: nil, workflow: command), "aider",
                           "\(command) is not an allowlisted agent")
        }
    }

    func testOffAllowlistAtBothWorkflowLevelsLandsOnSettings() {
        defaults.set("grok", forKey: SettingsKey.mainTerminalCommand)
        XCTAssertEqual(resolve(entry: "aider", workflow: "claude --foo"), "grok")
    }

    /// Level 3 is deliberately ungated: the Settings picker already constrains it, and gating it
    /// would disturb the Cmd+T "None" login-shell path.
    func testSettingsValueIsNeverGatedByTheAllowlist() {
        defaults.set("aider", forKey: SettingsKey.mainTerminalCommand)
        XCTAssertEqual(resolve(entry: nil, workflow: nil), "aider")
    }

    // MARK: - Whitespace never matches

    /// The launch expands the command unquoted, so a value carrying whitespace would word-split into
    /// argv. Every case here ends in an allowlisted path component, which is what a last-path-component
    /// check alone would admit: a space-bearing path launches broken, and the rest smuggle flags or
    /// swap the executable outright.
    func testWhitespaceBearingValueNeverMatches() {
        defaults.set("grok", forKey: SettingsKey.mainTerminalCommand)
        for command in ["/Users/me/My Tools/claude",
                        "claude --dangerously-skip-permissions /claude",
                        "echo pwned; /claude",
                        "/opt/bin/claude\t/codex"] {
            XCTAssertEqual(resolve(entry: command, workflow: nil), "grok",
                           "\(command) carries whitespace and must fall through")
            XCTAssertEqual(resolve(entry: nil, workflow: command), "grok",
                           "\(command) carries whitespace and must fall through")
        }
    }

    /// The gate and `applyModel`'s own gate must agree, or an admitted command silently loses its
    /// `--model` flag: `acceptsModelFlag` tests the *first* whitespace-separated token, so a
    /// whitespace-bearing value that the allowlist let through would fail it.
    func testEveryAdmittedCommandStillCarriesItsModelFlag() {
        for command in ["codex", "/opt/homebrew/bin/claude", "./grok"] {
            let resolved = resolve(entry: command, workflow: nil)
            XCTAssertEqual(applyModel(to: resolved, model: "opus"), "\(command) --model opus")
        }
    }
}
