import XCTest
@testable import Clearway

/// Decode + validation tests for `WorkflowDefinition` (`.clearway/WORKFLOW.json`).
/// Pure-model tests decode JSON literals directly; the load-path tests write a fixture
/// into a temp project directory and exercise `load(projectPath:)` / `hasJSONWorkflow`.
final class WorkflowDefinitionTests: XCTestCase {

    private var tempRoot: String!

    override func setUp() {
        super.setUp()
        tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-workflow-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root = tempRoot {
            try? FileManager.default.removeItem(atPath: root)
        }
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// The canonical valid graph from the spec brief: implement → test → review (terminal).
    private static let validGraphJSON = """
    {
      "version": 1,
      "start": "implement",
      "actions": {
        "implement": {
          "name": "Implement",
          "instructions": "Implement the task described in TASK.md.",
          "routes": { "success": "test" }
        },
        "test": {
          "name": "Test",
          "instructions": "Run the test suite.",
          "routes": { "success": "review" }
        },
        "review": {
          "name": "Review",
          "instructions": "Review the diff."
        }
      }
    }
    """

    private func decode(_ json: String) throws -> WorkflowDefinition {
        try JSONDecoder().decode(WorkflowDefinition.self, from: Data(json.utf8))
    }

    /// Writes `json` to `.clearway/WORKFLOW.json` under `tempRoot` and returns the project path.
    private func writeWorkflow(_ json: String) throws -> String {
        let clearwayDir = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: clearwayDir, withIntermediateDirectories: true)
        let path = (clearwayDir as NSString).appendingPathComponent("WORKFLOW.json")
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        return tempRoot
    }

    // MARK: - Valid graph

    func testValidGraphDecodesAndValidates() throws {
        let definition = try decode(Self.validGraphJSON)

        XCTAssertEqual(definition.version, 1)
        XCTAssertEqual(definition.start, "implement")
        XCTAssertEqual(definition.actions.count, 3)
        XCTAssertEqual(definition.actions["implement"]?.routes["success"], "test")
        XCTAssertEqual(definition.actions["test"]?.routes["success"], "review")

        // validate() must not throw for a well-formed graph.
        XCTAssertNoThrow(try definition.validate())
    }

    func testOrderedActionSlugsFollowsFlowThenAppendsUnreached() throws {
        // Linear flow: start → test → review (terminal) — flow order, not map order.
        let linear = try decode(Self.validGraphJSON)
        XCTAssertEqual(linear.orderedActionSlugs(), ["implement", "test", "review"],
                       "slugs come out in flow order from start")

        // A self-cycle plus an island the walk never reaches: the cycle must terminate after one
        // visit, and the unreached action is appended (sorted) rather than dropped.
        let branched = try decode("""
        {
          "version": 1,
          "start": "fix",
          "actions": {
            "fix": { "name": "Fix", "instructions": "Fix.", "routes": { "again": "fix" } },
            "island": { "name": "Island", "instructions": "Detached." }
          }
        }
        """)
        XCTAssertEqual(branched.orderedActionSlugs(), ["fix", "island"],
                       "a self-cycle stops after one visit; the unreached island is appended")
    }

    func testIsTerminalAndLegalNext() throws {
        let definition = try decode(Self.validGraphJSON)

        XCTAssertFalse(definition.isTerminal("implement"))
        XCTAssertEqual(definition.legalNext(from: "implement"), ["test"])

        // A routeless action is terminal with no legal next values.
        XCTAssertTrue(definition.isTerminal("review"))
        XCTAssertEqual(definition.legalNext(from: "review"), [])

        // An unknown slug is treated as terminal (engine never advances past it).
        XCTAssertTrue(definition.isTerminal("nope"))
        XCTAssertEqual(definition.legalNext(from: "nope"), [])
    }

    func testLoadFromProjectDirectory() throws {
        let projectPath = try writeWorkflow(Self.validGraphJSON)

        let definition = try WorkflowDefinition.load(projectPath: projectPath)
        XCTAssertEqual(definition.start, "implement")
        XCTAssertTrue(WorkflowDefinition.hasJSONWorkflow(projectPath: projectPath))
    }

    // MARK: - Missing start target

    func testMissingStartTargetReportsSpecificDefect() throws {
        let json = """
        {
          "version": 1,
          "start": "nonexistent",
          "actions": {
            "implement": { "name": "Implement", "instructions": "Do it." }
          }
        }
        """
        let definition = try decode(json)
        XCTAssertThrowsError(try definition.validate()) { error in
            XCTAssertEqual(error as? WorkflowDefinition.LoadError, .startTargetMissing(start: "nonexistent"))
        }
    }

    // MARK: - Dangling route target

    func testDanglingRouteTargetReportsSpecificDefect() throws {
        let json = """
        {
          "version": 1,
          "start": "implement",
          "actions": {
            "implement": {
              "name": "Implement",
              "instructions": "Do it.",
              "routes": { "success": "ghost" }
            }
          }
        }
        """
        let definition = try decode(json)
        XCTAssertThrowsError(try definition.validate()) { error in
            XCTAssertEqual(
                error as? WorkflowDefinition.LoadError,
                .routeTargetMissing(action: "implement", outcome: "success", target: "ghost")
            )
        }
    }

