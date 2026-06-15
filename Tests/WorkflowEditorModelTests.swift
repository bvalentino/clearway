import XCTest
@testable import Clearway

/// Unit tests for `WorkflowEditorModel`: slug generation and linear-chain route relinking. Every
/// mutation's `toDefinition` output is asserted `validate()`-clean.
final class WorkflowEditorModelTests: XCTestCase {

    // MARK: - Helpers

    /// Asserts the model serializes to a `validate()`-clean definition; returns it for further checks.
    @discardableResult
    private func assertValid(
        _ model: WorkflowEditorModel,
        preserving base: WorkflowDefinition? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) -> WorkflowDefinition {
        let definition = model.toDefinition(preserving: base)
        XCTAssertNoThrow(try definition.validate(), "toDefinition output must validate", file: file, line: line)
        return definition
    }

    // MARK: - slugify

    func testSlugifyLowercasesAndCollapsesSeparators() {
        XCTAssertEqual(WorkflowEditorModel.slugify("Implement"), "implement")
        XCTAssertEqual(WorkflowEditorModel.slugify("Run Tests!"), "run_tests")
        XCTAssertEqual(WorkflowEditorModel.slugify("  Foo   Bar  "), "foo_bar")
        XCTAssertEqual(WorkflowEditorModel.slugify("review-the-diff"), "review_the_diff")
    }

    func testSlugifyDropsNonASCIIAndTrimsToEmptyForAllSymbols() {
        XCTAssertEqual(WorkflowEditorModel.slugify("café"), "caf")
        XCTAssertEqual(WorkflowEditorModel.slugify("!!!"), "")
        XCTAssertEqual(WorkflowEditorModel.slugify("   "), "")
    }

    // MARK: - makeSlug

    func testMakeSlugDedupsAgainstExisting() {
        XCTAssertEqual(WorkflowEditorModel.makeSlug(from: "Test", existing: ["test"]), "test_2")
        XCTAssertEqual(WorkflowEditorModel.makeSlug(from: "Test", existing: ["test", "test_2"]), "test_3")
    }

    func testMakeSlugAvoidsReservedBacklogMarkers() {
        XCTAssertEqual(WorkflowEditorModel.makeSlug(from: "New", existing: []), "new_2")
        XCTAssertEqual(WorkflowEditorModel.makeSlug(from: "Ready To Start", existing: []), "ready_to_start_2")
    }

    func testMakeSlugFallsBackForEmptyName() {
        XCTAssertEqual(WorkflowEditorModel.makeSlug(from: "", existing: []), "action")
        XCTAssertEqual(WorkflowEditorModel.makeSlug(from: "!!!", existing: []), "action")
        XCTAssertEqual(WorkflowEditorModel.makeSlug(from: "", existing: ["action"]), "action_2")
    }

    // MARK: - init(from:)

    func testInitFromDefinitionWalksFlowOrder() throws {
        let definition = WorkflowDefinition(version: 1, start: "implement", actions: [
            "implement": .init(name: "Implement", instructions: "Do it.", routes: ["success": "test"]),
            "test": .init(name: "Test", instructions: "Run tests.", routes: ["success": "review"]),
            "review": .init(name: "Review", instructions: "Review the diff.")
        ])
        let model = WorkflowEditorModel(from: definition)
        XCTAssertEqual(model.actions.map { $0.slug }, ["implement", "test", "review"])
        XCTAssertEqual(model.actions.map { $0.name }, ["Implement", "Test", "Review"])
        XCTAssertEqual(model.actions.first?.instructions, "Do it.")
    }

    // MARK: - toDefinition linear-chain wiring

    func testToDefinitionWiresLinearChainAndValidates() {
        var model = WorkflowEditorModel()
        model.add(name: "Implement")
        model.add(name: "Test")
        model.add(name: "Review")

        let definition = assertValid(model)
        let slugs = model.actions.map { $0.slug }
        XCTAssertEqual(definition.start, slugs[0])
        XCTAssertEqual(definition.actions[slugs[0]]?.routes, ["success": slugs[1]])
        XCTAssertEqual(definition.actions[slugs[1]]?.routes, ["success": slugs[2]])
        XCTAssertEqual(definition.actions[slugs[2]]?.routes, [:])
        XCTAssertTrue(definition.isTerminal(slugs[2]))
    }

    func testSingleActionIsTerminalAndValid() {
        var model = WorkflowEditorModel()
        let only = model.add(name: "Only")
        let definition = assertValid(model)
        XCTAssertEqual(definition.start, only.slug)
        XCTAssertTrue(definition.isTerminal(only.slug))
    }

    // MARK: - add

    func testAddAppendsAndRelinksFormerTerminal() {
        var model = WorkflowEditorModel()
        let first = model.add(name: "First")
        let second = model.add(name: "Second")
        let third = model.add(name: "Third")

        let definition = assertValid(model)
        XCTAssertEqual(definition.actions[first.slug]?.routes, ["success": second.slug])
        XCTAssertEqual(definition.actions[second.slug]?.routes, ["success": third.slug])
        XCTAssertTrue(definition.isTerminal(third.slug))
    }

