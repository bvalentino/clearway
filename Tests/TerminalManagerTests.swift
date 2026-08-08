import XCTest
@testable import Clearway

@MainActor
final class TerminalManagerTests: XCTestCase {

    private let testPath = "/opt/homebrew/bin:/usr/bin:/bin"

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

    // MARK: - resolveAgentCommand

    func test_resolveAgentCommand_prefersNonEmptyWorkflowCommand() {
        let suite = "resolveAgent.prefer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("grok", forKey: SettingsKey.mainTerminalCommand)
        XCTAssertEqual(
            resolveAgentCommand(workflowCommand: "codex", defaults: defaults),
            "codex"
        )
    }

    func test_resolveAgentCommand_fallsBackToMainTerminal_whenWorkflowEmpty() {
        let suite = "resolveAgent.main.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("grok", forKey: SettingsKey.mainTerminalCommand)
        XCTAssertEqual(resolveAgentCommand(workflowCommand: "", defaults: defaults), "grok")
        XCTAssertEqual(resolveAgentCommand(workflowCommand: nil, defaults: defaults), "grok")
        XCTAssertEqual(resolveAgentCommand(workflowCommand: "   ", defaults: defaults), "grok")
    }

    func test_resolveAgentCommand_fallsBackToDefaultMainTerminal_whenBothBlank() {
        let suite = "resolveAgent.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(
            resolveAgentCommand(workflowCommand: nil, defaults: defaults),
            SettingsManager.defaultMainTerminalCommand
        )
    }

    // MARK: - buildAgentPromptCommand

    func test_buildAgentPromptCommand_usesPositionalPrompt_notStdinPipe() {
        let launch = buildAgentPromptCommand(agentCommand: "grok", prompt: "hello", path: testPath)
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }
        XCTAssertTrue(launch.command.contains("\"$(cat \"$2\")\""),
                      "prompt must be a positional arg via cat-into-quotes; got: \(launch.command)")
        XCTAssertFalse(launch.command.contains("cat \"$2\" | $1"),
                       "must not pipe prompt into agent stdin; got: \(launch.command)")
    }

    /// The builder must export the PATH it was given, not one it reads for itself: the
    /// caller is the only place that knows whether a resolution has completed.
    func test_buildAgentPromptCommand_exportsTheGivenPath_andDisablesGlobbing() {
        let launch = buildAgentPromptCommand(agentCommand: "claude", prompt: "x", path: testPath)
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }
        XCTAssertTrue(launch.command.contains("export PATH=") && launch.command.contains("'\(testPath)'"),
                      "must export the given PATH; got: \(launch.command)")
        XCTAssertTrue(launch.command.contains("set -f"), "must disable globbing; got: \(launch.command)")
        XCTAssertTrue(launch.command.contains("rm -f \"$2\""),
                      "must clean up the prompt file after the agent exits; got: \(launch.command)")
    }

    func test_buildAgentPromptCommand_writesPromptFile_andQuotesAgentCommand() {
        let launch = buildAgentPromptCommand(
            agentCommand: "claude; rm -rf /",
            prompt: "do the work",
            path: testPath,
            filePrefix: "clearway-test-prompt"
        )
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: launch.promptFile),
                      "must write the prompt temp file")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: launch.promptFile)),
           let body = String(data: data, encoding: .utf8) {
            XCTAssertEqual(body, "do the work")
        } else {
            XCTFail("could not read prompt file at \(launch.promptFile)")
        }
        XCTAssertTrue(launch.command.contains("'claude; rm -rf /'"),
                      "agent command must be single-quoted; got: \(launch.command)")
        XCTAssertTrue(launch.command.hasPrefix("/bin/sh -c "),
                      "must invoke /bin/sh -c; got: \(launch.command)")
        XCTAssertTrue(launch.command.contains(" -- "),
                      "must pass `--` before positionals; got: \(launch.command)")
    }

    func test_buildAgentPromptCommand_keepsSpecialCharsInFile_notInShellString() {
        let prompt = "say \"hi\"\n$HOME `id` 'x'"
        let launch = buildAgentPromptCommand(agentCommand: "grok", prompt: prompt, path: testPath)
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: launch.promptFile)),
           let body = String(data: data, encoding: .utf8) {
            XCTAssertEqual(body, prompt, "prompt file must preserve the body byte-for-byte")
        } else {
            XCTFail("could not read prompt file at \(launch.promptFile)")
        }
        XCTAssertFalse(launch.command.contains(prompt),
                       "prompt body must not be inlined into the shell string")
        XCTAssertFalse(launch.command.contains("$HOME"),
                       "prompt metacharacters must not appear raw in the shell string")
        XCTAssertTrue(launch.command.contains("\"$(cat \"$2\")\""),
                      "must still use positional cat expansion; got: \(launch.command)")
    }

    func test_buildAgentPromptCommand_escapesSingleQuotes_inAgentCommand() {
        let launch = buildAgentPromptCommand(agentCommand: "weird'name", prompt: "x", path: testPath)
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }
        XCTAssertTrue(launch.command.contains("'weird'\\''name'"),
                      "single quotes in agent command must be shell-escaped; got: \(launch.command)")
    }

    func test_buildAgentPromptCommand_usesFilePrefix() {
        let launch = buildAgentPromptCommand(
            agentCommand: "grok",
            prompt: "p",
            path: testPath,
            filePrefix: "clearway-launcher"
        )
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }
        XCTAssertTrue(
            (launch.promptFile as NSString).lastPathComponent.hasPrefix("clearway-launcher-"),
            "prompt file name should use the prefix; got: \(launch.promptFile)"
        )
    }

    // MARK: - buildBareCommand

    /// The bare command must `exec` the agent so tab-close signals reach the
    /// agent directly, not a wrapping `/bin/sh`. Mirrors the rationale in the
    /// helper's docstring.
    func test_buildBareCommand_usesExec_forDirectSignalDelivery() {
        let manager = TerminalManager()
        let out = manager.buildBareCommand(agentCommand: "claude", path: testPath)
        XCTAssertTrue(out.contains("exec $1"),
                      "buildBareCommand must `exec` the agent; got: \(out)")
    }

    /// Without exporting the resolved PATH, user-installed agents like `~/.bun/bin/claude`
    /// or `~/.claude/local/claude` would `command not found`. The builder must export the
    /// PATH it was given: the caller is the only place that knows a resolution completed.
    func test_buildBareCommand_exportsTheGivenPath() {
        let manager = TerminalManager()
        let out = manager.buildBareCommand(agentCommand: "claude", path: testPath)
        XCTAssertTrue(out.contains("export PATH=") && out.contains("'\(testPath)'"),
                      "buildBareCommand must export the given PATH; got: \(out)")
    }

    /// `set -f` disables glob expansion so an agent name containing `*`/`?`
    /// can't accidentally be globbed by the wrapping shell.
    func test_buildBareCommand_disablesGlobbing() {
        let manager = TerminalManager()
        let out = manager.buildBareCommand(agentCommand: "claude", path: testPath)
        XCTAssertTrue(out.contains("set -f"),
                      "buildBareCommand must `set -f` to disable globbing; got: \(out)")
    }

    /// Unlike the prompt recipe, the bare path takes no initial prompt: there
    /// must be no temp-file argument and no prompt-file `cat`.
    func test_buildBareCommand_hasNoPromptFile_orCat() {
        let manager = TerminalManager()
        let out = manager.buildBareCommand(agentCommand: "claude", path: testPath)
        XCTAssertFalse(out.contains("cat "),
                       "buildBareCommand must not read a prompt file; got: \(out)")
        XCTAssertFalse(out.contains("clearway-launcher-"),
                       "buildBareCommand must not allocate a launcher temp file; got: \(out)")
    }

    /// Security: shell metacharacters in the user-configured main command
    /// must be quoted, not interpolated. A command of `claude; rm -rf /`
    /// must reach `/bin/sh -c` as a single positional argument.
    func test_buildBareCommand_quotesShellMetacharacters_inAgentCommand() {
        let manager = TerminalManager()
        let malicious = "claude; rm -rf /"
        let out = manager.buildBareCommand(agentCommand: malicious, path: testPath)

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
        let out = manager.buildBareCommand(agentCommand: "weird'name", path: testPath)
        XCTAssertTrue(out.contains("'weird'\\''name'"),
                      "single quotes must be escaped via `'\\''` to stay inside the quoted form; got: \(out)")
    }

    /// Sanity: the resulting command is a well-formed `/bin/sh -c <recipe> -- <agent> <path>`
    /// invocation with exactly two positional arguments after `--`.
    func test_buildBareCommand_shapeMatches_binShCRecipeWithTwoPositionals() {
        let manager = TerminalManager()
        let out = manager.buildBareCommand(agentCommand: "claude", path: testPath)
        XCTAssertTrue(out.hasPrefix("/bin/sh -c "),
                      "must invoke /bin/sh -c; got: \(out)")
        XCTAssertTrue(out.contains(" -- "),
                      "must pass `--` before positional args so dashed agent names aren't parsed as options; got: \(out)")
    }

    // MARK: - beginTaskLaunch

    /// A plan launch awaits the resolved PATH before it has a surface, so nothing else marks the
    /// task as busy for that window. A second press must lose the claim rather than start a second
    /// agent — on a machine whose first resolution blocks, that window is seconds long.
    func test_beginTaskLaunch_secondClaimIsRefusedUntilTheFirstEnds() {
        let manager = TerminalManager()
        let task = UUID()

        XCTAssertTrue(manager.beginTaskLaunch(for: task))
        XCTAssertFalse(manager.beginTaskLaunch(for: task),
                       "a launch already in flight must refuse the second press")

        manager.endTaskLaunch(for: task)
        XCTAssertTrue(manager.beginTaskLaunch(for: task),
                      "the claim must be released once the launch has its surface")
    }

    /// The claim is per task: a launch for one task must not block a launch for another.
    func test_beginTaskLaunch_claimsAreIndependentPerTask() {
        let manager = TerminalManager()

        XCTAssertTrue(manager.beginTaskLaunch(for: UUID()))
        XCTAssertTrue(manager.beginTaskLaunch(for: UUID()))
    }
}
