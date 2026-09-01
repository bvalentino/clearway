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

}
