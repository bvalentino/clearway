import XCTest
@testable import Clearway

/// Pins the managed block of the spec's Decisions 10–12: reconciled by content rather than
/// versioned, recognised by substring rather than equality, and collapsing every container it
/// empties so an uninstall leaves no trace. Every assertion compares whole JSON objects, because
/// "the user's entries are preserved value-for-value" is a property of the document, not of a key.
final class AgentHookSettingsTests: XCTestCase {

    private let clearwayHook: [String: Any] = [
        "type": "command",
        "command": AgentHookScript.command,
    ]

    private let userHook: [String: Any] = [
        "type": "command",
        "command": "~/bin/my-hook.sh",
    ]

    // MARK: - Install

    func testInstallIntoEmptySettingsProducesExactlyTheNineEvents() {
        let result = AgentHookSettings.install(into: [:])
        let hooks = result["hooks"] as? [String: Any] ?? [:]

        XCTAssertEqual(hooks.count, 9)
        XCTAssertEqual(Set(hooks.keys), Set(AgentHookScript.installedEvents))

        for event in AgentHookScript.installedEvents {
            let groups = hooks[event] as? [[String: Any]]
            XCTAssertEqual(groups?.count, 1, "\(event) should carry exactly one group")
            XCTAssertNil(groups?.first?["matcher"], "\(event) group must omit the matcher key")
            XCTAssertEqual(groups?.first?["hooks"] as? NSArray, [clearwayHook] as NSArray)
        }
    }

    func testInstallIsIdempotentForEveryStartingShape() {
        for start in [emptySettings, settingsWithUserHooks, AgentHookSettings.install(into: settingsWithUserHooks)] {
            let once = AgentHookSettings.install(into: start)
            XCTAssertEqual(AgentHookSettings.install(into: once) as NSDictionary, once as NSDictionary)
        }
    }

