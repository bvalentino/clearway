import XCTest
@testable import Clearway

/// Model-level tests for `WorkTask` serialization/parsing — independent of `WorkTaskManager`.
final class WorkTaskTests: XCTestCase {

    /// The task `id` must round-trip through serialize → parse so identity survives the rename
    /// from `<UUID>.md` (central) to `TASK.md` (worktree), where the filename no longer carries it.
    func testIdRoundTripsThroughFrontmatter() throws {
        let original = WorkTask(id: UUID(), title: "Carry me", status: .inProgress, worktree: "feature/x", body: "Body")

        let serialized = original.serialized()
        XCTAssertTrue(serialized.contains("id: \(original.id.uuidString)"), "frontmatter must emit the id")

        // Parse with a DIFFERENT caller-supplied id to prove the frontmatter id wins.
        let reparsed = WorkTask.parse(from: serialized, id: UUID(), createdAt: Date())
        XCTAssertEqual(reparsed?.id, original.id, "frontmatter id must take precedence over the caller-supplied id")
    }

    /// A backlog task (no worktree) serializes without a `worktree:` line — Planning tasks aren't
    /// cluttered with `worktree: null` — and still round-trips to a nil worktree.
    func testBacklogTaskOmitsWorktreeLine() throws {
        let backlog = WorkTask(id: UUID(), title: "Backlog", status: .new, worktree: nil)

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
