import XCTest
@testable import Clearway

/// Pins the two pure rules `SavedCommand` exists to carry: the All/Terminal/Agent list filter and
/// the `SavedCommand` → `CommandLaunch` resolver. The views and `TerminalManager` work that consumes
/// them is not reachable from XCTest, which is why the rules live apart from it.
final class SavedCommandTests: XCTestCase {

    private func makeCommand(
        name: String = "Dev server",
        kind: SavedCommand.Kind = .terminal,
        text: String = "bin/dev",
        agent: String = "claude",
        autoRun: Bool = true
    ) -> SavedCommand {
        SavedCommand(id: UUID(), name: name, kind: kind, text: text, agent: agent, autoRun: autoRun)
    }

    // MARK: - Filter

    func testAllReturnsEveryCommandInInputOrder() {
        let agent = makeCommand(name: "Review", kind: .agent)
        let terminal = makeCommand(name: "Test", kind: .terminal)
        let commands = [agent, terminal]
        XCTAssertEqual(SavedCommand.filter(commands, by: .all), commands)
    }

    func testTerminalReturnsOnlyTerminalCommandsInInputOrder() {
        let first = makeCommand(name: "Dev", kind: .terminal)
        let agent = makeCommand(name: "Review", kind: .agent)
        let second = makeCommand(name: "Test", kind: .terminal)
        XCTAssertEqual(
            SavedCommand.filter([first, agent, second], by: .terminal),
            [first, second]
        )
    }

    func testAgentReturnsOnlyAgentCommandsInInputOrder() {
        let first = makeCommand(name: "Review", kind: .agent)
        let terminal = makeCommand(name: "Dev", kind: .terminal)
        let second = makeCommand(name: "Summarise", kind: .agent)
        XCTAssertEqual(
            SavedCommand.filter([first, terminal, second], by: .agent),
            [first, second]
        )
    }

    func testEmptyInputFiltersToEmptyForEveryFilter() {
        for filter in CommandFilter.allCases {
            XCTAssertEqual(SavedCommand.filter([], by: filter), [])
        }
    }

    /// `.moveDisabled` reads this: drag reorder is refused whenever the list on screen is a subset.
    func testOnlyAllIsAnInactiveFilter() {
        XCTAssertFalse(CommandFilter.all.isActive)
        XCTAssertTrue(CommandFilter.terminal.isActive)
        XCTAssertTrue(CommandFilter.agent.isActive)
    }

    // MARK: - Launch resolver

