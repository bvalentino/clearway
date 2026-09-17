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
            OpenInAppLauncher.failureMessage(command: "zed", stderr: "sh: zed: command not found"),
            "sh: zed: command not found"
        )
    }

    func test_failureMessage_namesTheCommandWhenTheShellSaidNothing() {
        XCTAssertEqual(
            OpenInAppLauncher.failureMessage(command: "false", stderr: ""),
            "\"false\" failed without reporting an error."
        )
    }

    func test_launch_commandThatSucceeds_reportsLaunched() async {
        let outcome = await OpenInAppLauncher.launch(command: "true", path: "/tmp")
        XCTAssertEqual(outcome, .launched)
    }

    func test_launch_commandThatExitsNonZero_reportsFailed() async {
        let outcome = await OpenInAppLauncher.launch(command: "false", path: "/tmp")
        guard case .failed = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
    }

    func test_launch_commandNotOnPath_reportsTheShellsError() async {
        let outcome = await OpenInAppLauncher.launch(command: "clearway-no-such-command", path: "/tmp")
        guard case .failed(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("command not found"), "unexpected message: \(message)")
        XCTAssertTrue(message.contains("clearway-no-such-command"), "unexpected message: \(message)")
    }

    func test_launch_commandThatKeepsRunning_reportsLaunchedAtTheDeadline() async {
        let started = Date()
        let outcome = await OpenInAppLauncher.launch(command: "sleep 5 #", path: "/tmp")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome, .launched)
        XCTAssertGreaterThanOrEqual(elapsed, OpenInAppLauncher.watchWindow - 0.2)
        XCTAssertLessThan(elapsed, OpenInAppLauncher.watchWindow + 1.5)
    }

    func test_launch_spawnThatThrows_reportsTheErrorAsAFailure() async {
        let outcome = await OpenInAppLauncher.launch(command: "true", path: "/tmp/clearway-no-such-directory")
        guard case .failed(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("clearway-no-such-directory"), "unexpected message: \(message)")
    }
}
