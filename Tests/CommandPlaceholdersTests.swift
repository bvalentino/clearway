import XCTest
@testable import Clearway

/// Pins the substitution rule the after-create run and the Plan action share: `{{ task_path }}`
/// is replaced raw, and a command that names no task keeps its token.
final class CommandPlaceholdersTests: XCTestCase {

    private func makeCommand(
        text: String,
        name: String = "Work the task",
        kind: SavedCommand.Kind = .agent,
        agent: String = "claude",
        autoRun: Bool = true
    ) -> SavedCommand {
        SavedCommand(id: UUID(), name: name, kind: kind, text: text, agent: agent, autoRun: autoRun)
    }

    func testTokenIsReplacedWithTheGivenPath() {
        let command = makeCommand(text: "/work {{ task_path }}")
        let result = CommandPlaceholders.substituted(command, taskPath: "/repo/.clearway/TASK.md")
        XCTAssertEqual(result.text, "/work /repo/.clearway/TASK.md")
    }

    func testEveryOccurrenceIsReplaced() {
        let command = makeCommand(text: "read {{ task_path }} then rewrite {{ task_path }}")
        let result = CommandPlaceholders.substituted(command, taskPath: "/repo/t.md")
        XCTAssertEqual(result.text, "read /repo/t.md then rewrite /repo/t.md")
    }

    /// A command that names no task has nothing to say about one, so the token stays as typed
    /// rather than collapsing to a blank the agent would read as a malformed path.
    func testNilPathLeavesEveryTokenVerbatim() {
        let command = makeCommand(text: "review {{ task_path }} and {{ task_path }}")
        let result = CommandPlaceholders.substituted(command, taskPath: nil)
        XCTAssertEqual(result, command)
        XCTAssertEqual(result.text, "review {{ task_path }} and {{ task_path }}")
    }

    func testTextWithNoTokenIsUnchanged() {
        let command = makeCommand(text: "Review the open PR")
        XCTAssertEqual(
            CommandPlaceholders.substituted(command, taskPath: "/repo/t.md"),
            command
        )
    }

    /// The prompt travels as one argv element through `AgentLaunch`'s temp file, so quoting or
    /// escaping the path here would arrive at the agent as literal quote characters.
    func testPathWithASpaceIsSubstitutedRaw() {
        let command = makeCommand(text: "/work {{ task_path }}")
        let result = CommandPlaceholders.substituted(
            command,
            taskPath: "/repo/My Project/.clearway/TASK.md"
        )
        XCTAssertEqual(result.text, "/work /repo/My Project/.clearway/TASK.md")
    }

    func testOnlyTheTextDiffersFromTheInputCommand() {
        let command = makeCommand(
            text: "/work {{ task_path }}",
            name: "Plan",
            kind: .agent,
            agent: "codex",
            autoRun: false
        )
        let result = CommandPlaceholders.substituted(command, taskPath: "/repo/t.md")
        XCTAssertEqual(result.id, command.id)
        XCTAssertEqual(result.name, command.name)
        XCTAssertEqual(result.kind, command.kind)
        XCTAssertEqual(result.agent, command.agent)
        XCTAssertEqual(result.autoRun, command.autoRun)
        XCTAssertNotEqual(result.text, command.text)
    }

    func testTheTokenIsTheOneTheHelperPublishes() {
        let command = makeCommand(text: CommandPlaceholders.taskPath)
        XCTAssertEqual(
            CommandPlaceholders.substituted(command, taskPath: "/repo/t.md").text,
            "/repo/t.md"
        )
    }
}
