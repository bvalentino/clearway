import XCTest
@testable import Clearway

/// `applyModel(to:model:)` — the known-agent gate and the single-word guard that stand between a
/// repo-authored `WORKFLOW.json` model value and `buildAgentPromptCommand`'s unquoted command
/// expansion.
final class AgentLaunchModelTests: XCTestCase {

    // MARK: - Agent detection

    /// All three agents take the same `--model <value>` long form, so one predicate covers them.
    func testEachKnownAgentGetsTheFlag() {
        XCTAssertEqual(applyModel(to: "claude", model: "sonnet"), "claude --model sonnet")
        XCTAssertEqual(applyModel(to: "codex", model: "gpt-5.4-codex"), "codex --model gpt-5.4-codex")
        XCTAssertEqual(applyModel(to: "grok", model: "grok-4"), "grok --model grok-4")
    }

    func testFlaggedAgentCommandGetsTheFlag() {
        XCTAssertEqual(
            applyModel(to: "claude --dangerously-skip-permissions", model: "opus"),
            "claude --dangerously-skip-permissions --model opus"
        )
    }

    func testAbsolutePathToAnAgentGetsTheFlag() {
        XCTAssertEqual(
            applyModel(to: "/opt/homebrew/bin/claude", model: "sonnet"),
            "/opt/homebrew/bin/claude --model sonnet"
        )
        XCTAssertEqual(
            applyModel(to: "/Users/me/.grok/bin/grok", model: "grok-4"),
            "/Users/me/.grok/bin/grok --model grok-4"
        )
    }

    func testUnknownCommandsAreUntouched() {
        for command in ["aider", "npx claude", "env FOO=1 claude", ""] {
            XCTAssertEqual(applyModel(to: command, model: "sonnet"), command,
                           "\(command) is not a known agent")
        }
    }

    // MARK: - Single-word guard

    func testWellFormedModelValuesInject() {
        XCTAssertEqual(applyModel(to: "claude", model: "opus"), "claude --model opus")
        XCTAssertEqual(applyModel(to: "claude", model: "claude-opus-4-8"), "claude --model claude-opus-4-8")
        XCTAssertEqual(applyModel(to: "claude", model: "claude_4.8"), "claude --model claude_4.8")
    }

    /// Non-claude agents name models with `/` and `:`, so the guard must admit more than a charset.
    func testProviderPrefixedAndTaggedModelIDsInject() {
        XCTAssertEqual(applyModel(to: "codex", model: "gpt-oss:20b"), "codex --model gpt-oss:20b")
        XCTAssertEqual(applyModel(to: "codex", model: "openai/gpt-5"), "codex --model openai/gpt-5")
    }

    func testPaddedModelIsTrimmedBeforeInjection() {
        XCTAssertEqual(applyModel(to: "claude", model: "  sonnet  "), "claude --model sonnet")
    }

    /// A value that splits into extra argv words is dropped. Unquoted `$1` word-splits but is never
    /// re-scanned for operators, so this bounds the flag to one word — it is not an injection guard.
    func testMultiWordModelIsDropped() {
        for model in ["sonnet opus", "sonnet; curl x", "opus 4.8", "a\tb", "a\nb"] {
            XCTAssertEqual(applyModel(to: "claude", model: model), "claude",
                           "\(model) splits into extra argv words, so it is dropped")
        }
    }

    // MARK: - Absent model

    func testNilAndEmptyModelLeaveTheCommandUnchanged() {
        XCTAssertEqual(applyModel(to: "claude", model: nil), "claude")
        XCTAssertEqual(applyModel(to: "claude", model: ""), "claude")
        XCTAssertEqual(applyModel(to: "claude", model: "   "), "claude")
    }

    // MARK: - Survival through the launch recipe

    /// `applyModel` returns one string, which `buildAgentPromptCommand` shell-escapes into a *single*
    /// positional. The only thing that splits `claude --model sonnet` back into three argv words is
    /// the bare `$1` in the recipe, so quoting it — the textbook SC2086 "fix", and the last unquoted
    /// expansion left in there — would turn every modelled launch into `command not found` while
    /// leaving every string-level assertion in this file green.
    func testRecipeLeavesTheAgentCommandUnquotedSoTheModelFlagWordSplits() {
        let launch = buildAgentPromptCommand(
            agentCommand: applyModel(to: "claude", model: "sonnet"),
            prompt: "Do the thing.",
            path: NSTemporaryDirectory()
        )
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }

        XCTAssertTrue(launch.command.contains("$1 \"$(cat \"$2\")\""),
                      "$1 must stay unquoted so a multi-word command word-splits: \(launch.command)")
        XCTAssertFalse(launch.command.contains("\"$1\""),
                       "quoting $1 would run `claude --model sonnet` as one binary name")
        XCTAssertTrue(launch.command.contains("'claude --model sonnet'"),
                      "the whole resolved command arrives as one escaped positional")
    }
}
