import XCTest
@testable import Clearway

@MainActor
final class TerminalManagerTests: XCTestCase {

    private let testPath = "/opt/homebrew/bin:/usr/bin:/bin"

    private func makeAgentCommand(name: String) -> SavedCommand {
        SavedCommand(id: UUID(), name: name, kind: .agent, text: "", agent: "claude", autoRun: true)
    }

    // MARK: - setInitialPanelVisibility

    func test_setInitialPanelVisibility_secondaryFollowsProvider() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)

        manager.openSecondaryOnStartProvider = { false }
        manager.setInitialPanelVisibility(for: wt.id)
        XCTAssertFalse(manager.isSecondaryVisible(for: wt.id))

        let wt2 = makeWorktree(branch: "feature-2", path: "/tmp/feature-2", isMain: false)
        manager.openSecondaryOnStartProvider = { true }
        manager.setInitialPanelVisibility(for: wt2.id)
        XCTAssertTrue(manager.isSecondaryVisible(for: wt2.id))
    }

    func test_setInitialPanelVisibility_asideStaysHidden() {
        let manager = TerminalManager()
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)

        manager.setInitialPanelVisibility(for: main.id)
        manager.setInitialPanelVisibility(for: wt.id)

        XCTAssertFalse(manager.isAsideVisible(for: main.id))
        XCTAssertFalse(manager.isAsideVisible(for: wt.id),
                       "the aside opens only when the user asks for it")
    }

    func test_setInitialPanelVisibility_providerChangeDoesNotMutateExistingPane() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)

        manager.openSecondaryOnStartProvider = { true }
        manager.setInitialPanelVisibility(for: wt.id)
        XCTAssertTrue(manager.isSecondaryVisible(for: wt.id))

        // Flipping the setting after the pane was seeded must not move existing panes —
        // the provider is consulted only at pane creation, so a manual Cmd+J toggle
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

        manager.setInitialPanelVisibility(for: wt.id)
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
        manager.setInitialPanelVisibility(for: wt.id)
        XCTAssertFalse(manager.isSecondaryVisible(for: wt.id), "precondition: secondary starts hidden")

        manager.revealSecondaryForHook(for: wt.id)
        XCTAssertTrue(manager.isSecondaryVisible(for: wt.id),
                      "the hook reveal must win over the open-on-start-off default")
    }

    // MARK: - First tab source

    func test_firstTabSource_afterCreatePickReplacesTheMainTerminalTab() {
        let pick = makeAgentCommand(name: "Review")
        XCTAssertEqual(
            TerminalManager.firstTabSource(afterCreateCommand: pick, mainCommand: "claude"),
            .savedCommand(pick),
            "the picked command is the first tab; the Main Terminal agent must not open beside it")
    }

    func test_firstTabSource_noPick_opensTheMainTerminalAgent() {
        XCTAssertEqual(
            TerminalManager.firstTabSource(afterCreateCommand: nil, mainCommand: "claude"),
            .mainTerminalAgent("claude"))
    }

    func test_firstTabSource_noPickAndNoMainTerminalCommand_opensALoginShell() {
        XCTAssertEqual(
            TerminalManager.firstTabSource(afterCreateCommand: nil, mainCommand: nil),
            .loginShell)
    }

    func test_firstTabSource_pickWinsWithNoMainTerminalCommand() {
        let pick = makeAgentCommand(name: "Review")
        XCTAssertEqual(
            TerminalManager.firstTabSource(afterCreateCommand: pick, mainCommand: nil),
            .savedCommand(pick))
    }

    func test_takeFirstTabSource_justCreatedWorktree_runsMainTerminalCommand() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)
        manager.mainCommandProvider = { "claude" }

        manager.markWorktreeCreated(wt, afterCreateCommand: nil)
        XCTAssertEqual(manager.takeFirstTabSource(for: wt.id), .mainTerminalAgent("claude"))
    }

    func test_takeFirstTabSource_justCreatedWorktree_carriesTheAfterCreatePick() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)
        let pick = makeAgentCommand(name: "Review")
        manager.mainCommandProvider = { "claude" }

        manager.markWorktreeCreated(wt, afterCreateCommand: pick)
        XCTAssertEqual(manager.takeFirstTabSource(for: wt.id), .savedCommand(pick))
    }

    func test_takeFirstTabSource_existingWorktree_opensLoginShell() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)
        manager.mainCommandProvider = { "claude" }

        XCTAssertEqual(manager.takeFirstTabSource(for: wt.id), .loginShell,
                       "a worktree Clearway did not create opens a login shell, whatever Main Terminal holds")
    }

    func test_takeFirstTabSource_justCreatedWorktree_mainTerminalNone_opensLoginShell() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)
        manager.mainCommandProvider = { nil }

        manager.markWorktreeCreated(wt, afterCreateCommand: nil)
        XCTAssertEqual(manager.takeFirstTabSource(for: wt.id), .loginShell)
    }

    func test_takeFirstTabSource_markIsOneShot() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)
        manager.mainCommandProvider = { "claude" }

        let pick = makeAgentCommand(name: "Review")
        manager.markWorktreeCreated(wt, afterCreateCommand: pick)
        XCTAssertEqual(manager.takeFirstTabSource(for: wt.id), .savedCommand(pick))
        XCTAssertEqual(manager.takeFirstTabSource(for: wt.id), .loginShell,
                       "closing a created worktree's terminals and reopening it is opening one that already exists")
    }

    func test_takeFirstTabSource_marksOneWorktreeOnly() {
        let manager = TerminalManager()
        let created = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)
        let other = makeWorktree(branch: "other", path: "/tmp/other", isMain: false)
        manager.mainCommandProvider = { "claude" }

        manager.markWorktreeCreated(created, afterCreateCommand: nil)
        XCTAssertEqual(manager.takeFirstTabSource(for: other.id), .loginShell)
        XCTAssertEqual(manager.takeFirstTabSource(for: created.id), .mainTerminalAgent("claude"))
    }

    /// Tearing a worktree's terminals down drops every other per-worktree entry, so the creation
    /// mark has to go with them: a worktree whose terminals were closed and then reopened is one
    /// that already exists, and must come back on a login shell rather than on a second agent.
    func test_removeSurface_clearsTheCreationMark() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)
        manager.mainCommandProvider = { "claude" }

        manager.markWorktreeCreated(wt, afterCreateCommand: nil)
        manager.removeSurface(for: wt.id)
        XCTAssertEqual(manager.takeFirstTabSource(for: wt.id), .loginShell,
                       "the creation mark must not survive the worktree's terminals")
    }

    // MARK: - buildAgentPromptCommand

    func test_buildAgentPromptCommand_usesPositionalPrompt_notStdinPipe() throws {
        let launch = try XCTUnwrap(buildAgentPromptCommand(agentCommand: "grok", prompt: "hello", path: testPath))
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }
        XCTAssertTrue(launch.command.contains("\"$(cat \"$2\")\""),
                      "prompt must be a positional arg via cat-into-quotes; got: \(launch.command)")
        XCTAssertFalse(launch.command.contains("cat \"$2\" | $1"),
                       "must not pipe prompt into agent stdin; got: \(launch.command)")
    }

    /// `$1` must stay bare in the recipe. Quoting it would make a multi-word command
    /// (`claude --model sonnet`) be looked up as one filename, so the launch would fail.
    func test_buildAgentPromptCommand_leavesTheAgentCommandExpansionUnquoted() throws {
        let launch = try XCTUnwrap(buildAgentPromptCommand(agentCommand: "claude", prompt: "x", path: testPath))
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }
        XCTAssertTrue(launch.command.contains("; $1 \""),
                      "the agent command must expand unquoted; got: \(launch.command)")
        XCTAssertFalse(launch.command.contains("\"$1\""),
                       "quoting $1 would run a multi-word command as one binary name; got: \(launch.command)")
    }

    /// The builder must export the PATH it was given, not one it reads for itself: the
    /// caller is the only place that knows whether a resolution has completed.
    func test_buildAgentPromptCommand_exportsTheGivenPath_andDisablesGlobbing() throws {
        let launch = try XCTUnwrap(buildAgentPromptCommand(agentCommand: "claude", prompt: "x", path: testPath))
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }
        XCTAssertTrue(launch.command.contains("export PATH=") && launch.command.contains("'\(testPath)'"),
                      "must export the given PATH; got: \(launch.command)")
        XCTAssertTrue(launch.command.contains("set -f"), "must disable globbing; got: \(launch.command)")
        XCTAssertTrue(launch.command.contains("rm -f \"$2\""),
                      "must clean up the prompt file after the agent exits; got: \(launch.command)")
    }

    func test_buildAgentPromptCommand_writesPromptFile_andQuotesAgentCommand() throws {
        let launch = try XCTUnwrap(buildAgentPromptCommand(
            agentCommand: "claude; rm -rf /",
            prompt: "do the work",
            path: testPath,
            filePrefix: "clearway-test-prompt"
        ))
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

    func test_buildAgentPromptCommand_keepsSpecialCharsInFile_notInShellString() throws {
        let prompt = "say \"hi\"\n$HOME `id` 'x'"
        let launch = try XCTUnwrap(buildAgentPromptCommand(agentCommand: "grok", prompt: prompt, path: testPath))
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

    func test_buildAgentPromptCommand_escapesSingleQuotes_inAgentCommand() throws {
        let launch = try XCTUnwrap(buildAgentPromptCommand(agentCommand: "weird'name", prompt: "x", path: testPath))
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }
        XCTAssertTrue(launch.command.contains("'weird'\\''name'"),
                      "single quotes in agent command must be shell-escaped; got: \(launch.command)")
    }

    func test_buildAgentPromptCommand_usesFilePrefix() throws {
        let launch = try XCTUnwrap(buildAgentPromptCommand(
            agentCommand: "grok",
            prompt: "p",
            path: testPath,
            filePrefix: "clearway-agent-tab"
        ))
        defer { try? FileManager.default.removeItem(atPath: launch.promptFile) }
        XCTAssertTrue(
            (launch.promptFile as NSString).lastPathComponent.hasPrefix("clearway-agent-tab-"),
            "prompt file name should use the prefix; got: \(launch.promptFile)"
        )
    }

    /// A prefix naming a directory that does not exist makes `FileManager.createFile` fail. The
    /// builder must answer `nil` there rather than hand back a command whose `$(cat)` would seed the
    /// agent with an empty prompt.
    func test_buildAgentPromptCommand_returnsNil_whenThePromptFileCannotBeWritten() {
        let missingDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-missing-dir-\(UUID().uuidString)")
        let launch = buildAgentPromptCommand(
            agentCommand: "claude",
            prompt: "do the work",
            path: testPath,
            filePrefix: "\((missingDir as NSString).lastPathComponent)/prompt"
        )
        XCTAssertNil(launch, "an unwritable prompt file must refuse the launch, not build a command")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDir),
                       "the builder must not create the directory it failed to write into")
    }

    // MARK: - buildAgentPromptLine

    /// The staged form of the same launch: the prompt stays in the temp file, so what lands on the
    /// prompt line is one short readable command whatever the prompt contains.
    func test_buildAgentPromptLine_keepsThePromptInTheFile_notInTheLine() throws {
        let prompt = "say \"hi\"\n$HOME `id` 'x'"
        let staged = try XCTUnwrap(
            buildAgentPromptLine(agentCommand: "claude", prompt: prompt, filePrefix: "clearway-test-line"))
        defer { try? FileManager.default.removeItem(atPath: staged.promptFile) }

        XCTAssertEqual(
            try? String(contentsOfFile: staged.promptFile, encoding: .utf8),
            prompt,
            "prompt file must preserve the body byte-for-byte"
        )
        XCTAssertFalse(staged.line.contains("$HOME"),
                       "prompt metacharacters must not reach the staged line; got: \(staged.line)")
        XCTAssertEqual(staged.line, "claude \"$(cat '\(staged.promptFile)')\"")
    }

    /// Same contract as the `/bin/sh -c` recipe: the agent command word-splits, the file does not.
    func test_buildAgentPromptLine_leavesTheAgentCommandUnquoted_andQuotesTheFile() throws {
        let staged = try XCTUnwrap(buildAgentPromptLine(agentCommand: "claude --model opus", prompt: "x"))
        defer { try? FileManager.default.removeItem(atPath: staged.promptFile) }

        XCTAssertTrue(staged.line.hasPrefix("claude --model opus \""),
                      "a multi-word agent command must stay unquoted; got: \(staged.line)")
        XCTAssertTrue(staged.line.contains("'\(staged.promptFile)'"),
                      "the prompt file must be single-quoted; got: \(staged.line)")
    }

    func test_buildAgentPromptLine_writesTheFileWithRestrictivePermissions() throws {
        let staged = try XCTUnwrap(
            buildAgentPromptLine(agentCommand: "grok", prompt: "p", filePrefix: "clearway-test-line"))
        defer { try? FileManager.default.removeItem(atPath: staged.promptFile) }

        let mode = try FileManager.default.attributesOfItem(atPath: staged.promptFile)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
        XCTAssertTrue((staged.promptFile as NSString).lastPathComponent.hasPrefix("clearway-test-line-"))
    }

    /// The staged form carries the run form's refusal: a line whose `$(cat)` names a file that was
    /// never written would seed the agent with an empty prompt the moment the operator presses
    /// Enter.
    func test_buildAgentPromptLine_returnsNil_whenThePromptFileCannotBeWritten() {
        let missingDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clearway-missing-dir-\(UUID().uuidString)")
        let staged = buildAgentPromptLine(
            agentCommand: "claude",
            prompt: "do the work",
            filePrefix: "\((missingDir as NSString).lastPathComponent)/prompt"
        )
        XCTAssertNil(staged, "an unwritable prompt file must refuse the staged line too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDir),
                       "the builder must not create the directory it failed to write into")
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
        XCTAssertFalse(out.contains("clearway-agent-tab-"),
                       "buildBareCommand must not allocate a prompt temp file; got: \(out)")
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

    /// A task-terminal launch awaits the resolved PATH before it has a surface, so nothing else
    /// marks the task as busy for that window. A second press must lose the claim rather than start
    /// a second agent — on a machine whose first resolution blocks, that window is seconds long.
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

    // MARK: - beginAgentLaunch

    /// An agent tab awaits the resolved PATH before it has a surface, so the worktree's pane has no
    /// tab for that window. A second Opt+Cmd+T must lose the claim rather than open a second agent.
    func test_beginAgentLaunch_secondClaimIsRefusedUntilTheFirstEnds() {
        let manager = TerminalManager()
        let worktreeId = "feature"

        XCTAssertTrue(manager.beginAgentLaunch(for: worktreeId))
        XCTAssertFalse(manager.beginAgentLaunch(for: worktreeId),
                       "a launch already in flight must refuse the second press")

        manager.endAgentLaunch(for: worktreeId)
        XCTAssertTrue(manager.beginAgentLaunch(for: worktreeId),
                      "the claim must be released once the launch has its tab")
    }

    /// The claim is per worktree: a launch in one must not block a launch in another.
    func test_beginAgentLaunch_claimsAreIndependentPerWorktree() {
        let manager = TerminalManager()

        XCTAssertTrue(manager.beginAgentLaunch(for: "feature"))
        XCTAssertTrue(manager.beginAgentLaunch(for: "main"))
    }

    /// The empty-state gate in `detailView` reads this set, so a claim has to be visible there —
    /// it is what keeps a worktree whose first tab is an agent from flashing the placeholder.
    func test_agentLaunchesInFlight_tracksTheClaimedWorktrees() {
        let manager = TerminalManager()

        XCTAssertTrue(manager.beginAgentLaunch(for: "feature"))
        XCTAssertTrue(manager.agentLaunchesInFlight.contains("feature"))

        manager.endAgentLaunch(for: "feature")
        XCTAssertFalse(manager.agentLaunchesInFlight.contains("feature"))
    }

    // MARK: - proceedsWithLaunch

    /// The four doors, as Decision 20 draws them. Row three is the one that already regressed: a
    /// saved agent command started during another launch's PATH wait opened nothing.
    func test_proceedsWithLaunch_onlyARefusingDoorLosesToAnotherLaunch() {
        XCTAssertTrue(TerminalManager.proceedsWithLaunch(ownsMarker: true, refuseWhenInFlight: true),
                      "Opt+Cmd+T with no launch in flight")
        XCTAssertFalse(TerminalManager.proceedsWithLaunch(ownsMarker: false, refuseWhenInFlight: true),
                       "a second Opt+Cmd+T during the wait is a repeat of the first")
        XCTAssertTrue(TerminalManager.proceedsWithLaunch(ownsMarker: false, refuseWhenInFlight: false),
                      "a door that does not refuse opens its tab even when another launch holds the marker")
        XCTAssertTrue(TerminalManager.proceedsWithLaunch(ownsMarker: true, refuseWhenInFlight: false))
    }

    // MARK: - promptDelivery

    /// Which builder an agent tab uses, and whether it stages afterwards. `submit` is the user's
    /// "Append Enter to run immediately" toggle, so reading it backwards runs a prompt they staged.
    func test_promptDelivery_submitOnlyMattersWithAPrompt() {
        XCTAssertEqual(TerminalManager.promptDelivery(prompt: "", submit: true), .bare,
                       "Opt+Cmd+T passes no prompt and must not build an empty argv element")
        XCTAssertEqual(TerminalManager.promptDelivery(prompt: "", submit: false), .bare)
        XCTAssertEqual(TerminalManager.promptDelivery(prompt: "review the diff", submit: true), .argv)
        XCTAssertEqual(TerminalManager.promptDelivery(prompt: "review the diff", submit: false), .staged)
    }

    // MARK: - stagedText

    /// Outside bracketed paste libghostty rewrites every `\n` to `\r`, which is an Enter, so a
    /// trailing newline on "staged" text submits it. The trim is what keeps staging staged.
    func test_stagedText_stripsTheNewlinesThatWouldSubmitIt() {
        XCTAssertEqual(TerminalManager.stagedText("review the diff\n"), "review the diff")
        XCTAssertEqual(TerminalManager.stagedText("\nreview the diff"), "review the diff")
        XCTAssertEqual(TerminalManager.stagedText("  review the diff \n\n"), "review the diff")
    }

    /// Only the ends are trimmed. An interior newline still reaches a target without bracketed
    /// paste as an Enter — unchanged from `sendPaste`, and not something a trim can fix.
    func test_stagedText_keepsInteriorNewlines() {
        XCTAssertEqual(TerminalManager.stagedText("\nfirst\n\nsecond\n"), "first\n\nsecond")
    }

    func test_stagedText_whitespaceOnlyReducesToEmpty() {
        XCTAssertEqual(TerminalManager.stagedText(" \n\t "), "")
        XCTAssertEqual(TerminalManager.stagedText(""), "")
    }

    func test_stagedText_leavesOrdinaryTextAlone() {
        XCTAssertEqual(TerminalManager.stagedText("review the diff"), "review the diff")
    }

    // MARK: - Task terminal fan-out

    func test_closeTaskTerminalInAllManagers_clearsTheTaskInEveryManager() {
        let first = TerminalManager()
        let second = TerminalManager()
        let taskA = UUID()
        let taskB = UUID()
        seedTaskTerminal(taskA, in: first)
        seedTaskTerminal(taskB, in: second)
        XCTAssertTrue(first.openTaskIds.contains(taskA))
        XCTAssertTrue(second.openTaskIds.contains(taskB))

        TerminalManager.closeTaskTerminalInAllManagers(taskA)

        for manager in [first, second] {
            assertNoTaskTerminal(taskA, in: manager)
        }
        XCTAssertTrue(second.openTaskIds.contains(taskB))
        XCTAssertEqual(second.taskTerminalVisible[taskB], true)
        XCTAssertEqual(second.taskTerminalHeights[taskB], 320)

        TerminalManager.closeTaskTerminalInAllManagers(taskB)

        assertNoTaskTerminal(taskB, in: second)
    }

    func test_taskHasActiveProcessInAnyManager_isFalseWithoutASurface() {
        let manager = TerminalManager()
        let task = UUID()
        seedTaskTerminal(task, in: manager)

        XCTAssertFalse(TerminalManager.taskHasActiveProcessInAnyManager(task))
        XCTAssertFalse(TerminalManager.taskHasActiveProcessInAnyManager(UUID()))
    }

    private func seedTaskTerminal(_ taskId: UUID, in manager: TerminalManager) {
        manager.openTaskIds.insert(taskId)
        manager.taskTerminalVisible[taskId] = true
        manager.taskTerminalHeights[taskId] = 320
    }

    private func assertNoTaskTerminal(
        _ taskId: UUID,
        in manager: TerminalManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(manager.taskSurfaces[taskId], file: file, line: line)
        XCTAssertFalse(manager.openTaskIds.contains(taskId), file: file, line: line)
        XCTAssertNil(manager.taskTerminalVisible[taskId], file: file, line: line)
        XCTAssertNil(manager.taskTerminalHeights[taskId], file: file, line: line)
    }
}
