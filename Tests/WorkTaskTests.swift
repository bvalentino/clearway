import XCTest
@testable import Clearway

/// Model-level tests for `WorkTask` serialization/parsing — independent of `WorkTaskManager`.
final class WorkTaskTests: XCTestCase {

    /// The task `id` must round-trip through serialize → parse so identity survives the rename
    /// from `<UUID>.md` (central) to `TASK.md` (worktree), where the filename no longer carries it.
    func testIdRoundTripsThroughFrontmatter() throws {
        let original = WorkTask(id: UUID(), title: "Carry me", status: WorkTask.ReservedStatus.inProgress, worktree: "feature/x", body: "Body")

        let serialized = original.serialized()
        XCTAssertTrue(serialized.contains("id: \(original.id.uuidString)"), "frontmatter must emit the id")

        // Parse with a DIFFERENT caller-supplied id to prove the frontmatter id wins.
        let reparsed = WorkTask.parse(from: serialized, id: UUID(), createdAt: Date())
        XCTAssertEqual(reparsed?.id, original.id, "frontmatter id must take precedence over the caller-supplied id")
    }

    /// A backlog task (no worktree) serializes without a `worktree:` line — Planning tasks aren't
    /// cluttered with `worktree: null` — and still round-trips to a nil worktree.
    func testBacklogTaskOmitsWorktreeLine() throws {
        let backlog = WorkTask(id: UUID(), title: "Backlog", status: WorkTask.ReservedStatus.new, worktree: nil)

        let serialized = backlog.serialized()
        XCTAssertFalse(serialized.contains("worktree:"), "a backlog task must not emit a worktree line")

        let reparsed = WorkTask.parse(from: serialized, id: backlog.id, createdAt: Date())
        XCTAssertNil(reparsed?.worktree, "an absent worktree line must round-trip to nil")
    }

    /// A legacy central file with no `id:` line must fall back to the caller-supplied filename UUID.
    func testLegacyFileWithoutIdFallsBackToFilenameUUID() throws {
        let legacy = """
        ---
        title: "Legacy"
        status: new
        worktree: null
        ---

        body
        """
        let filenameId = UUID()
        let reparsed = WorkTask.parse(from: legacy, id: filenameId, createdAt: Date())
        XCTAssertEqual(reparsed?.id, filenameId, "with no frontmatter id, the filename UUID identifies the task")
        XCTAssertEqual(reparsed?.title, "Legacy")
    }

    /// An arbitrary action slug (not a reserved/legacy constant) must serialize and parse back
    /// verbatim — this is what lets a `WORKFLOW.json` engine sit `status` on any action.
    func testArbitrarySlugRoundTrips() throws {
        let task = WorkTask(id: UUID(), title: "Loop step", status: "review", worktree: "feature/loop")

        let serialized = task.serialized()
        XCTAssertTrue(serialized.contains("status: review"), "an arbitrary slug must serialize verbatim")

        let reparsed = WorkTask.parse(from: serialized, id: task.id, createdAt: Date())
        XCTAssertEqual(reparsed?.status, "review", "an arbitrary slug must parse back verbatim")
    }

    /// Legacy status values still migrate on parse: `open` → `new`, `started` → `in_progress`,
    /// `stopped` → `canceled`. Reserved/arbitrary slugs pass through unchanged.
    func testLegacyStatusValuesMigrate() throws {
        XCTAssertEqual(WorkTask.migrateStatus("open"), WorkTask.ReservedStatus.new)
        XCTAssertEqual(WorkTask.migrateStatus("started"), WorkTask.ReservedStatus.inProgress)
        XCTAssertEqual(WorkTask.migrateStatus("in_progress"), WorkTask.ReservedStatus.inProgress)
        XCTAssertEqual(WorkTask.migrateStatus("stopped"), WorkTask.ReservedStatus.canceled)
        XCTAssertEqual(WorkTask.migrateStatus("review"), "review", "arbitrary slugs pass through unchanged")
    }

    /// Display labels: known reserved/legacy slugs keep their human labels; an arbitrary slug
    /// is humanized; a value with no word characters falls back to the raw slug.
    func testDisplayLabels() throws {
        XCTAssertEqual(WorkTask.displayLabel(for: WorkTask.ReservedStatus.new), "New")
        XCTAssertEqual(WorkTask.displayLabel(for: WorkTask.ReservedStatus.readyToStart), "Ready to Start")
        XCTAssertEqual(WorkTask.displayLabel(for: WorkTask.ReservedStatus.inProgress), "In Progress")
        XCTAssertEqual(WorkTask.displayLabel(for: WorkTask.ReservedStatus.qa), "QA")
        XCTAssertEqual(WorkTask.displayLabel(for: WorkTask.ReservedStatus.readyForReview), "Ready for Review")
        XCTAssertEqual(WorkTask.displayLabel(for: WorkTask.ReservedStatus.done), "Done")
        XCTAssertEqual(WorkTask.displayLabel(for: WorkTask.ReservedStatus.canceled), "Canceled")
        XCTAssertEqual(WorkTask.displayLabel(for: "review"), "Review")
        XCTAssertEqual(WorkTask.displayLabel(for: "run_tests"), "Run Tests")
        XCTAssertEqual(WorkTask.displayLabel(for: "run-tests"), "Run Tests")
        XCTAssertEqual(WorkTask.displayLabel(for: "_"), "_", "a slug with no words falls back to the raw value")
    }

    /// A malformed frontmatter `id` must not crash parsing — it falls back to the filename UUID.
    func testInvalidFrontmatterIdFallsBackToFilenameUUID() throws {
        let malformed = """
        ---
        id: not-a-uuid
        title: "Bad id"
        status: new
        worktree: null
        ---
        """
        let filenameId = UUID()
        let reparsed = WorkTask.parse(from: malformed, id: filenameId, createdAt: Date())
        XCTAssertEqual(reparsed?.id, filenameId)
    }
}