    // MARK: - Empty actions

    func testEmptyActionsReportsNoActions() throws {
        let json = """
        { "version": 1, "start": "implement", "actions": {} }
        """
        let definition = try decode(json)
        XCTAssertThrowsError(try definition.validate()) { error in
            XCTAssertEqual(error as? WorkflowDefinition.LoadError, .noActions)
        }
    }

    // MARK: - Terminal (routeless) action

    func testTerminalRoutelessActionDecodesAsEmptyRoutes() throws {
        let json = """
        {
          "version": 1,
          "start": "only",
          "actions": {
            "only": { "name": "Only", "instructions": "One and done." }
          }
        }
        """
        let definition = try decode(json)

        XCTAssertEqual(definition.actions["only"]?.routes, [:])
        XCTAssertTrue(definition.isTerminal("only"))
        // A single terminal start action is a legal (if tiny) workflow.
        XCTAssertNoThrow(try definition.validate())
    }

    // MARK: - Agent / hooks defaults

    func testAgentDefaultsWhenAgentOmitted() throws {
        let definition = try decode(Self.validGraphJSON)

        XCTAssertEqual(definition.agent.command, WorkflowDefinition.AgentSettings.defaultCommand)
        XCTAssertEqual(definition.agent.command, "claude")
        XCTAssertEqual(definition.agent.timeoutMs, WorkflowDefinition.AgentSettings.defaultTimeoutMs)
        XCTAssertNil(definition.hooks)
    }

    func testAgentPartialOverrideKeepsOtherDefault() throws {
        let json = """
        {
          "version": 1,
          "start": "only",
          "agent": { "command": "codex" },
          "actions": {
            "only": { "name": "Only", "instructions": "Go." }
          }
        }
        """
        let definition = try decode(json)
        XCTAssertEqual(definition.agent.command, "codex")
        // timeout_ms omitted → falls back to the default.
        XCTAssertEqual(definition.agent.timeoutMs, WorkflowDefinition.AgentSettings.defaultTimeoutMs)
    }

    func testHooksDecodeWithSnakeCaseKeys() throws {
        let json = """
        {
          "version": 1,
          "start": "only",
          "agent": { "command": "claude", "timeout_ms": 1234 },
          "hooks": { "after_create": "echo created", "before_run": "echo running" },
          "actions": {
            "only": { "name": "Only", "instructions": "Go." }
          }
        }
        """
        let definition = try decode(json)
        XCTAssertEqual(definition.agent.timeoutMs, 1234)
        XCTAssertEqual(definition.hooks?.afterCreate, "echo created")
        XCTAssertEqual(definition.hooks?.beforeRun, "echo running")
    }

    func testActionSnakeCaseLoopGuardKeysDecode() throws {
        let json = """
        {
          "version": 1,
          "start": "test",
          "actions": {
            "test": {
              "name": "Test",
              "instructions": "Run tests.",
              "routes": { "success": "fix" },
              "max_attempts": 3,
              "on_max_attempts": "fix"
            },
            "fix": { "name": "Fix", "instructions": "Patch it.", "routes": { "success": "test" } }
          }
        }
        """
        let definition = try decode(json)
        XCTAssertEqual(definition.actions["test"]?.maxAttempts, 3)
        XCTAssertEqual(definition.actions["test"]?.onMaxAttempts, "fix")
        XCTAssertNoThrow(try definition.validate())
    }

    // MARK: - Load-path error surfacing

    func testHasJSONWorkflowFalseWhenFileAbsent() {
        XCTAssertFalse(WorkflowDefinition.hasJSONWorkflow(projectPath: tempRoot))
        XCTAssertThrowsError(try WorkflowDefinition.load(projectPath: tempRoot)) { error in
            guard case .fileNotFound = error as? WorkflowDefinition.LoadError else {
                return XCTFail("expected .fileNotFound, got \(error)")
            }
        }
    }

    func testHasJSONWorkflowFalseWhenJSONMalformed() throws {
        let projectPath = try writeWorkflow("{ not valid json")
        XCTAssertFalse(WorkflowDefinition.hasJSONWorkflow(projectPath: projectPath))
        XCTAssertThrowsError(try WorkflowDefinition.load(projectPath: projectPath)) { error in
            guard case .malformedJSON = error as? WorkflowDefinition.LoadError else {
                return XCTFail("expected .malformedJSON, got \(error)")
            }
        }
    }

    func testHasJSONWorkflowFalseWhenGraphInvalid() throws {
        // Decodes fine, but the dangling start pointer must fail validation, so the gate
        // reads as "no JSON workflow" rather than silently enabling a broken loop.
        let json = """
        { "version": 1, "start": "ghost", "actions": {
            "real": { "name": "Real", "instructions": "x" } } }
        """
        let projectPath = try writeWorkflow(json)
        XCTAssertFalse(WorkflowDefinition.hasJSONWorkflow(projectPath: projectPath))
    }
}
