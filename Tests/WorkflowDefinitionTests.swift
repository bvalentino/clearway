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

    // MARK: - Reserved backlog-marker slugs

    func testActionSluggedNewIsRejectedAsReserved() throws {
        // An action keyed `new` would be silently unreachable — the engine ignores `new` as a
        // backlog marker — so validation must reject the key with the specific reserved defect.
        let json = """
        {
          "version": 1,
          "start": "new",
          "actions": {
            "new": { "name": "New", "instructions": "Unreachable." }
          }
        }
        """
        let definition = try decode(json)
        XCTAssertThrowsError(try definition.validate()) { error in
            XCTAssertEqual(error as? WorkflowDefinition.LoadError, .reservedActionSlug(slug: "new"))
        }
    }

    func testActionSluggedReadyToStartIsRejectedAsReserved() throws {
        // Same defect for the other backlog marker. `start` points elsewhere here to prove the
        // reserved-key check fires on the action key itself, not via the start pointer.
        let json = """
        {
          "version": 1,
          "start": "implement",
          "actions": {
            "implement": { "name": "Implement", "instructions": "Do it." },
            "ready_to_start": { "name": "Ready", "instructions": "Unreachable." }
          }
        }
        """
        let definition = try decode(json)
        XCTAssertThrowsError(try definition.validate()) { error in
            XCTAssertEqual(error as? WorkflowDefinition.LoadError, .reservedActionSlug(slug: "ready_to_start"))
        }
    }

    func testHasJSONWorkflowFalseWhenActionSluggedReserved() throws {
        // A file defining a reserved-slug action decodes fine but fails validation, so the gate
        // reads as "no JSON workflow" rather than enabling a loop with an unreachable action.
        let json = """
        {
          "version": 1,
          "start": "new",
          "actions": {
            "new": { "name": "New", "instructions": "Unreachable." }
          }
        }
        """
        let projectPath = try writeWorkflow(json)
        XCTAssertFalse(WorkflowDefinition.hasJSONWorkflow(projectPath: projectPath))
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

    // MARK: - Action progress derivation

    func testActionProgressLinearFlowCurrentInMiddle() throws {
        let definition = try decode(Self.validGraphJSON)

        XCTAssertEqual(definition.actionProgress(currentStatus: "test"), [
            .init(slug: "implement", state: .completed),
            .init(slug: "test", state: .current),
            .init(slug: "review", state: .next),
        ])
    }

    func testActionProgressCurrentAtStart() throws {
        let definition = try decode(Self.validGraphJSON)

        XCTAssertEqual(definition.actionProgress(currentStatus: "implement"), [
            .init(slug: "implement", state: .current),
            .init(slug: "test", state: .next),
            .init(slug: "review", state: .upcoming),
        ])
    }

    func testActionProgressCurrentAtTerminalHasNoNext() throws {
        let definition = try decode(Self.validGraphJSON)

        XCTAssertEqual(definition.actionProgress(currentStatus: "review"), [
            .init(slug: "implement", state: .completed),
            .init(slug: "test", state: .completed),
            .init(slug: "review", state: .current),
        ])
    }

    func testActionProgressCompletedTerminalReadsAllDone() throws {
        // A finished loop: status sits on the terminal `review` and `completed: true`. The terminal
        // action reads `completed` instead of `current`, so the whole flow shows done.
        let definition = try decode(Self.validGraphJSON)

        XCTAssertEqual(definition.actionProgress(currentStatus: "review", completed: true), [
            .init(slug: "implement", state: .completed),
            .init(slug: "test", state: .completed),
            .init(slug: "review", state: .completed),
        ])
    }

    func testActionProgressCompletedOnNonTerminalStaysCurrent() throws {
        // A stray `completed: true` on a non-terminal action is not honored by the engine, so the
        // view doesn't honor it either — the action stays `current`.
        let definition = try decode(Self.validGraphJSON)

        XCTAssertEqual(definition.actionProgress(currentStatus: "test", completed: true), [
            .init(slug: "implement", state: .completed),
            .init(slug: "test", state: .current),
            .init(slug: "review", state: .next),
        ])
    }

    func testActionProgressUnknownStatusMarksAllUpcoming() throws {
        // A halted/unknown status resolves to no action: nothing is current or completed, so every
        // slug falls through to upcoming and the view can defer to the error surface.
        let definition = try decode(Self.validGraphJSON)

        XCTAssertEqual(definition.actionProgress(currentStatus: "halted-gibberish"), [
            .init(slug: "implement", state: .upcoming),
            .init(slug: "test", state: .upcoming),
            .init(slug: "review", state: .upcoming),
        ])
    }

    // MARK: - Planning object

    func testPlanningDecodesAndCoexistsWithActions() throws {
        let json = """
        {
          "version": 1,
          "start": "implement",
          "planning": { "instructions": "Plan the task described in TASK.md." },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Do it." }
          }
        }
        """
        let definition = try decode(json)
        XCTAssertEqual(definition.planning?.instructions, "Plan the task described in TASK.md.")
        XCTAssertEqual(definition.actions.count, 1, "planning does not disturb actions")
        XCTAssertEqual(try roundTrip(definition), definition, "planning round-trips alongside actions")
    }

    func testPlanningOmittedFromEncodeWhenNil() throws {
        let def = try decode(Self.validGraphJSON)
        XCTAssertNil(def.planning)
        let json = try XCTUnwrap(String(bytes: def.encoded(), encoding: .utf8))
        XCTAssertFalse(json.contains("planning"), "nil planning is omitted from the encoded file")
    }

    func testPlanningOnlyFileDecodesWithDefaults() throws {
        // A minimal hand-authored planning-only file must decode: version/start/actions default
        // to 1/""/[:] when absent.
        let definition = try decode("""
        { "planning": { "instructions": "Plan it." } }
        """)
        XCTAssertEqual(definition.version, 1)
        XCTAssertEqual(definition.start, "")
        XCTAssertTrue(definition.actions.isEmpty)
        XCTAssertEqual(definition.planning?.instructions, "Plan it.")
    }

    func testPlanningOnlyFileStillFailsValidation() throws {
        // Decode tolerates a planning-only file, but validate() still throws noActions so the
        // autopilot/JSON-workflow gate stays off (AC #7).
        let definition = try decode("""
        { "planning": { "instructions": "Plan it." } }
        """)
        XCTAssertThrowsError(try definition.validate()) { error in
            XCTAssertEqual(error as? WorkflowDefinition.LoadError, .noActions)
        }
    }

    func testPlanningRoundTripsViaModelInitializer() throws {
        let def = WorkflowDefinition(
            version: 1,
            start: "implement",
            planning: .init(instructions: "Plan it."),
            actions: ["implement": .init(name: "Implement", instructions: "Do it.")]
        )
        let back = try roundTrip(def)
        XCTAssertEqual(back, def)
        XCTAssertEqual(back.planning?.instructions, "Plan it.")
        XCTAssertEqual(back.actions["implement"]?.name, "Implement")
    }

    // MARK: - Raw (non-validating) load

    func testLoadRawDecodesPlanningOnlyFileWithoutValidation() throws {
        // A planning-only file (zero actions) fails load()/validate() with noActions, but loadRaw
        // decodes it so the planning instructions and top-level agent stay reachable.
        let projectPath = try writeWorkflow("""
        { "planning": { "instructions": "Plan it." }, "agent": { "command": "codex" } }
        """)
        XCTAssertFalse(WorkflowDefinition.hasJSONWorkflow(projectPath: projectPath),
                       "a planning-only file does not enable the JSON-workflow gate")
        let raw = try WorkflowDefinition.loadRaw(projectPath: projectPath)
        XCTAssertEqual(raw.planning?.instructions, "Plan it.")
        XCTAssertEqual(raw.agent.command, "codex")
        XCTAssertTrue(raw.actions.isEmpty)
    }

    func testLoadRawThrowsFileNotFoundWhenAbsent() {
        XCTAssertThrowsError(try WorkflowDefinition.loadRaw(projectPath: tempRoot)) { error in
            guard case .fileNotFound = error as? WorkflowDefinition.LoadError else {
                return XCTFail("expected .fileNotFound, got \(error)")
            }
        }
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

    // MARK: - Encode round-trip

    private func roundTrip(_ def: WorkflowDefinition) throws -> WorkflowDefinition {
        try JSONDecoder().decode(WorkflowDefinition.self, from: def.encoded())
    }

    func testEncodeRoundTripSingleTerminalAction() throws {
        let def = WorkflowDefinition(version: 1, start: "only", actions: [
            "only": .init(name: "Only", instructions: "One and done.")
        ])
        XCTAssertEqual(try roundTrip(def), def)
    }

    func testEncodeRoundTripTwoActionChain() throws {
        let def = WorkflowDefinition(version: 1, start: "implement", actions: [
            "implement": .init(name: "Implement", instructions: "Do it.", routes: ["success": "test"]),
            "test": .init(name: "Test", instructions: "Run tests.")
        ])
        XCTAssertEqual(try roundTrip(def), def)
    }

    func testEncodeRoundTripThreeActionChain() throws {
        let def = try decode(Self.validGraphJSON)
        XCTAssertEqual(try roundTrip(def), def)
    }

    func testEncodeRoundTripPreservesAgentAndHooks() throws {
        let def = WorkflowDefinition(
            version: 1,
            start: "only",
            agent: .init(command: "codex", timeoutMs: 1234),
            hooks: .init(afterCreate: "echo created", beforeRun: "echo running"),
            actions: ["only": .init(name: "Only", instructions: "Go.")]
        )
        let back = try roundTrip(def)
        XCTAssertEqual(back, def)
        XCTAssertEqual(back.agent.command, "codex")
        XCTAssertEqual(back.agent.timeoutMs, 1234)
        XCTAssertEqual(back.hooks?.afterCreate, "echo created")
        XCTAssertEqual(back.hooks?.beforeRun, "echo running")
    }

    func testEncodeEmitsSnakeCaseKeys() throws {
        let def = WorkflowDefinition(
            version: 1,
            start: "test",
            agent: .init(command: "claude", timeoutMs: 1234),
            hooks: .init(afterCreate: "echo created", beforeRun: "echo running"),
            actions: [
                "test": .init(
                    name: "Test", instructions: "Run tests.",
                    routes: ["success": "fix"], maxAttempts: 3, onMaxAttempts: "fix"
                ),
                "fix": .init(name: "Fix", instructions: "Patch it.", routes: ["success": "test"])
            ]
        )
        let json = try XCTUnwrap(String(bytes: def.encoded(), encoding: .utf8))
        XCTAssertTrue(json.contains("timeout_ms"), "agent timeout uses snake_case")
        XCTAssertTrue(json.contains("after_create"), "hooks use snake_case")
        XCTAssertTrue(json.contains("before_run"), "hooks use snake_case")
        XCTAssertTrue(json.contains("max_attempts"), "loop-guard keys use snake_case")
        XCTAssertTrue(json.contains("on_max_attempts"), "loop-guard keys use snake_case")
    }

    func testEncodeOmitsRoutesKeyForTerminalAction() throws {
        let def = WorkflowDefinition(version: 1, start: "only", actions: [
            "only": .init(name: "Only", instructions: "One and done.")
        ])
        let json = try XCTUnwrap(String(bytes: def.encoded(), encoding: .utf8))
        XCTAssertFalse(json.contains("routes"), "terminal action omits the routes key")

        let back = try roundTrip(def)
        XCTAssertTrue(back.isTerminal("only"))
    }

    func testEncodeOmitsAgentWhenDefault() throws {
        let def = WorkflowDefinition(version: 1, start: "only", actions: [
            "only": .init(name: "Only", instructions: "Go.")
        ])
        let json = try XCTUnwrap(String(bytes: def.encoded(), encoding: .utf8))
        XCTAssertFalse(json.contains("\"agent\""), "default agent is omitted from the encoded file")
        XCTAssertEqual(try roundTrip(def), def)
    }
}
