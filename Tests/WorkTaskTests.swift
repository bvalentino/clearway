import XCTest
@testable import Clearway

/// Model-level tests for `WorkTask` serialization/parsing — independent of `WorkTaskManager`.
final class WorkTaskTests: XCTestCase {

    /// The task `id` must round-trip through serialize → parse so identity survives the rename
    /// from `<UUID>.md` (central) to `TASK.md` (worktree), where the filename no longer carries it.
    func testIdRoundTripsThroughFrontmatter() throws {
        let original = WorkTask(id: UUID(), title: "Carry me", worktree: "feature/x", body: "Body")

        let serialized = original.serialized()
        XCTAssertTrue(serialized.contains("id: \(original.id.uuidString)"), "frontmatter must emit the id")

        // Parse with a DIFFERENT caller-supplied id to prove the frontmatter id wins.
        let reparsed = WorkTask.parse(from: serialized, id: UUID(), createdAt: Date())
        XCTAssertEqual(reparsed?.id, original.id, "frontmatter id must take precedence over the caller-supplied id")
    }

    /// A backlog task (no worktree) serializes without a `worktree:` line — so it isn't cluttered
    /// with `worktree: null` — and still round-trips to a nil worktree.
    func testBacklogTaskOmitsWorktreeLine() throws {
        let backlog = WorkTask(id: UUID(), title: "Backlog", worktree: nil)

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
        worktree: null
        ---

        body
        """
        let filenameId = UUID()
        let reparsed = WorkTask.parse(from: legacy, id: filenameId, createdAt: Date())
        XCTAssertEqual(reparsed?.id, filenameId, "with no frontmatter id, the filename UUID identifies the task")
        XCTAssertEqual(reparsed?.title, "Legacy")
    }

    /// Nothing Clearway writes carries a `status:` or `attempt:` line: not a new backlog task, not
    /// a hidden shadow task linked to its worktree, not a task linked by Create.
    func testSerializedTasksCarryNoStatusOrAttemptLine() throws {
        var shadow = WorkTask(title: "", worktree: "feature/shadow")
        shadow.hidden = true
        let tasks = [
            WorkTask(title: "Backlog"),
            shadow,
            WorkTask(title: "Linked", worktree: "feature/linked", body: "Body"),
        ]

        for task in tasks {
            let serialized = task.serialized()
            XCTAssertFalse(serialized.contains("status:"), "no status line in:\n\(serialized)")
            XCTAssertFalse(serialized.contains("attempt:"), "no attempt line in:\n\(serialized)")
        }
    }

    /// `title` is the only required field: a file carrying nothing else parses.
    func testFileWithOnlyTitleParses() throws {
        let parsed = WorkTask.parse(from: "---\ntitle: \"Bare\"\n---", id: UUID(), createdAt: Date())
        XCTAssertEqual(parsed?.title, "Bare")
    }

    /// A file with no `title` is rejected, whatever else it carries.
    func testFileWithoutTitleIsRejected() throws {
        let untitled = """
        ---
        id: \(UUID().uuidString)
        worktree: "feature/x"
        ---
        """
        XCTAssertNil(WorkTask.parse(from: untitled, id: UUID(), createdAt: Date()))
    }

    /// An old `status:` line, whatever its value, and an old `attempt:` line are ignored like any
    /// unknown key: the file parses to exactly the task the same file without that line gives.
    func testOldStatusAndAttemptLinesParseLikeTheBareFile() throws {
        let id = UUID()
        let createdAt = Date()
        func file(_ extraLine: String?) -> String {
            let extra = extraLine.map { "\($0)\n" } ?? ""
            return "---\nid: \(id.uuidString)\ntitle: \"Old\"\n\(extra)worktree: \"feature/old\"\n---\n\nBody text"
        }
        let bare = try XCTUnwrap(WorkTask.parse(from: file(nil), id: id, createdAt: createdAt))

        let oldLines = [
            "status: new", "status: in_progress", "status: canceled", "status: open",
            "status: started", "status: stopped", "status: ready_to_start", "status: review",
            "attempt: 3",
        ]
        for line in oldLines {
            XCTAssertEqual(WorkTask.parse(from: file(line), id: id, createdAt: createdAt), bare, "\(line) must be ignored")
        }
    }

    /// The retired `autopilot` / `completed` / `error_message` / `attempt` / `status` fields are no
    /// longer part of the model: a `TASK.md` still carrying them parses, and re-serializing drops
    /// all five while preserving every other field.
    func testRetiredFieldsAreDroppedOnReserialize() throws {
        let id = UUID()
        let legacy = """
        ---
        id: \(id.uuidString)
        title: "Carried over"
        status: review
        worktree: "feature/legacy"
        attempt: 2
        error_message: "agent halted"
        hidden: true
        autopilot: true
        completed: false
        ---

        Body text
        """

        guard let parsed = WorkTask.parse(from: legacy, id: UUID(), createdAt: Date()) else {
            XCTFail("a file carrying the retired fields must still parse"); return
        }
        XCTAssertEqual(parsed.id, id)
        XCTAssertEqual(parsed.title, "Carried over")
        XCTAssertEqual(parsed.worktree, "feature/legacy")
        XCTAssertTrue(parsed.hidden)
        XCTAssertEqual(parsed.body, "Body text")

        let reserialized = parsed.serialized()
        XCTAssertFalse(reserialized.contains("autopilot"), "autopilot must not be re-emitted")
        XCTAssertFalse(reserialized.contains("completed"), "completed must not be re-emitted")
        XCTAssertFalse(reserialized.contains("error_message"), "error_message must not be re-emitted")
        XCTAssertFalse(reserialized.contains("attempt"), "attempt must not be re-emitted")
        XCTAssertTrue(reserialized.contains("hidden: true"))
        XCTAssertFalse(reserialized.contains("status"), "status must not be re-emitted")
        XCTAssertTrue(reserialized.contains("worktree: \"feature/legacy\""))
    }

    /// A malformed frontmatter `id` must not crash parsing — it falls back to the filename UUID.
    func testInvalidFrontmatterIdFallsBackToFilenameUUID() throws {
        let malformed = """
        ---
        id: not-a-uuid
        title: "Bad id"
        worktree: null
        ---
        """
        let filenameId = UUID()
        let reparsed = WorkTask.parse(from: malformed, id: filenameId, createdAt: Date())
        XCTAssertEqual(reparsed?.id, filenameId)
    }
}
