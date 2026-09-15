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

    func testTerminalCommandWithAutoRunExecutes() {
        let command = makeCommand(kind: .terminal, text: "bin/dev", autoRun: true)
        XCTAssertEqual(CommandLaunch.launch(for: command), .shell(text: "bin/dev", execute: true))
    }

    func testTerminalCommandWithoutAutoRunIsStaged() {
        let command = makeCommand(kind: .terminal, text: "bin/dev", autoRun: false)
        XCTAssertEqual(CommandLaunch.launch(for: command), .shell(text: "bin/dev", execute: false))
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
        XCTAssertEqual(CommandLaunch.launch(for: command), .shell(text: "bin/dev", execute: true))
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
