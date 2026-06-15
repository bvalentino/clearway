import XCTest
@testable import Clearway

/// Tests for the planning-prompt renderer. Planning instructions now live in `WORKFLOW.json`
/// (a `planning` object); the renderer interpolates the selected task's `{{ task.* }}` data and
/// — since planning is manual, pre-worktree, with no retry — does **not** support `{{ attempt }}`.
final class PlanningConfigTests: XCTestCase {

    func testRenderPlanningPromptInterpolatesTaskVariables() {
        let task = WorkTask(id: UUID(), title: "Add dark mode", body: "Make it dark.")
        let rendered = PlanningConfig.renderPlanningPrompt(
            instructions: "Plan {{ task.title }} (id {{ task.id }}): {{ task.body }}",
            task: task,
            taskPath: "/tmp/TASK.md"
        )
        XCTAssertEqual(rendered, "Plan Add dark mode (id \(task.id.uuidString)): Make it dark.")
    }

    func testRenderPlanningPromptInterpolatesTaskPath() {
        let task = WorkTask(id: UUID(), title: "T")
        let rendered = PlanningConfig.renderPlanningPrompt(
            instructions: "File at {{ task.path }}.",
            task: task,
            taskPath: "/tmp/TASK.md"
        )
        XCTAssertEqual(rendered, "File at /tmp/TASK.md.")
    }

    func testRenderPlanningPromptLeavesAttemptUninterpolated() {
        // `{{ attempt }}` is dropped — planning has no retry — so it reads as an unknown variable
        // and is left verbatim rather than substituted.
        let task = WorkTask(id: UUID(), title: "T")
        let rendered = PlanningConfig.renderPlanningPrompt(
            instructions: "Attempt {{ attempt }}.",
            task: task,
            taskPath: nil
        )
        XCTAssertEqual(rendered, "Attempt {{ attempt }}.")
    }

    func testRenderPlanningPromptEmptyInstructionsFallsBackToBody() {
        let task = WorkTask(id: UUID(), title: "T", body: "Just the body.")
        let rendered = PlanningConfig.renderPlanningPrompt(instructions: "", task: task, taskPath: nil)
        XCTAssertEqual(rendered, "Just the body.")
    }
}
