import XCTest
@testable import Clearway

/// Pins the whole mapping from an enable attempt to the one line Settings displays: the precedence
/// between a socket failure and an install failure, the rule that only a *wholly* absent set of
/// agent directories is a failure, and each case's sentence character for character. Nothing here
/// touches a socket or a disk — that is the point of the type existing on its own.
final class AgentHookHealthTests: XCTestCase {

    private func report(scriptWritten: Bool = true, _ files: AgentHookFileOutcome...) -> AgentHookInstallReport {
        AgentHookInstallReport(scriptWritten: scriptWritten, files: files)
    }

    private let claude = "~/.claude/settings.json"
    private let codex = "~/.codex/hooks.json"

    // MARK: - Messages

    func testOffAndListeningDisplayNothing() {
        XCTAssertNil(AgentHookHealth.off.message)
        XCTAssertNil(AgentHookHealth.listening.message)
    }

    func testEveryFailureCarriesItsSentence() {
        XCTAssertEqual(
            AgentHookHealth.socketOwnedByAnotherInstance.message,
            "Another Clearway instance is using the hook socket."
        )
        XCTAssertEqual(
            AgentHookHealth.socketUnopenable.message,
            "The hook socket at ~/.clearway/hook.sock could not be opened."
        )
        XCTAssertEqual(
            AgentHookHealth.scriptNotWritten.message,
            "The hook script could not be written to ~/.clearway/hooks."
        )
        XCTAssertEqual(
            AgentHookHealth.noAgentDirectory.message,
            "No ~/.claude or ~/.codex directory was found, so no hooks were installed."
        )
        XCTAssertEqual(
            AgentHookHealth.settingsRefused(path: claude).message,
            "~/.claude/settings.json could not be updated."
        )
    }

    func testTheRefusedMessageNamesTheFileItWasGiven() {
        XCTAssertEqual(
            AgentHookHealth.settingsRefused(path: codex).message,
            "~/.codex/hooks.json could not be updated."
        )
    }

    // MARK: - Resolve

    func testAPerfectAttemptIsListening() {
        XCTAssertEqual(AgentHookHealth.resolve(install: report(.installed, .installed), socket: .listening), .listening)
    }

    func testALiveOwnerOutranksEveryInstallFailure() {
        let worst = report(scriptWritten: false, .refused(path: claude), .absent)
        XCTAssertEqual(AgentHookHealth.resolve(install: worst, socket: .ownedByAnotherInstance), .socketOwnedByAnotherInstance)
    }

    func testAnUnopenableSocketOutranksEveryInstallFailure() {
        let worst = report(scriptWritten: false, .refused(path: claude), .absent)
        XCTAssertEqual(AgentHookHealth.resolve(install: worst, socket: .unopenable), .socketUnopenable)
    }

    func testALiveOwnerIsReportedEvenWhenTheInstallIsPerfect() {
        XCTAssertEqual(AgentHookHealth.resolve(install: report(.installed, .installed), socket: .ownedByAnotherInstance), .socketOwnedByAnotherInstance)
    }

    func testTheMissingScriptOutranksEveryFileOutcome() {
        XCTAssertEqual(
            AgentHookHealth.resolve(install: report(scriptWritten: false, .absent, .absent), socket: .listening),
            .scriptNotWritten
        )
        XCTAssertEqual(
            AgentHookHealth.resolve(install: report(scriptWritten: false, .refused(path: claude), .installed), socket: .listening),
            .scriptNotWritten
        )
    }

    func testEveryDirectoryAbsentIsTheOnlyAbsenceThatIsAFailure() {
        XCTAssertEqual(AgentHookHealth.resolve(install: report(.absent, .absent), socket: .listening), .noAgentDirectory)
    }

    func testOneAbsentDirectoryBesideAnInstalledOneIsHealthy() {
        XCTAssertEqual(AgentHookHealth.resolve(install: report(.installed, .absent), socket: .listening), .listening)
        XCTAssertEqual(AgentHookHealth.resolve(install: report(.absent, .installed), socket: .listening), .listening)
    }

    func testOneAbsentDirectoryBesideARefusedFileNamesTheRefusedFile() {
        XCTAssertEqual(
            AgentHookHealth.resolve(install: report(.refused(path: claude), .absent), socket: .listening),
            .settingsRefused(path: claude)
        )
        XCTAssertEqual(
            AgentHookHealth.resolve(install: report(.absent, .refused(path: codex)), socket: .listening),
            .settingsRefused(path: codex)
        )
    }

    func testTwoRefusedFilesDisplayTheFirstTheInstallerWalked() {
        XCTAssertEqual(
            AgentHookHealth.resolve(install: report(.refused(path: claude), .refused(path: codex)), socket: .listening),
            .settingsRefused(path: claude)
        )
    }

    func testAnEmptyFileListIsNotAnAbsentDirectory() {
        XCTAssertEqual(AgentHookHealth.resolve(install: report(), socket: .listening), .listening)
    }
}