    func testInstallLeavesUnrelatedKeysAndUserGroupsUntouched() {
        let result = AgentHookSettings.install(into: settingsWithUserHooks)

        XCTAssertEqual(result["model"] as? String, "opus")
        XCTAssertEqual(result["permissions"] as? NSDictionary, ["allow": ["Bash"]] as NSDictionary)

        let groups = (result["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(groups?.count, 2, "Clearway's group is appended beside the user's, not merged into it")
        XCTAssertEqual(groups?.first?["matcher"] as? String, "Bash")
        XCTAssertEqual(groups?.first?["hooks"] as? NSArray, [userHook] as NSArray)
        XCTAssertEqual(groups?.last?["hooks"] as? NSArray, [clearwayHook] as NSArray)
    }

    /// The one place `install` broke its own rule: a `hooks` value that is not an object read as
    /// empty and was replaced wholesale by the block, while `uninstall` left the same value alone.
    /// The backup makes that recoverable, not acceptable — the two halves must agree.
    func testInstallLeavesAHooksValueItCannotRead() {
        for unreadable in [["an array"] as Any, "a string" as Any, 7 as Any] {
            let start: [String: Any] = ["hooks": unreadable, "model": "opus"]
            XCTAssertEqual(AgentHookSettings.install(into: start) as NSDictionary, start as NSDictionary)
        }
    }

    // MARK: - Uninstall

    func testUninstallUndoesInstallForEveryStartingShape() {
        let userHooksOnClearwaysOwnEvents: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [userHook]]],
                "SessionStart": [["matcher": "startup", "hooks": [userHook]]],
            ],
        ]

        for start in [emptySettings, settingsWithUserHooks, userHooksOnClearwaysOwnEvents] {
            let round = AgentHookSettings.uninstall(from: AgentHookSettings.install(into: start))
            XCTAssertEqual(round as NSDictionary, start as NSDictionary)
        }
    }

    /// The discriminating case for the collapse rule: removing the entries is not enough. A file
    /// whose only hook was Clearway's must come back with no `hooks` key at all — the emptied
    /// group, the emptied event array and the emptied `hooks` object each go in turn.
    func testUninstallRemovesEveryContainerItEmpties() {
        let result = AgentHookSettings.uninstall(from: AgentHookSettings.install(into: [:]))

        XCTAssertNil(result["hooks"])
        XCTAssertTrue(result.isEmpty)
    }

    func testUninstallLeavesEntriesItDoesNotOwn() {
        let foreign: [String: Any] = [
            "hooks": [
                "PreToolUse": [["hooks": [userHook, ["type": "webhook", "url": "https://example.test"]]]],
            ],
        ]

        let result = AgentHookSettings.uninstall(from: AgentHookSettings.install(into: foreign))

        XCTAssertEqual(result as NSDictionary, foreign as NSDictionary)
    }

    // MARK: - Recognition

    /// Substring containment, not equality: a hand-edited entry carrying a matcher or a different
    /// spelling of the same path is still Clearway's and must be removed, or an uninstall leaves a
    /// hook that forwards to a socket nothing is listening on.
    func testHandWrittenClearwayEntriesAreStillRecognised() {
        let handEdited: [String: Any] = [
            "hooks": [
                "Stop": [[
                    "matcher": "",
                    "hooks": [
                        ["type": "command", "command": "$HOME/.clearway/hooks/clearway-hook.sh"],
                        ["type": "command", "command": "sh ~/.clearway/hooks/clearway-hook.sh"],
                    ],
                ]],
            ],
        ]

        XCTAssertTrue(AgentHookSettings.uninstall(from: handEdited).isEmpty)
    }

    func testRecognitionRejectsEntriesThatAreNotClearwaysCommand() {
        XCTAssertFalse(AgentHookSettings.isClearwayEntry(userHook))
        XCTAssertFalse(AgentHookSettings.isClearwayEntry(["type": "webhook", "command": AgentHookScript.command]))
        XCTAssertFalse(AgentHookSettings.isClearwayEntry(["type": "command"]))
        XCTAssertFalse(AgentHookSettings.isClearwayEntry("clearway-hook.sh"))
        XCTAssertTrue(AgentHookSettings.isClearwayEntry(clearwayHook))
    }

    // MARK: - Identity

    func testIdentityCarriesTheWorktreeOnlyWhenThereIsOne() {
        let surfaceId = UUID()

        let stamped = AgentHookIdentity.environment(surfaceId: surfaceId, worktreeId: "/Users/x/my repo")
        XCTAssertEqual(stamped.count, 3)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: stamped.map { ($0.key, $0.value) }), [
            "CLEARWAY_SURFACE_ID": surfaceId.uuidString,
            "CLEARWAY_WORKTREE_ID": "/Users/x/my repo",
            "CLEARWAY_HOOK_SOCKET": AgentHookPaths().socketPath,
        ])

        let unstamped = AgentHookIdentity.environment(surfaceId: surfaceId, worktreeId: nil)
        XCTAssertEqual(unstamped.count, 2)
        XCTAssertNil(unstamped.first { $0.key == "CLEARWAY_WORKTREE_ID" })
    }

    // MARK: - The forwarder

    /// The script is shell text, so nothing but a test ties it to the names the Swift side stamps
    /// or keeps the `-N` flag out — macOS `nc` reads `-N` as a probe count, so a script using it
    /// fails silently on every hook.
    func testForwarderKeepsItsGuardsAndItsTransport() {
        let body = AgentHookScript.body

        XCTAssertTrue(body.hasPrefix("#!/bin/sh\n"))
        for key in ["CLEARWAY_SURFACE_ID", "CLEARWAY_WORKTREE_ID", "CLEARWAY_HOOK_SOCKET"] {
            XCTAssertTrue(body.contains("[ -n \"$\(key)\" ] || exit 0") || body.contains("[ -S \"$\(key)\" ] || exit 0"),
                          "\(key) must be guarded before anything is forwarded")
        }
        XCTAssertTrue(body.contains("/usr/bin/nc -U -w 1 \"$CLEARWAY_HOOK_SOCKET\""))
        XCTAssertFalse(body.contains(" -N"))
        XCTAssertTrue(body.hasSuffix("exit 0\n"))
        XCTAssertTrue(AgentHookScript.command.contains(AgentHookScript.scriptPathMarker))
    }

    // MARK: - Fixtures

    private let emptySettings: [String: Any] = [:]

    private var settingsWithUserHooks: [String: Any] {
        [
            "model": "opus",
            "permissions": ["allow": ["Bash"]],
            "hooks": [
                "PreToolUse": [["matcher": "Bash", "hooks": [userHook]]],
            ],
        ]
    }
}
