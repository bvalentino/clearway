import XCTest
@testable import Clearway

/// Pins what the create sheet does once `createWorktree` returns, and which of its two variants
/// carries the "Run agent command after create" slot. Nothing in a SwiftUI body is reachable from
/// XCTest, which is why both rules are pure statics on `CreateWorktreeSheet`.
@MainActor
final class CreateWorktreeOutcomeTests: XCTestCase {

    /// The regression: a fetch that failed non-fatally leaves `error` set over a creation that
    /// succeeded, and the sheet used to drop the typed name and status because of it.
    func testAReturnedWorktreeIsAppliedEvenWhenTheManagerCarriesAnError() {
        let created = makeWorktree(branch: "feature-x", path: "/tmp/feature-x")

        let outcome = CreateWorktreeSheet.outcome(
            created: created,
            error: "Fetch failed: no route to host. Proceeding with local state."
        )

        XCTAssertEqual(outcome, .apply(created))
    }

    func testAReturnedWorktreeIsAppliedWhenThereIsNoError() {
        let created = makeWorktree(branch: "feature-x", path: "/tmp/feature-x")

        XCTAssertEqual(CreateWorktreeSheet.outcome(created: created, error: nil), .apply(created))
    }

    func testNoWorktreeWithAnErrorLeavesTheSheetOpen() {
        XCTAssertEqual(
            CreateWorktreeSheet.outcome(created: nil, error: "Invalid branch name"),
            .reportedFailure
        )
    }

    /// `createWorktree` also returns nil when the worktree was added but the follow-up lookup did
    /// not find it. Nothing is published to explain that, so the sheet logs rather than dismissing
    /// onto a worktree that carries no name, status or group.
    func testNoWorktreeAndNoErrorIsASilentFailure() {
        XCTAssertEqual(CreateWorktreeSheet.outcome(created: nil, error: nil), .silentFailure)
    }

    // MARK: - Run agent command after create

    private func makeAgentCommand() -> SavedCommand {
        SavedCommand(id: UUID(), name: "Plan", kind: .agent, text: "brief", agent: "claude", autoRun: true)
    }

    /// The regression: the New Worktree sheet showed the picker and wrote its pick back, so a
    /// hand-made worktree both ran an agent command with no task to act on and cleared the default
    /// Start Now seeds its picker from.
    func testTheNewWorktreeVariantOffersNoFieldAndRunsNothing() {
        let agent = makeAgentCommand()

        let slot = CreateWorktreeSheet.afterCreateSlot(
            taskId: nil, pickedId: agent.id, commands: [agent]
        )

        XCTAssertEqual(slot, .hidden)
    }

    func testTheStartTaskVariantResolvesThePickedAgentCommand() {
        let agent = makeAgentCommand()

        let slot = CreateWorktreeSheet.afterCreateSlot(
            taskId: UUID(), pickedId: agent.id, commands: [agent]
        )

        XCTAssertEqual(slot, .offered(agent))
    }

    /// None is a real pick on this variant, so it both runs nothing and is written back.
    func testTheStartTaskVariantTreatsNoPickAsAFieldThatResolvesToNothing() {
        let slot = CreateWorktreeSheet.afterCreateSlot(
            taskId: UUID(), pickedId: nil, commands: [makeAgentCommand()]
        )

        XCTAssertEqual(slot, .offered(nil))
    }

    // MARK: - Start Task prefill

    func testPrefillCarriesTheGivenNameAndBranch() {
        let draft = CreateWorktreeSheet.prefill(name: "Ship It Now", branch: "ship-it-now-a1b2c3d4")

        XCTAssertEqual(draft.name, "Ship It Now")
        XCTAssertEqual(draft.branch, "ship-it-now-a1b2c3d4")
    }

    /// The prefilled branch may have been resolved away from a collision, so a later Name keystroke
    /// must not regenerate over it — which is why the branch goes through `setBranch`.
    func testPrefilledBranchSurvivesALaterNameEdit() {
        var draft = CreateWorktreeSheet.prefill(name: "Ship It Now", branch: "ship-it-now-a1b2c3d4")

        draft.setName("Renamed")

        XCTAssertEqual(draft.branch, "ship-it-now-a1b2c3d4")
        XCTAssertEqual(draft.name, "Renamed")
    }
}
