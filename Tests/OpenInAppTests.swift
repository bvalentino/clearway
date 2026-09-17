import XCTest
@testable import Clearway

final class OpenInAppTests: XCTestCase {

    func test_builtIns_reportLabelsAndDefaultCommands() {
        XCTAssertEqual(OpenInBuiltIn.finder.label, "Finder")
        XCTAssertEqual(OpenInBuiltIn.finder.defaultCommand, "open")
        XCTAssertEqual(OpenInBuiltIn.vsCode.label, "VS Code")
        XCTAssertEqual(OpenInBuiltIn.vsCode.defaultCommand, "code")
        XCTAssertEqual(OpenInBuiltIn.cursor.label, "Cursor")
        XCTAssertEqual(OpenInBuiltIn.cursor.defaultCommand, "cursor")
        XCTAssertEqual(OpenInBuiltIn.zed.label, "Zed")
        XCTAssertEqual(OpenInBuiltIn.zed.defaultCommand, "zed")
    }

    func test_builtIns_rawValuesArePersistedForm() {
        XCTAssertEqual(OpenInBuiltIn.allCases.map(\.rawValue), ["finder", "vsCode", "cursor", "zed"])
    }

    func test_label_readsBuiltInLabel() {
        let app = OpenInApp(kind: .builtIn(.vsCode), command: "code")
        XCTAssertEqual(app.label, "VS Code")
    }

    func test_label_readsCustomLabel() {
        let app = OpenInApp(kind: .custom(label: "Xcode"), command: "xed")
        XCTAssertEqual(app.label, "Xcode")
    }

    func test_availableBuiltIns_excludingEmptyList_returnsAllInAllCasesOrder() {
        XCTAssertEqual(OpenInApp.availableBuiltIns(excluding: []), OpenInBuiltIn.allCases)
    }

    func test_availableBuiltIns_omitsPresentBuiltIns_preservingAllCasesOrder() {
        let apps = [
            OpenInApp(kind: .builtIn(.cursor), command: "cursor"),
            OpenInApp(kind: .builtIn(.finder), command: "open"),
        ]
        XCTAssertEqual(OpenInApp.availableBuiltIns(excluding: apps), [.vsCode, .zed])
    }

    func test_availableBuiltIns_everyBuiltInPresent_offersNone() {
        let apps = OpenInBuiltIn.allCases.map { OpenInApp(kind: .builtIn($0), command: $0.defaultCommand) }
        XCTAssertEqual(OpenInApp.availableBuiltIns(excluding: apps), [])
    }

    func test_availableBuiltIns_customEntriesExcludeNothing() {
        let apps = [
            OpenInApp(kind: .custom(label: "Xcode"), command: "xed"),
            OpenInApp(kind: .custom(label: "Finder"), command: "open"),
        ]
        XCTAssertEqual(OpenInApp.availableBuiltIns(excluding: apps), OpenInBuiltIn.allCases)
    }

    func test_customDraft_isValidOnlyWhenBothFieldsAreNonBlank() {
        XCTAssertTrue(OpenInApp.Draft(builtIn: nil, label: "Xcode", command: "xed").isValid)
        XCTAssertFalse(OpenInApp.Draft(builtIn: nil, label: "  ", command: "xed").isValid)
        XCTAssertFalse(OpenInApp.Draft(builtIn: nil, label: "Xcode", command: " \t ").isValid)
        XCTAssertFalse(OpenInApp.Draft(builtIn: nil, label: "", command: "").isValid)
    }

    func test_builtInDraft_isValidOnCommandAlone() {
        XCTAssertTrue(OpenInApp.Draft(builtIn: .cursor, label: "", command: "cursor").isValid)
        XCTAssertFalse(OpenInApp.Draft(builtIn: .cursor, label: "Cursor", command: "   ").isValid)
    }