    // MARK: - remove

    func testRemoveRelinksPredecessorToSuccessor() {
        var model = WorkflowEditorModel()
        let a = model.add(name: "A")
        model.add(name: "B")
        let c = model.add(name: "C")

        model.remove(at: 1)

        let definition = assertValid(model)
        XCTAssertEqual(definition.actions.count, 2)
        XCTAssertEqual(definition.actions[a.slug]?.routes, ["success": c.slug])
        XCTAssertTrue(definition.isTerminal(c.slug))
    }

    func testRemoveLastLeavesPredecessorTerminal() {
        var model = WorkflowEditorModel()
        let a = model.add(name: "A")
        model.add(name: "B")

        model.remove(at: 1)

        let definition = assertValid(model)
        XCTAssertEqual(definition.start, a.slug)
        XCTAssertTrue(definition.isTerminal(a.slug), "the predecessor becomes terminal")
    }

    // MARK: - move

    func testMoveRewritesStartAndRoutes() {
        var model = WorkflowEditorModel()
        let a = model.add(name: "A")
        let b = model.add(name: "B")
        let c = model.add(name: "C")

        model.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(model.actions.map { $0.slug }, [c.slug, a.slug, b.slug])

        let definition = assertValid(model)
        XCTAssertEqual(definition.start, c.slug, "start follows the new first card")
        XCTAssertEqual(definition.actions[c.slug]?.routes, ["success": a.slug])
        XCTAssertEqual(definition.actions[a.slug]?.routes, ["success": b.slug])
        XCTAssertTrue(definition.isTerminal(b.slug))
    }

    // MARK: - slug freezing

    func testRenameKeepsSlugFrozen() {
        var model = WorkflowEditorModel()
        let original = model.add(name: "Test")
        XCTAssertEqual(original.slug, "test")

        model.actions[0].name = "Completely Different Name"
        XCTAssertEqual(model.actions[0].slug, "test", "rename is cosmetic; slug is frozen")

        let definition = assertValid(model)
        XCTAssertEqual(definition.start, "test")
        XCTAssertEqual(definition.actions["test"]?.name, "Completely Different Name")
    }

    // MARK: - finalizeSlug (creation-commit)

    func testFinalizeSlugDerivesFromName() {
        var model = WorkflowEditorModel()
        let added = model.add()
        XCTAssertEqual(added.slug, "action")

        model.actions[0].name = "Sample"
        model.finalizeSlug(of: added.slug)
        XCTAssertEqual(model.actions[0].slug, "sample", "slug is re-derived from the name on commit")
    }

    func testFinalizeSlugDedupsAgainstOtherActions() {
        var model = WorkflowEditorModel()
        model.add(name: "Test")
        let new = model.add()
        model.actions[1].name = "Test"
        model.finalizeSlug(of: new.slug)
        XCTAssertEqual(model.actions[1].slug, "test_2", "finalized slug dedups against existing slugs")
    }

    func testFinalizeSlugRewiresRoutesAndValidates() {
        var model = WorkflowEditorModel()
        model.add(name: "Implement")
        let new = model.add()
        model.actions[1].name = "Review"
        model.finalizeSlug(of: new.slug)

        let definition = assertValid(model)
        XCTAssertEqual(definition.actions["implement"]?.routes, ["success": "review"])
        XCTAssertNil(definition.actions["action"], "the placeholder slug is gone")
        XCTAssertTrue(definition.isTerminal("review"))
    }

    func testSlugsSurviveRoundTripThroughDisk() throws {
        let definition = WorkflowDefinition(version: 1, start: "implement", actions: [
            "implement": .init(name: "Implement", instructions: "Do it.", routes: ["success": "test"]),
            "test": .init(name: "Test", instructions: "Run tests.")
        ])
        let model = WorkflowEditorModel(from: definition)
        let rebuilt = model.toDefinition(preserving: definition)
        XCTAssertEqual(rebuilt, definition, "a linear def round-trips through the editor unchanged")
    }

    // MARK: - preserve-on-write

    func testToDefinitionPreservesAgentHooksAndVersion() {
        let base = WorkflowDefinition(
            version: 1,
            start: "old",
            agent: .init(command: "codex", timeoutMs: 1234),
            hooks: .init(afterCreate: "echo created", beforeRun: "echo running"),
            actions: ["old": .init(name: "Old", instructions: "x")]
        )
        var model = WorkflowEditorModel()
        model.add(name: "Brand New")

        let definition = assertValid(model, preserving: base)
        XCTAssertEqual(definition.agent.command, "codex")
        XCTAssertEqual(definition.agent.timeoutMs, 1234)
        XCTAssertEqual(definition.hooks?.afterCreate, "echo created")
        XCTAssertEqual(definition.hooks?.beforeRun, "echo running")
        XCTAssertEqual(definition.version, 1)
        XCTAssertNil(definition.actions["old"])
        XCTAssertNotNil(definition.actions["brand_new"])
    }

