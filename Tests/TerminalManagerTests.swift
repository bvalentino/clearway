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

    // MARK: - runHookInSecondary visibility

    /// Running an after_create hook must force the secondary panel visible even when
    /// "open secondary on start" is off — otherwise the hook would run (and possibly
    /// fail) in a panel the user can't see. `setInitialPanelVisibility` stands in for
    /// the provider-driven default `pane(for:)` seeds before the hook reveal.
    func test_runHookInSecondary_forcesSecondaryVisible_overridingOpenOnStartOff() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)

        manager.openSecondaryOnStartProvider = { false }
        manager.setInitialPanelVisibility(for: wt.id, worktree: wt)
        XCTAssertFalse(manager.isSecondaryVisible(for: wt.id), "precondition: secondary starts hidden")

        manager.revealSecondaryForHook(for: wt.id)
        XCTAssertTrue(manager.isSecondaryVisible(for: wt.id),
                      "the hook reveal must win over the open-on-start-off default")
    }

    // MARK: - LauncherPromotion.command

    func test_launcherPromotion_command_pattern_matches() {
        // Empty Enter should land in this case at the call site, carrying the
        // resolved main command (e.g. "claude") with no stdin.
        let mode: TerminalManager.LauncherPromotion = .command("claude")
        guard case .command(let cmd) = mode else {
            return XCTFail("Expected .command case but got \(mode)")
        }
        XCTAssertEqual(cmd, "claude")
    }

    // MARK: - buildBareCommand

    /// The bare command must `exec` the agent so tab-close signals reach the
    /// agent directly, not a wrapping `/bin/sh`. Mirrors the rationale in the
    /// helper's docstring.
    func test_buildBareCommand_usesExec_forDirectSignalDelivery() {
        let manager = TerminalManager()
        let out = manager.buildBareCommand(agentCommand: "claude")
        XCTAssertTrue(out.contains("exec $1"),
                      "buildBareCommand must `exec` the agent; got: \(out)")
    }

    /// Without exporting the login-shell PATH, user-installed agents like
    /// `~/.bun/bin/claude` or `~/.claude/local/claude` would `command not found`.
    func test_buildBareCommand_exportsLoginShellPath() {
        let manager = TerminalManager()
        let out = manager.buildBareCommand(agentCommand: "claude")
        XCTAssertTrue(out.contains("export PATH="),
                      "buildBareCommand must export PATH; got: \(out)")
    }

    /// `set -f` disables glob expansion so an agent name containing `*`/`?`
    /// can't accidentally be globbed by the wrapping shell.
    func test_buildBareCommand_disablesGlobbing() {
        let manager = TerminalManager()
        let out = manager.buildBareCommand(agentCommand: "claude")
        XCTAssertTrue(out.contains("set -f"),
                      "buildBareCommand must `set -f` to disable globbing; got: \(out)")
    }

    /// Unlike the prompt-pipe recipe, the bare path takes no stdin: there
    /// must be no temp-file argument and no `cat … | $1` pipe.
    func test_buildBareCommand_hasNoStdinPipe_orTempFile() {
        let manager = TerminalManager()
        let out = manager.buildBareCommand(agentCommand: "claude")
        XCTAssertFalse(out.contains("cat "),
                       "buildBareCommand must not pipe a temp file into the agent; got: \(out)")
        XCTAssertFalse(out.contains("clearway-launcher-"),
                       "buildBareCommand must not allocate a launcher temp file; got: \(out)")
    }

    /// Security: shell metacharacters in the user-configured main command
    /// must be quoted, not interpolated. A command of `claude; rm -rf /`
    /// must reach `/bin/sh -c` as a single positional argument.
    func test_buildBareCommand_quotesShellMetacharacters_inAgentCommand() {
        let manager = TerminalManager()
        let malicious = "claude; rm -rf /"
        let out = manager.buildBareCommand(agentCommand: malicious)

        // The agent command must appear single-quoted (per `shellEscape`) so
        // `/bin/sh -c` receives it as $1, not as additional commands.
        XCTAssertTrue(out.contains("'claude; rm -rf /'"),
                      "agent command must be single-quoted; got: \(out)")
        // And the bare `rm -rf /` substring must NOT appear unquoted in a
        // position where the outer shell would parse it as a new command.
        // (We assert the only occurrence is inside the quoted form above.)
        let unquotedCount = out.components(separatedBy: "rm -rf /").count - 1
        let quotedCount = out.components(separatedBy: "'claude; rm -rf /'").count - 1
        XCTAssertEqual(unquotedCount, quotedCount,
                       "every occurrence of the dangerous substring must be inside a quoted argument; got: \(out)")
    }

    /// Single quotes in the agent command must be handled by the
    /// `'\''` quote-escape recipe in `shellEscape`, not by string interpolation.
    func test_buildBareCommand_escapesSingleQuotes_inAgentCommand() {
        let manager = TerminalManager()
        let out = manager.buildBareCommand(agentCommand: "weird'name")
        XCTAssertTrue(out.contains("'weird'\\''name'"),
                      "single quotes must be escaped via `'\\''` to stay inside the quoted form; got: \(out)")
    }

    /// Sanity: the resulting command is a well-formed `/bin/sh -c <recipe> -- <agent> <path>`
    /// invocation with exactly two positional arguments after `--`.
    func test_buildBareCommand_shapeMatches_binShCRecipeWithTwoPositionals() {
        let manager = TerminalManager()
        let out = manager.buildBareCommand(agentCommand: "claude")
        XCTAssertTrue(out.hasPrefix("/bin/sh -c "),
                      "must invoke /bin/sh -c; got: \(out)")
        XCTAssertTrue(out.contains(" -- "),
                      "must pass `--` before positional args so dashed agent names aren't parsed as options; got: \(out)")
    }
}
