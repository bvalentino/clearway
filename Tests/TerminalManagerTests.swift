import XCTest
@testable import Clearway

@MainActor
final class TerminalManagerTests: XCTestCase {

    // MARK: - setInitialPanelVisibility

    func test_setInitialPanelVisibility_mainWorktree_secondaryFollowsProvider() {
        let manager = TerminalManager()
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)

        manager.openSecondaryOnStartProvider = { false }
        manager.setInitialPanelVisibility(for: main.id, worktree: main)
        XCTAssertFalse(manager.isSecondaryVisible(for: main.id))
        XCTAssertFalse(manager.isAsideVisible(for: main.id), "aside stays hidden on the main worktree")

        let other = makeWorktree(branch: "main-2", path: "/tmp/main-2", isMain: true)
        manager.openSecondaryOnStartProvider = { true }
        manager.setInitialPanelVisibility(for: other.id, worktree: other)
        XCTAssertTrue(manager.isSecondaryVisible(for: other.id))
    }

    func test_setInitialPanelVisibility_nonMainWorktree_asideAlwaysOn_secondaryFollowsProvider() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)

        manager.openSecondaryOnStartProvider = { false }
        manager.setInitialPanelVisibility(for: wt.id, worktree: wt)
        XCTAssertTrue(manager.isAsideVisible(for: wt.id))
        XCTAssertFalse(manager.isSecondaryVisible(for: wt.id))

        let wt2 = makeWorktree(branch: "feature-2", path: "/tmp/feature-2", isMain: false)
        manager.openSecondaryOnStartProvider = { true }
        manager.setInitialPanelVisibility(for: wt2.id, worktree: wt2)
        XCTAssertTrue(manager.isAsideVisible(for: wt2.id))
        XCTAssertTrue(manager.isSecondaryVisible(for: wt2.id))
    }

    func test_setInitialPanelVisibility_providerChangeDoesNotMutateExistingPane() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)

        manager.openSecondaryOnStartProvider = { true }
        manager.setInitialPanelVisibility(for: wt.id, worktree: wt)
        XCTAssertTrue(manager.isSecondaryVisible(for: wt.id))

        // Flipping the setting after the pane was seeded must not move existing panes —
        // the provider is consulted only at pane creation, so a manual `Cmd+\` toggle
        // the user made earlier would otherwise be clobbered.
        manager.openSecondaryOnStartProvider = { false }
        XCTAssertTrue(manager.isSecondaryVisible(for: wt.id))

        // Likewise, toggling the setting on must not resurrect a manually hidden pane.
        manager.toggleSecondary(for: wt.id)
        XCTAssertFalse(manager.isSecondaryVisible(for: wt.id))
        manager.openSecondaryOnStartProvider = { true }
        XCTAssertFalse(manager.isSecondaryVisible(for: wt.id))
    }

    func test_openSecondaryOnStartProvider_defaultsToFalse() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)

        manager.setInitialPanelVisibility(for: wt.id, worktree: wt)
        XCTAssertFalse(manager.isSecondaryVisible(for: wt.id),
                       "unwired provider must default to the opt-in-safe `false` path")
    }

    // MARK: - buildPromptPipeCommand

    /// The pipe recipe must positionally inject `agentCommand`, the prompt file, and the
    /// resolved PATH so shell metacharacters in any of them can't escape the `/bin/sh -c`
    /// sandbox. Each positional arg is single-quoted via `shellEscape`.
    func test_buildPromptPipeCommand_positionalArgsAreShellQuoted() throws {
        let cmd = TerminalManager.buildPromptPipeCommand(
            agentCommand: "claude --flag",
            prompt: "Hello"
        )

        XCTAssertTrue(cmd.hasPrefix("/bin/sh -c "), "must launch via /bin/sh -c")
        XCTAssertTrue(cmd.contains("'claude --flag'"),
                      "agent command must be a single quoted positional arg, not expanded")
        XCTAssertTrue(cmd.contains("cat \"$2\" | $1"),
                      "recipe must read the prompt file on stdin of the agent command")
        XCTAssertTrue(cmd.contains("rm -f \"$2\""),
                      "recipe must remove the prompt file after the agent consumes it")

        // The prompt file should be written to the temp dir with the expected prefix,
        // and its contents should match what the caller passed.
        let lines = cmd.components(separatedBy: " ")
        let quoted = lines.first(where: { $0.contains("clearway-launcher-") })
        let path = quoted?.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        XCTAssertNotNil(path)
        let data = FileManager.default.contents(atPath: path ?? "")
        XCTAssertEqual(data.flatMap { String(data: $0, encoding: .utf8) }, "Hello")
        try? FileManager.default.removeItem(atPath: path ?? "")
    }
}