    private func shellSend(
        for command: SavedCommand,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ShellSend? {
        guard case let .shell(send) = CommandLaunch.launch(for: command) else {
            XCTFail("expected a shell launch", file: file, line: line)
            return nil
        }
        return send
    }

    func testTerminalCommandWithAutoRunExecutes() {
        let command = makeCommand(kind: .terminal, text: "bin/dev", autoRun: true)
        XCTAssertEqual(shellSend(for: command)?.lines, ["bin/dev"])
        XCTAssertEqual(shellSend(for: command)?.runsLastLine, true)
    }

    func testTerminalCommandWithoutAutoRunIsStaged() {
        let command = makeCommand(kind: .terminal, text: "bin/dev", autoRun: false)
        XCTAssertEqual(shellSend(for: command)?.lines, ["bin/dev"])
        XCTAssertEqual(shellSend(for: command)?.runsLastLine, false)
    }

    /// Every newline is an Enter, so the lines run in order; the toggle governs the last one alone.
    func testMultiLineTerminalCommandSplitsIntoOneLinePerEnter() {
        let command = makeCommand(kind: .terminal, text: "cd /tmp\npwd", autoRun: true)
        XCTAssertEqual(shellSend(for: command)?.lines, ["cd /tmp", "pwd"])
        XCTAssertEqual(shellSend(for: command)?.runsLastLine, true)
    }

    func testMultiLineTerminalCommandWithoutAutoRunStagesOnlyItsLastLine() {
        let command = makeCommand(kind: .terminal, text: "cd /tmp\npwd", autoRun: false)
        XCTAssertEqual(shellSend(for: command)?.lines, ["cd /tmp", "pwd"])
        XCTAssertEqual(shellSend(for: command)?.runsLastLine, false)
    }

    /// A `\r\n` pasted into the editor must not arrive as two Enters.
    func testCarriageReturnsNormaliseToOneLineBreak() {
        let command = makeCommand(kind: .terminal, text: "cd /tmp\r\npwd\rls")
        XCTAssertEqual(shellSend(for: command)?.lines, ["cd /tmp", "pwd", "ls"])
    }

    /// A trailing newline would otherwise stage an empty line instead of the last real one.
    func testTrailingNewlineDoesNotBecomeAnEmptyLastLine() {
        let command = makeCommand(kind: .terminal, text: "cd /tmp\npwd\n", autoRun: false)
        XCTAssertEqual(shellSend(for: command)?.lines, ["cd /tmp", "pwd"])
    }

    /// A blank line inside the text is a real Enter on an empty prompt, and is kept.
    func testInteriorBlankLineSurvives() {
        let command = makeCommand(kind: .terminal, text: "cd /tmp\n\npwd")
        XCTAssertEqual(shellSend(for: command)?.lines, ["cd /tmp", "", "pwd"])
    }

    /// Nothing to type — the surface skips it, exactly as the old first-line guard did.
    func testWhitespaceOnlyTerminalCommandSendsNothing() {
        let command = makeCommand(kind: .terminal, text: "  \n\n ")
        XCTAssertEqual(shellSend(for: command)?.lines, [])
    }

    // MARK: - Enter placement

    /// The steps are what the surface is actually handed, so these pin the whole of what
    /// "Append Enter to run immediately" governs — everything above only pins the split.

    func testAutoRunAppendsTheTrailingEnter() {
        let command = makeCommand(kind: .terminal, text: "bin/dev", autoRun: true)
        XCTAssertEqual(shellSend(for: command)?.steps, [.text("bin/dev"), .enter])
    }

    /// Without the toggle the line is typed and left on the prompt, unrun and editable. The
    /// missing trailing `.enter` is the whole safety property of staging.
    func testWithoutAutoRunTheLastLineIsTypedButNotRun() {
        let command = makeCommand(kind: .terminal, text: "git reset --hard origin/main", autoRun: false)
        XCTAssertEqual(shellSend(for: command)?.steps, [.text("git reset --hard origin/main")])
    }

    func testInteriorNewlinesAreEntersRegardlessOfTheToggle() {
        let running = makeCommand(kind: .terminal, text: "cd /tmp\npwd", autoRun: true)
        XCTAssertEqual(
            shellSend(for: running)?.steps,
            [.text("cd /tmp"), .enter, .text("pwd"), .enter]
        )

        let staged = makeCommand(kind: .terminal, text: "cd /tmp\npwd", autoRun: false)
        XCTAssertEqual(
            shellSend(for: staged)?.steps,
            [.text("cd /tmp"), .enter, .text("pwd")],
            "Only the last line is held back — the earlier lines still run"
        )
    }

    func testEmptyTextProducesNoSteps() {
        let command = makeCommand(kind: .terminal, text: "  \n\n ", autoRun: true)
        XCTAssertEqual(shellSend(for: command)?.steps, [])
    }

    func testAgentCommandWithAutoRunSubmits() {
        let command = makeCommand(kind: .agent, text: "Review the PR", agent: "codex", autoRun: true)
        XCTAssertEqual(
            CommandLaunch.launch(for: command),
            .agent(agent: "codex", prompt: "Review the PR", submit: true)
        )
    }

    func testAgentCommandWithoutAutoRunIsStaged() {
        let command = makeCommand(kind: .agent, text: "Review the PR", agent: "codex", autoRun: false)
        XCTAssertEqual(
            CommandLaunch.launch(for: command),
            .agent(agent: "codex", prompt: "Review the PR", submit: false)
        )
    }

    /// The agent case carries the command's own agent, never Settings → Main Terminal's.
    func testAgentCaseCarriesTheCommandsOwnAgent() {
        let command = makeCommand(kind: .agent, agent: "grok")
        guard case let .agent(agent, _, _) = CommandLaunch.launch(for: command) else {
            return XCTFail("expected an agent launch")
        }
        XCTAssertEqual(agent, "grok")
    }

    /// A terminal command's `agent` field is inert — it survives editing but never reaches a launch.
    func testTerminalCommandIgnoresItsAgentField() {
        let command = makeCommand(kind: .terminal, text: "bin/dev", agent: "grok", autoRun: true)
        XCTAssertEqual(shellSend(for: command)?.lines, ["bin/dev"])
    }

    // MARK: - Decoding

    /// A file hand-written with an unrecognized kind must not take the whole list down with it.
    func testUnknownKindDecodesAsTerminal() throws {
        let json = Data("""
        {"id":"7B1F0B1E-0000-4000-8000-000000000001","name":"Mystery","kind":"wormhole",
         "text":"bin/dev","agent":"claude","autoRun":false}
        """.utf8)
        let decoded = try JSONDecoder().decode(SavedCommand.self, from: json)
        XCTAssertEqual(decoded.kind, .terminal)
        XCTAssertEqual(decoded.name, "Mystery")
    }

    func testRoundTripsThroughJSONUnchanged() throws {
        let command = makeCommand(kind: .agent, text: "Review the PR", agent: "codex", autoRun: false)
        let data = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(SavedCommand.self, from: data), command)
    }
}
