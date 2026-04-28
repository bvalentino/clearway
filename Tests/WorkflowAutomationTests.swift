import XCTest
@testable import Clearway

final class WorkflowAutomationTests: XCTestCase {

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

    // MARK: - Codable

    /// On-disk schema must match the brief exactly: `{ "rules": { "<status>": [{ "command", "agent" }] } }`.
    /// `id` is a UI-only identity for SwiftUI list diffing — it must not leak into the JSON.
    func testEncodedJSONOmitsActionId() throws {
        var automation = WorkflowAutomation()
        automation.rules[.inProgress] = [
            WorkflowAutomation.Action(command: "say hi", agent: "claude")
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(automation)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("id"), "Action.id must not be persisted to JSON")
        XCTAssertTrue(json.contains("\"command\":\"say hi\""))
        XCTAssertTrue(json.contains("\"agent\":\"claude\""))
        XCTAssertTrue(json.contains("\"in_progress\""), "status keys must use raw value, not enum case name")
    }

    /// The status enum's raw value must appear in the JSON, not its Swift case name. This is the
    /// boundary between in-app code and the on-disk schema — a regression here would break every
    /// existing user's workflow.json.
    func testEncodedJSONUsesStatusRawValueKeys() throws {
        var automation = WorkflowAutomation()
        automation.rules[.readyForReview] = [
            WorkflowAutomation.Action(command: "test", agent: "claude")
        ]

        let data = try JSONEncoder().encode(automation)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"ready_for_review\""), "must serialize as raw value")
        XCTAssertFalse(json.contains("readyForReview"), "must not serialize as Swift case name")
    }

    /// Decode → encode → decode must yield identical rule contents (UUIDs are regenerated on
    /// decode, so they're compared per-field rather than via `==`).
    func testCodableRoundTripPreservesRulesContent() throws {
        let json = """
        {
          "rules": {
            "in_progress": [
              { "command": "first", "agent": "claude" },
              { "command": "second", "agent": "codex" }
            ],
            "qa": [
              { "command": "test it", "agent": "claude" }
            ]
          }
        }
        """

        let decoded = try JSONDecoder().decode(WorkflowAutomation.self, from: Data(json.utf8))
        let reencoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(WorkflowAutomation.self, from: reencoded)

        XCTAssertEqual(redecoded.rules.keys.sorted(by: { $0.rawValue < $1.rawValue }),
                       [WorkTask.Status.inProgress, .qa])

        let inProgress = redecoded.actions(for: .inProgress)
        XCTAssertEqual(inProgress.count, 2)
        XCTAssertEqual(inProgress[0].command, "first")
        XCTAssertEqual(inProgress[0].agent, "claude")
        XCTAssertEqual(inProgress[1].command, "second")
        XCTAssertEqual(inProgress[1].agent, "codex")

        let qa = redecoded.actions(for: .qa)
        XCTAssertEqual(qa.count, 1)
        XCTAssertEqual(qa[0].command, "test it")
        XCTAssertEqual(qa[0].agent, "claude")
    }

    /// Action ids are UI-only and not persisted; every decode must produce a fresh UUID so SwiftUI
    /// list diffing has stable per-instance identity without leaking it into the schema.
    func testActionIdRegeneratedOnEveryDecode() throws {
        let json = #"{ "rules": { "qa": [ { "command": "x", "agent": "claude" } ] } }"#

        let first = try JSONDecoder().decode(WorkflowAutomation.self, from: Data(json.utf8))
        let second = try JSONDecoder().decode(WorkflowAutomation.self, from: Data(json.utf8))

        let firstId = first.actions(for: .qa).first?.id
        let secondId = second.actions(for: .qa).first?.id

        XCTAssertNotNil(firstId)
        XCTAssertNotNil(secondId)
        XCTAssertNotEqual(firstId, secondId, "fresh decode must yield a fresh UI id")
    }

    /// Equality must compare content (`command`+`agent`) only, ignoring the
    /// UI-only `id`. Otherwise a save→watcher→reload round-trip — which
    /// regenerates ids on every decode — registers as a "different" automation
    /// in the editor's `onChange(of: workflowAutomation)` gate, replaces the
    /// `@State` model, and tears down every TextField (stealing focus while
    /// the user is mid-edit).
    func testActionEqualityIgnoresIdSoRoundTripPreservesEquality() throws {
        let json = #"{ "rules": { "qa": [ { "command": "x", "agent": "claude" } ] } }"#

        let first = try JSONDecoder().decode(WorkflowAutomation.self, from: Data(json.utf8))
        let second = try JSONDecoder().decode(WorkflowAutomation.self, from: Data(json.utf8))

        XCTAssertNotEqual(first.actions(for: .qa).first?.id,
                          second.actions(for: .qa).first?.id,
                          "precondition: ids differ across decodes")
        XCTAssertEqual(first, second,
                       "automations with the same content must compare equal regardless of action ids")
    }

    /// Forward-compat: a JSON file referencing a status key the current build doesn't recognize
    /// (e.g. a future "blocked" status) must be silently skipped, not fail the whole load.
    func testDecodeSkipsUnknownStatusKeysForForwardCompat() throws {
        let json = """
        {
          "rules": {
            "in_progress": [{ "command": "ok", "agent": "claude" }],
            "future_unknown_status": [{ "command": "ignore me", "agent": "claude" }]
          }
        }
        """

        let decoded = try JSONDecoder().decode(WorkflowAutomation.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.rules.count, 1, "unknown status keys must not survive decode")
        XCTAssertNotNil(decoded.rules[.inProgress])
    }

    // MARK: - load(projectPath:)

    /// A missing workflow.json must yield an empty automation — callers don't need to differentiate
    /// "absent" from "empty rules" (the brief explicitly equates them).
    func testLoadReturnsEmptyWhenFileMissing() {
        let result = WorkflowAutomation.load(projectPath: tempRoot)
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertFalse(result.hasAnyRule)
    }

    /// Corrupt JSON must not crash the app — fall back to an empty automation so the user can
    /// fix the file via the editor.
    func testLoadReturnsEmptyWhenJSONInvalid() throws {
        let dir = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("workflow.json")
        FileManager.default.createFile(atPath: path, contents: Data("{not json".utf8))

        let result = WorkflowAutomation.load(projectPath: tempRoot)
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertFalse(result.hasAnyRule)
    }

    /// Empty rules `{}` must be treated identically to a missing file (per the brief).
    func testLoadEmptyRulesEqualsEmptyAutomation() throws {
        let dir = (tempRoot as NSString).appendingPathComponent(".clearway")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("workflow.json")
        FileManager.default.createFile(atPath: path, contents: Data(#"{ "rules": {} }"#.utf8))

        let result = WorkflowAutomation.load(projectPath: tempRoot)
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertFalse(result.hasAnyRule)
    }

    // MARK: - save(to:)

    /// First save must create the `.clearway/` directory if it doesn't exist — no requirement
    /// that the user pre-create it.
    func testSaveCreatesClearwayDirectoryAndFile() throws {
        let clearwayDir = (tempRoot as NSString).appendingPathComponent(".clearway")
        let path = (clearwayDir as NSString).appendingPathComponent("workflow.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: clearwayDir))

        var automation = WorkflowAutomation()
        automation.rules[.qa] = [WorkflowAutomation.Action(command: "x", agent: "claude")]
        try automation.save(to: tempRoot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: clearwayDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// Save must round-trip cleanly: write → load → same rule content. The brief's primary success
    /// criterion is that the editor's edits land on disk and are read back identically.
    func testSaveLoadRoundTrip() throws {
        var original = WorkflowAutomation()
        original.rules[.inProgress] = [
            WorkflowAutomation.Action(command: "claude run", agent: "claude")
        ]
        original.rules[.qa] = [
            WorkflowAutomation.Action(command: "verify", agent: "codex"),
            WorkflowAutomation.Action(command: "lint", agent: "claude")
        ]

        try original.save(to: tempRoot)
        let reloaded = WorkflowAutomation.load(projectPath: tempRoot)

        XCTAssertEqual(reloaded.rules.keys.sorted(by: { $0.rawValue < $1.rawValue }),
                       original.rules.keys.sorted(by: { $0.rawValue < $1.rawValue }))

        let qa = reloaded.actions(for: .qa)
        XCTAssertEqual(qa.count, 2)
        XCTAssertEqual(qa.map { $0.command }, ["verify", "lint"])
        XCTAssertEqual(qa.map { $0.agent }, ["codex", "claude"])
    }

    /// File permissions must be 0o600 — the brief mirrors the WORKFLOW.md precedent because action
    /// commands can reference paths inside the user's environment that don't need to be world-readable.
    func testSaveSetsRestrictiveFilePermissions() throws {
        var automation = WorkflowAutomation()
        automation.rules[.qa] = [WorkflowAutomation.Action(command: "x", agent: "claude")]
        try automation.save(to: tempRoot)

        let path = (tempRoot as NSString)
            .appendingPathComponent(".clearway")
        let filePath = (path as NSString).appendingPathComponent("workflow.json")

        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600, "workflow.json must be user-only readable/writable")
    }

    /// Atomic rename — no `.tmp` file may remain after a successful save.
    func testSaveLeavesNoTempFileBehind() throws {
        var automation = WorkflowAutomation()
        automation.rules[.qa] = [WorkflowAutomation.Action(command: "x", agent: "claude")]
        try automation.save(to: tempRoot)

        let tmp = (tempRoot as NSString)
            .appendingPathComponent(".clearway/workflow.json.tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp))
    }

    // MARK: - hasAnyRule / actions(for:)

    /// `hasAnyRule` must be false for an empty rules dict (nothing fires, "Start Now" disabled).
    func testHasAnyRuleFalseForEmptyAutomation() {
        XCTAssertFalse(WorkflowAutomation().hasAnyRule)
    }

    /// `hasAnyRule` must be false when every status maps to an empty action array — an empty list
    /// is semantically the same as an absent key per the brief.
    func testHasAnyRuleFalseWhenAllArraysEmpty() {
        var automation = WorkflowAutomation()
        automation.rules[.inProgress] = []
        automation.rules[.qa] = []
        XCTAssertFalse(automation.hasAnyRule)
    }

    /// `hasAnyRule` flips to true the moment any status has at least one action.
    func testHasAnyRuleTrueWithAtLeastOneAction() {
        var automation = WorkflowAutomation()
        automation.rules[.qa] = [WorkflowAutomation.Action(command: "x", agent: "claude")]
        XCTAssertTrue(automation.hasAnyRule)
    }

    /// `actions(for:)` returns the rule list for the matching status.
    func testActionsForReturnsConfiguredActions() {
        var automation = WorkflowAutomation()
        automation.rules[.qa] = [
            WorkflowAutomation.Action(command: "a", agent: "claude"),
            WorkflowAutomation.Action(command: "b", agent: "codex")
        ]
        XCTAssertEqual(automation.actions(for: .qa).map { $0.command }, ["a", "b"])
    }

    /// `actions(for:)` returns an empty array for a status with no rule — callers iterate it
    /// directly without nil-checks.
    func testActionsForReturnsEmptyForMissingStatus() {
        XCTAssertEqual(WorkflowAutomation().actions(for: .done), [])
    }

    // MARK: - render

    /// The renderer must replace every supported `{{ var }}` with the matching task field. Variable
    /// keys come from the brief and must stay in sync with `WorkflowConfig.taskVariables` to keep
    /// PLANNING.md and workflow.json templates portable.
    func testRenderInterpolatesAllStandardVariables() {
        var task = WorkTask(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Title!",
            status: .inProgress,
            worktree: "feature/branch",
            body: "Body content"
        )
        task.attempt = 3

        let rendered = WorkflowAutomation.render(
            "title={{ task.title }} body={{ task.body }} id={{ task.id }} path={{ task.path }} worktree={{ task.worktree }} attempt={{ attempt }} qa={{ status.qa }}",
            task: task,
            taskPath: "/tmp/task.md",
            attempt: 3
        )

        XCTAssertEqual(
            rendered,
            "title=Title! body=Body content id=11111111-2222-3333-4444-555555555555 path=/tmp/task.md worktree=feature/branch attempt=3 qa=qa"
        )
    }

    /// Unknown variable keys must be left verbatim so future template additions degrade gracefully
    /// instead of silently dropping content. The brief explicitly states "no shell escaping".
    func testRenderLeavesUnknownVariablesVerbatim() {
        let task = WorkTask(title: "T", status: .new, worktree: nil, body: "")
        let out = WorkflowAutomation.render(
            "before {{ unknown.thing }} after",
            task: task,
            taskPath: nil,
            attempt: nil
        )
        XCTAssertEqual(out, "before {{ unknown.thing }} after")
    }

    /// When `taskPath` is nil the `{{ task.path }}` token must NOT be replaced with an empty
    /// string — the brief treats unknown tokens as verbatim, and missing-but-known tokens map to
    /// the same path. Authors then see literal `{{ task.path }}` in the dispatched command, which
    /// is a clearer failure mode than a silent empty string.
    func testRenderLeavesTaskPathVerbatimWhenAbsent() {
        let task = WorkTask(title: "T", status: .new, worktree: nil, body: "")
        let out = WorkflowAutomation.render(
            "go {{ task.path }} done",
            task: task,
            taskPath: nil,
            attempt: nil
        )
        XCTAssertEqual(out, "go {{ task.path }} done")
    }

    /// Rendered values must NOT be shell-escaped. Actions paste into a running agent, not a shell,
    /// so a command like `echo "hello world"` must arrive at the agent with the quotes intact.
    func testRenderDoesNotShellEscape() {
        let task = WorkTask(title: "He said \"hi\"; rm -rf /", status: .inProgress, worktree: nil, body: "")
        let out = WorkflowAutomation.render(
            "T={{ task.title }}",
            task: task,
            taskPath: nil,
            attempt: nil
        )
        XCTAssertEqual(out, "T=He said \"hi\"; rm -rf /")
    }

    /// Templates with no variables pass through untouched — no crashes, no double-rendering.
    func testRenderWithNoTokensReturnsTemplateUnchanged() {
        let task = WorkTask(title: "T", status: .new, worktree: nil, body: "")
        let out = WorkflowAutomation.render(
            "plain command --flag value",
            task: task,
            taskPath: nil,
            attempt: nil
        )
        XCTAssertEqual(out, "plain command --flag value")
    }

    /// A `{{` without a matching `}}` (truncated template) must not crash the renderer; the
    /// remaining text is appended verbatim.
    func testRenderHandlesUnterminatedToken() {
        let task = WorkTask(title: "T", status: .new, worktree: nil, body: "")
        let out = WorkflowAutomation.render(
            "before {{ task.title and the rest",
            task: task,
            taskPath: nil,
            attempt: nil
        )
        XCTAssertEqual(out, "before {{ task.title and the rest")
    }
}