    func testToDefinitionPreservesPerActionReservedFields() {
        let base = WorkflowDefinition(version: 1, start: "test", actions: [
            "test": .init(
                name: "Test", instructions: "Run tests.",
                routes: ["success": "fix"], maxAttempts: 3, onMaxAttempts: "fix"
            ),
            "fix": .init(name: "Fix", instructions: "Patch it.", routes: ["success": "test"])
        ])
        let model = WorkflowEditorModel(from: base)
        let definition = assertValid(model, preserving: base)
        XCTAssertEqual(definition.actions["test"]?.maxAttempts, 3, "max_attempts is carried forward")
        XCTAssertEqual(definition.actions["test"]?.onMaxAttempts, "fix", "on_max_attempts is carried forward")
    }

    func testToDefinitionDropsDanglingEscapePointerWhenTargetRemoved() {
        let base = WorkflowDefinition(version: 1, start: "test", actions: [
            "test": .init(
                name: "Test", instructions: "Run.",
                routes: ["success": "fix"], maxAttempts: 2, onMaxAttempts: "fix"
            ),
            "fix": .init(name: "Fix", instructions: "Patch.")
        ])
        var model = WorkflowEditorModel(from: base)
        model.remove(at: 1)

        let definition = assertValid(model, preserving: base)
        XCTAssertEqual(definition.actions["test"]?.maxAttempts, 2, "max_attempts still preserved")
        XCTAssertNil(definition.actions["test"]?.onMaxAttempts, "dangling escape pointer is dropped")
    }

    // MARK: - planning

    func testInitFromDefinitionReadsPlanningInstructions() {
        let base = WorkflowDefinition(
            version: 1,
            start: "implement",
            planning: .init(instructions: "Plan the task."),
            actions: ["implement": .init(name: "Implement", instructions: "Do it.")]
        )
        let model = WorkflowEditorModel(from: base)
        XCTAssertEqual(model.planning, "Plan the task.")
    }

    func testInitFromDefinitionWithoutPlanningLeavesPlanningNil() {
        let base = WorkflowDefinition(version: 1, start: "only", actions: [
            "only": .init(name: "Only", instructions: "Go.")
        ])
        XCTAssertNil(WorkflowEditorModel(from: base).planning)
    }

    func testToDefinitionCarriesPlanningAlongsideActions() {
        var model = WorkflowEditorModel()
        model.add(name: "Implement", instructions: "Do it.")
        model.planning = "Plan it."

        let definition = assertValid(model)
        XCTAssertEqual(definition.planning?.instructions, "Plan it.")
        XCTAssertNotNil(definition.actions["implement"], "planning does not disturb actions")
    }

    func testToDefinitionEmitsPlanningOnlyDefinitionWhenNoActions() throws {
        // Planning present, zero actions: toDefinition produces a planning-only definition that
        // round-trips (it can't validate — noActions — but it must encode/decode cleanly).
        var model = WorkflowEditorModel()
        model.planning = "Plan it."

        let definition = model.toDefinition(preserving: nil)
        XCTAssertTrue(definition.actions.isEmpty)
        XCTAssertEqual(definition.planning?.instructions, "Plan it.")

        let back = try JSONDecoder().decode(WorkflowDefinition.self, from: definition.encoded())
        XCTAssertEqual(back.planning?.instructions, "Plan it.")
        XCTAssertTrue(back.actions.isEmpty)
    }

    func testToDefinitionWithoutPlanningOmitsPlanning() {
        var model = WorkflowEditorModel()
        model.add(name: "Implement", instructions: "Do it.")
        XCTAssertNil(assertValid(model).planning)
    }

    func testRemovingAllActionsKeepsPlanningInDefinition() {
        let base = WorkflowDefinition(
            version: 1,
            start: "implement",
            planning: .init(instructions: "Plan it."),
            actions: ["implement": .init(name: "Implement", instructions: "Do it.")]
        )
        var model = WorkflowEditorModel(from: base)
        model.remove(at: 0)

        let definition = model.toDefinition(preserving: base)
        XCTAssertTrue(definition.actions.isEmpty, "all actions removed")
        XCTAssertEqual(definition.planning?.instructions, "Plan it.", "planning survives removing every action")
    }

    // MARK: - every-mutation-valid sweep

    func testEveryMutationStaysValid() {
        var model = WorkflowEditorModel()
        model.add(name: "One"); assertValid(model)
        model.add(name: "Two"); assertValid(model)
        model.add(name: "Three"); assertValid(model)
        model.move(from: IndexSet(integer: 0), to: 3); assertValid(model)
        model.remove(at: 1); assertValid(model)
        model.remove(at: 0); assertValid(model)
        XCTAssertEqual(model.actions.count, 1)
    }

    func testGeneratedSlugsNeverCollideAcrossManyEmptyNames() {
        var model = WorkflowEditorModel()
        for _ in 0..<5 { model.add(name: "") }
        let slugs = model.actions.map { $0.slug }
        XCTAssertEqual(Set(slugs).count, slugs.count, "every generated slug is unique")
        assertValid(model)
    }
}
