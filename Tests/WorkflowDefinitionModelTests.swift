import XCTest
@testable import Clearway

/// The optional per-entry `model` in `.clearway/WORKFLOW.json`: that it decodes on both entry kinds,
/// that an absent one emits no key (so a models-free file stays minimal), and that no model value is
/// ever a validation error — a malformed one is dropped at launch instead, because failing
/// `validate()` would make the whole file read as "no JSON workflow" and disable autopilot.
final class WorkflowDefinitionModelTests: XCTestCase {

    private func decode(_ json: String) throws -> WorkflowDefinition {
        try JSONDecoder().decode(WorkflowDefinition.self, from: Data(json.utf8))
    }

    private func roundTrip(_ def: WorkflowDefinition) throws -> WorkflowDefinition {
        try JSONDecoder().decode(WorkflowDefinition.self, from: def.encoded())
    }

    // MARK: - Per-entry model

    func testModelDecodesOnPlanningAndAction() throws {
        let json = """
        {
          "version": 1,
          "start": "implement",
          "planning": { "instructions": "Plan it.", "model": "fable" },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Do it.", "model": "opus" }
          }
        }
        """
        let definition = try decode(json)
        XCTAssertEqual(definition.planning?.model, "fable")
        XCTAssertEqual(definition.actions["implement"]?.model, "opus")
        XCTAssertEqual(try roundTrip(definition), definition)
    }

    /// The planning entry must be *present* and model-free for this to say anything: against a file
    /// with no `planning` at all, `definition.planning?.model` is nil for the wrong reason.
    func testModelAbsentDecodesAsNilOnBothEntryKinds() throws {
        let definition = try decode("""
        {
          "version": 1,
          "start": "implement",
          "planning": { "instructions": "Plan." },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Implement." }
          }
        }
        """)
        XCTAssertNotNil(definition.planning)
        XCTAssertNil(definition.actions["implement"]?.model)
        XCTAssertNil(definition.planning?.model)
    }

    func testEncodeOmitsModelKeyWhenAbsent() throws {
        let definition = try decode("""
        {
          "version": 1,
          "start": "implement",
          "planning": { "instructions": "Plan it." },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Do it." }
          }
        }
        """)
        let json = try XCTUnwrap(String(bytes: definition.encoded(), encoding: .utf8))
        XCTAssertFalse(json.contains("model"), "an absent model emits no key")
    }

    func testValidateAcceptsMalformedModel() throws {
        // A bad model value is dropped at launch, never a validation failure — failing here would
        // make the whole file read as "no JSON workflow" and silently disable autopilot.
        let definition = try decode("""
        {
          "version": 1,
          "start": "implement",
          "planning": { "instructions": "Plan it.", "model": "sonnet; curl x" },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Do it.", "model": "sonnet; curl x" }
          }
        }
        """)
        XCTAssertNoThrow(try definition.validate())
    }

    // MARK: - Per-entry agent command

    func testCommandDecodesOnPlanningAndAction() throws {
        let json = """
        {
          "version": 1,
          "start": "implement",
          "planning": { "instructions": "Plan it.", "command": "codex" },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Do it.", "command": "claude" }
          }
        }
        """
        let definition = try decode(json)
        XCTAssertEqual(definition.planning?.command, "codex")
        XCTAssertEqual(definition.actions["implement"]?.command, "claude")
        XCTAssertEqual(try roundTrip(definition), definition)
    }

    func testCommandAbsentDecodesAsNilOnBothEntryKinds() throws {
        let definition = try decode("""
        {
          "version": 1,
          "start": "implement",
          "planning": { "instructions": "Plan." },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Implement." }
          }
        }
        """)
        XCTAssertNotNil(definition.planning)
        XCTAssertNil(definition.actions["implement"]?.command)
        XCTAssertNil(definition.planning?.command)
    }

    func testEncodeOmitsCommandKeyWhenAbsent() throws {
        let definition = try decode("""
        {
          "version": 1,
          "start": "implement",
          "planning": { "instructions": "Plan it." },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Do it." }
          }
        }
        """)
        let json = try XCTUnwrap(String(bytes: definition.encoded(), encoding: .utf8))
        XCTAssertFalse(json.contains("command"), "an absent command emits no key")
        XCTAssertFalse(json.contains("agent"), "a default agent object stays omitted")
    }

    /// An off-allowlist value is ignored at launch, never a validation failure — rejecting the file
    /// would make it read as "no JSON workflow" and disable autopilot over a typo.
    func testValidateAcceptsOffAllowlistCommand() throws {
        let definition = try decode("""
        {
          "version": 1,
          "start": "implement",
          "agent": { "command": "claude --dangerously-skip-permissions" },
          "planning": { "instructions": "Plan it.", "command": "aider" },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Do it.", "command": "npx claude" }
          }
        }
        """)
        XCTAssertNoThrow(try definition.validate())
    }

    /// `timeout_ms` is reserved and unenforced in v1, so naming an agent must not newly write a
    /// timeout the user never asked for.
    func testEncodeOmitsDefaultTimeoutWhenOnlyTheAgentCommandIsSet() throws {
        let definition = try decode("""
        {
          "version": 1,
          "start": "implement",
          "agent": { "command": "codex" },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Do it." }
          }
        }
        """)
        let json = try XCTUnwrap(String(bytes: definition.encoded(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"command\" : \"codex\""), "the agent command is written: \(json)")
        XCTAssertFalse(json.contains("timeout_ms"), "a default timeout emits no key: \(json)")
        XCTAssertEqual(try roundTrip(definition), definition)
    }

    func testEncodeKeepsANonDefaultTimeout() throws {
        let definition = try decode("""
        {
          "version": 1,
          "start": "implement",
          "agent": { "timeout_ms": 1234 },
          "actions": {
            "implement": { "name": "Implement", "instructions": "Do it." }
          }
        }
        """)
        let json = try XCTUnwrap(String(bytes: definition.encoded(), encoding: .utf8))
        XCTAssertTrue(json.contains("timeout_ms"), "a non-default timeout survives: \(json)")
        XCTAssertEqual(try roundTrip(definition), definition)
    }
}