    func test_builtInApp_roundTripsThroughJSON() throws {
        let app = OpenInApp(kind: .builtIn(.zed), command: "zed --new")
        let decoded = try JSONDecoder().decode(OpenInApp.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(decoded, app)
    }

    func test_customApp_roundTripsThroughJSON() throws {
        let app = OpenInApp(kind: .custom(label: "Xcode"), command: "xed")
        let decoded = try JSONDecoder().decode(OpenInApp.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(decoded, app)
    }

    /// Pins the synthesized `Codable` shape of `Kind`, which a round-trip test cannot: renaming a
    /// case or its associated-value label orphans every stored entry with no compiler complaint.
    func test_storedWireFormat_decodesFromItsPersistedBytes() throws {
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","kind":{"builtIn":{"_0":"zed"}},"command":"zed"},
         {"id":"\(id.uuidString)","kind":{"custom":{"label":"Xcode"}},"command":"xed"}]
        """
        let decoded = try JSONDecoder().decode([OpenInApp].self, from: Data(json.utf8))

        XCTAssertEqual(decoded.map(\.kind), [.builtIn(.zed), .custom(label: "Xcode")])
        XCTAssertEqual(decoded.map(\.command), ["zed", "xed"])
    }

    func test_upsert_replacesInPlaceSoTheEntryKeepsItsPosition() {
        let middle = OpenInApp(kind: .builtIn(.cursor), command: "cursor")
        let apps = [
            OpenInApp(kind: .builtIn(.finder), command: "open"),
            middle,
            OpenInApp(kind: .custom(label: "Xcode"), command: "xed")
        ]

        let updated = OpenInApp.upsert(OpenInApp(id: middle.id, kind: .builtIn(.cursor), command: "cursor --wait"), into: apps)

        XCTAssertEqual(updated.map(\.label), ["Finder", "Cursor", "Xcode"])
        XCTAssertEqual(updated[1].command, "cursor --wait")
    }

    func test_upsert_appendsAnIdThatIsNotInTheList() {
        let apps = [OpenInApp(kind: .builtIn(.finder), command: "open")]
        let added = OpenInApp(kind: .custom(label: "Xcode"), command: "xed")

        XCTAssertEqual(OpenInApp.upsert(added, into: apps), apps + [added])
    }

    func test_draftFromBuiltInApp_carriesTheBuiltInAndItsCommand() {
        let draft = OpenInApp.Draft(app: OpenInApp(kind: .builtIn(.cursor), command: "cursor --wait"))
        XCTAssertEqual(draft, OpenInApp.Draft(builtIn: .cursor, label: "Cursor", command: "cursor --wait"))
    }

    func test_draftFromCustomApp_carriesTheLabelAndCommand() {
        let draft = OpenInApp.Draft(app: OpenInApp(kind: .custom(label: "Xcode"), command: "xed"))
        XCTAssertEqual(draft, OpenInApp.Draft(builtIn: nil, label: "Xcode", command: "xed"))
    }

    func test_draftApp_keepsTheBuiltInKindSoOnlyTheCommandIsEditable() {
        let existing = OpenInApp(kind: .builtIn(.zed), command: "zed")
        let edited = OpenInApp.Draft(builtIn: .zed, label: "renamed", command: "zed --new").app(id: existing.id)
        XCTAssertEqual(edited.id, existing.id)
        XCTAssertEqual(edited.kind, .builtIn(.zed))
        XCTAssertEqual(edited.label, "Zed")
        XCTAssertEqual(edited.command, "zed --new")
    }

    func test_draftApp_buildsACustomEntryFromTheLabelField() {
        let id = UUID()
        let app = OpenInApp.Draft(builtIn: nil, label: "Xcode", command: "xed").app(id: id)
        XCTAssertEqual(app, OpenInApp(id: id, kind: .custom(label: "Xcode"), command: "xed"))
    }

    func test_draftApp_trimsTheFieldsTheValidityRuleTrims() {
        let app = OpenInApp.Draft(builtIn: nil, label: "  Xcode ", command: " xed  ").app(id: UUID())
        XCTAssertEqual(app.label, "Xcode")
        XCTAssertEqual(app.command, "xed")
    }
}

// MARK: - Launcher

extension OpenInAppTests {

    func test_buildOpenInScript_runsTheCommandWithTheFolderAppended() {
        let script = OpenInAppLauncher.buildOpenInScript(command: "cursor", path: "/tmp/wt")
        XCTAssertEqual(script, "cursor '/tmp/wt'")
    }

    func test_buildOpenInScript_escapesAPathWithSpacesAndQuotes() {
        let script = OpenInAppLauncher.buildOpenInScript(command: "zed", path: "/tmp/it's here")
        XCTAssertEqual(script, "zed '/tmp/it'\\''s here'")
    }

    func test_buildOpenInScript_interpolatesTheCommandVerbatim() {
        let flags = OpenInAppLauncher.buildOpenInScript(command: "myeditor --new-window", path: "/tmp/wt")
        XCTAssertEqual(flags, "myeditor --new-window '/tmp/wt'")

        let operators = OpenInAppLauncher.buildOpenInScript(command: "a && b", path: "/tmp/wt")
        XCTAssertEqual(operators, "a && b '/tmp/wt'")
    }

    func test_failureMessage_quotesTheShellsTextWhenThereIsSome() {
        XCTAssertEqual(
            OpenInAppLauncher.failureMessage(command: "zed", detail: "sh: zed: command not found"),
            "sh: zed: command not found"
        )
    }

    func test_failureMessage_namesTheCommandWhenTheShellSaidNothing() {
        XCTAssertEqual(
            OpenInAppLauncher.failureMessage(command: "false", detail: ""),
            "\"false\" failed without reporting an error."
        )
    }

    func test_spawnFailureMessage_namesTheFolderRatherThanLeavingItOnTheApp() {
        let message = OpenInAppLauncher.spawnFailureMessage(
            directory: "/tmp/gone",
            error: CocoaError(.fileNoSuchFile)
        )
        XCTAssertTrue(message.hasPrefix("Couldn't run in /tmp/gone — "), "unexpected message: \(message)")
    }

    func test_launch_commandThatSucceeds_reportsLaunched() async {
        let outcome = await OpenInAppLauncher.launch(command: "true", path: "/tmp")
        XCTAssertEqual(outcome, .launched)
    }

    func test_launch_commandThatExitsNonZero_reportsFailedWithNoDetail() async {
        let outcome = await OpenInAppLauncher.launch(command: "false", path: "/tmp")
        XCTAssertEqual(outcome, .failed(message: ""))
    }

    func test_launch_failureThatPrintsToStdout_reportsWhatItPrinted() async {
        let outcome = await OpenInAppLauncher.launch(command: "echo 'no project here'; exit 1 #", path: "/tmp")
        XCTAssertEqual(outcome, .failed(message: "no project here"))
    }

    /// Pins both halves of the execution contract: the child inherits the resolved PATH through
    /// `processEnvironment`, and it runs in the worktree folder. Nothing else notices if either
    /// assignment is dropped — the test host's own PATH and cwd are good enough to hide it.
    func test_launch_runsInTheFolderWithTheResolvedPath() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clearway-open-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let outcome = await OpenInAppLauncher.launch(
            command: "{ printenv PATH; pwd; } > captured #",
            path: folder.path
        )
        XCTAssertEqual(outcome, .launched)

        let lines = try String(contentsOf: folder.appendingPathComponent("captured"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, ShellEnvironment.path)
        XCTAssertEqual(
            lines.last.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            folder.resolvingSymlinksInPath().path
        )
    }

    func test_launch_commandNotOnPath_reportsTheShellsError() async {
        let outcome = await OpenInAppLauncher.launch(command: "clearway-no-such-command", path: "/tmp")
        guard case .failed(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("command not found"), "unexpected message: \(message)")
        XCTAssertTrue(message.contains("clearway-no-such-command"), "unexpected message: \(message)")
    }

    func test_launch_nonZeroExitWithADescendantHoldingTheOutput_stillReportsFailure() async {
        let started = Date()
        let outcome = await OpenInAppLauncher.launch(command: "sleep 30 & echo boom 1>&2; exit 1 #", path: "/tmp")
        let elapsed = Date().timeIntervalSince(started)

        guard case .failed(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("boom"), "unexpected message: \(message)")
        XCTAssertLessThan(elapsed, OpenInAppLauncher.watchWindow, "the verdict waited on the descendant, not the shell's exit")
    }

    func test_launch_commandThatKeepsRunning_reportsLaunchedAtTheDeadline() async {
        let started = Date()
        let outcome = await OpenInAppLauncher.launch(command: "sleep 5 #", path: "/tmp")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome, .launched)
        XCTAssertGreaterThanOrEqual(elapsed, OpenInAppLauncher.watchWindow - 0.2)
        XCTAssertLessThan(elapsed, OpenInAppLauncher.watchWindow + 1.5)
    }

    /// Decision 15: a child still running at the deadline counts as launched, and the non-zero
    /// exit it reaches later raises no alert.
    func test_launch_failureAfterTheDeadline_staysLaunched() async {
        let outcome = await OpenInAppLauncher.launch(command: "sleep 4; exit 1 #", path: "/tmp")
        XCTAssertEqual(outcome, .launched)
    }

    func test_launch_spawnThatThrows_reportsTheErrorAsAFailure() async {
        let outcome = await OpenInAppLauncher.launch(command: "true", path: "/tmp/clearway-no-such-directory")
        guard case .failed(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("clearway-no-such-directory"), "unexpected message: \(message)")
    }
}
