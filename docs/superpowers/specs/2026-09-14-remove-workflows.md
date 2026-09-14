# Remove the workflow engine, autopilot, and the Workflow view

**Date:** 2026-09-14
**Base:** 92f0e661ccf2a880fd4e982e33df1184d7d7d9fc

Clearway currently ships an agent orchestration engine: a project drops a `.clearway/WORKFLOW.json`
describing a graph of actions, and Clearway watches each worktree's `TASK.md`, launches an agent per
action, and advances the loop when the agent writes the next slug into the task's frontmatter. That
job has moved out of the terminal app and into the agents themselves — a single orchestrating agent
now fans work out to sub-agents, which is cheaper in tokens and runs unattended for longer. This
change removes the whole engine and everything that existed only to serve it: the `WORKFLOW.json`
model and editor, the loop engine and its watcher, autopilot, step badges, the per-entry agent and
model resolution, the planning prompt, and the sidebar's Workflow destination. What remains is what
Clearway was underneath: a worktree manager with terminals, a task backlog, and per-project hooks.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What sets a task's status once a worktree exists? | **Start Now** writes `status = in_progress`. No status picker is restored in the task aside; a worktree task then sits on `in_progress` with no in-app way to change it. The Ready to Start toggle, the status badges, and the labels for the legacy fixed states all stay. | Operator |
| 2 | What happens to `autopilot` and `completed` in `TASK.md`? | Both leave the `WorkTask` model and the frontmatter entirely, so they vanish from a `TASK.md` on its next write. An unknown `status` slug left behind by an old workflow is displayed as-is (`humanize`). `.clearway/WORKFLOW.json` is simply never read again: no warning, no migration, no deletion. | Operator |
| 3 | Does the Plan button survive? | No. It goes, and with it `planning.instructions` as a feature. The **Planning bottom panel itself stays**: Cmd+J and the panel-toggle toolbar icon still open the per-task terminal, running Settings → Main Terminal or a login shell. | Operator |
| 4 | Which hooks survive? | `WORKFLOW.json`'s `hooks.after_create` goes. The independent per-project `WorktreeHooks` (`afterCreate` / `beforeRemove` — the operator's "post_create / pre_remove", edited in the worktree settings sheet) stays. `scripts/worktree-post-create.sh` is this repo's own dev bootstrap and is unrelated to both. | Operator |
| 5 | Which agent-launch helpers survive? | `agentAllowlist` stays — Settings → Main Terminal's picker renders from it. `buildAgentPromptCommand` stays (prompt launcher). `resolveAgentCommand`, `applyModel`, `agentsAcceptingModelFlag`, `isModelValueSafe` and `isAllowlistedAgentCommand` go: verified below that they have no non-workflow caller. | Operator + verified |
| 6 | What happens to Ctrl-3? | Retired with no alias. The sidebar loses its Workflow row, the Ctrl+digit claim range narrows to 1…2, and `AppKeyboardShortcutsTests` gains a not-claimed pin for Ctrl+3 following the existing "Retired shortcuts" convention. | Operator |
| 7 | `WorkTaskAgentMetadata` fields? | `errorMessage` was written only by engine paths and by `handleChildExited` (which itself only ever fired for engine-launched surfaces) — it goes, from the view, the model, and the frontmatter. `attempt` keeps its writer (`startTask`'s restart-after-cancel increment) and stays. | Operator + verified |
| 8 | Docs? | Remove every workflow / autopilot / `WORKFLOW.json` / per-entry agent-and-model section from README and CLAUDE.md. Facts inside those sections that remain true of surviving code must be rehomed, not lost. | Operator |
| 9 | Do `WorkTaskManager.onTasksReloaded`, `onClearwayChanged` and the root `.clearway/` watcher survive? | No. All three exist only to drive or feed the engine (verified: their sole consumers are `WorkTaskCoordinator`'s engine wiring). The debounced reload itself stays — it is what keeps `tasks` fresh — but it notifies nobody. | Spec author |
| 10 | Does the agent-surface bookkeeping on `WorkTaskCoordinator` survive? | No. `agentSurfaces`, `agentSurfaceIdentities`, `launchPromptFiles`, `setAgentSurface`, `isAgentSurface`, `handleMainTabClosed`, `handleChildExited`, `shouldClearLiveAgentState`, the `.ghosttyChildExited` observer and `appProvider` are populated **only** by `launchWorkflowAgent`. With the engine gone they are permanently empty, so `TerminalManager.skipAutoRestart` and `onMainTabClosed` go with them. | Spec author |
| 11 | Does `TerminalTab.launcherCommand` survive? | No. Its only writer is `runWorkflowAction`'s stamp; `ContentView` then falls back to `settings.resolvedMainTerminalCommand` for every surviving tab. Field, init parameter, `appendLauncherTab(command:)` parameter and the `command == nil` promotion gate all go. | Spec author |
| 12 | Does `WorkTask.ReservedStatus.legacyOrdered` survive? | No. It has zero readers in `Sources/` and `Tests/`; its doc ties it to the already-retired `WORKFLOW.md` template variables. It is engine residue and is removed in this change. | Spec author |

## Assumptions

Each verified against the tree at the base commit. Empirical probing was not needed; everything below
is a direct read or grep of the repo (no probe scripts were written, into the repo or the scratchpad).

1. **`resolveAgentCommand` has no non-workflow caller.** Callers: `WorkTaskCoordinator.swift:180`
   (`planningAgentCommand`), `:194` (`workflowAgentCommand(for:action:)`), `WorkflowEditorView.swift:188`
   and `:215`. All four die with this change.
2. **`applyModel` / `isModelValueSafe` likewise.** `applyModel`: `WorkTaskCoordinator.swift:179`, `:193`.
   `isModelValueSafe`: `WorkflowEditorDetailForms.swift:158`. `isAllowlistedAgentCommand`:
   `WorkflowEditorDetailForms.swift:130`. `agentsAcceptingModelFlag` is `private` to `AgentLaunch.swift`
   and read only by `acceptsModelFlag`, itself read only by `applyModel`.
3. **`agentAllowlist` has a surviving reader.** `SettingsView.swift:11` renders the Main Terminal
   picker rows from it. (Its other reader, `WorkflowEditorDetailForms.swift:113`/`:117`, dies.)
4. **`buildAgentPromptCommand` has a surviving reader.** `TerminalManager+Launcher.swift:38`
   (`promoteLauncherToAgent`, the prompt launcher's submit path). Its other two callers —
   `WorkTaskCoordinator+WorkflowEngine.swift:637` and `WorkTaskCoordinator+Planning.swift:59` — die.
5. **`buildBareCommand` has a surviving reader.** `TerminalManager+Launcher.swift:33` and
   `WorkTaskCoordinator+Planning.swift:75` (the Planning terminal's bare-command path, which survives).
6. **`runHookInSecondary` / `revealSecondaryForHook` survive.** Single call site,
   `ContentView.swift:316`, whose command is `WorktreeHooks.chainCommands(projectHookCmd, workflowHookCmd)`.
   `projectHookCmd` comes from `worktreeManager.hookCommand(\.afterCreate, …)` — the per-project
   `WorktreeHooks` feature (`Sources/App/WorktreeHooks.swift`), which is independent of `WORKFLOW.json`.
   Only `workflowHookCmd` (`WorkTaskCoordinator.workflowAfterCreateHook()`) goes.
7. **`WorktreeHooks.chainCommands` loses its reason to exist.** After (6) there is exactly one command,
   so `chainCommands` has no caller (`Sources/App/WorktreeHooks.swift:29`; sole call site
   `ContentView.swift:315`).
8. **`TerminalManager.terminateSurface` has no surviving caller.** Sole call site is
   `WorkTaskCoordinator+WorkflowEngine.swift:232` (`TerminalManager+TaskTerminals.swift:102`).
9. **`WorkTaskManager.freshStatus` has no surviving caller.** Sole call site is
   `WorkTaskCoordinator+WorkflowEngine.swift:373` (`pauseIfAgentDiedMidStep`).
10. **`WorkTaskManager.onTasksReloaded` / `onClearwayChanged` have no surviving consumers.** Both are
    assigned only in `WorkTaskCoordinator.init` (`:220`, `:229`) and fired only from
    `WorkTaskManager.reload()` (`:391`, `:408`).
11. **The root `.clearway/` watcher exists only for `WORKFLOW.json`.** `WorkTaskManager.swift:14-21`
    documents it as such; `rootClearwayDirectory` (`:61`) is watched by `watchRootClearway()` (`:518`),
    re-armed at `:355`, cancelled at `:122`. The central `tasks/` watcher (`:509`) and the per-worktree
    `.clearway/` watchers are separate and survive.
12. **`WorkTaskCoordinator.agentSurfaces` and friends are populated only by the engine.**
    `setAgentSurface` is called once, at `WorkTaskCoordinator+WorkflowEngine.swift:651`;
    `agentSurfaceIdentities` is inserted into once, at `:652`; `launchPromptFiles` once, at `:653`.
13. **`TerminalManager.skipAutoRestart` and `onMainTabClosed` are wired only to the coordinator's
    agent-surface answers.** `ProjectWindow.swift:118` and `:121`. With (12) they are constant
    `false` / no-op.
14. **`TerminalTab.stepSlug` is written only through `currentWorkflowStepProvider`.**
    `TerminalManager.swift:192` inside the private `makeTab`; provider wired at `ContentView.swift:385`.
    Read at `MainTerminalTabStrip.swift:144` and `:204`.
15. **`TerminalTab.launcherCommand` is written only by the engine.** `appendLauncherTab`'s `command:`
    argument (`TerminalManager.swift:395`) is non-nil only from `runWorkflowAction`. Read at
    `ContentView.swift:817`.
16. **`PressableCardButtonStyle` is workflow-only.** Declared `WorkflowActionCard.swift:78`, used only
    at `WorkflowEditorView.swift:240`, `:245`, `:348`.
17. **`WorkTask.ReservedStatus.legacyOrdered` has zero readers.** Declared `WorkTask.swift:72`; no other
    hit in `Sources/` or `Tests/`.
18. **A shadow/exposed task already defaults to `in_progress`.** `WorkTaskManager.createShadowTask`
    (`:167`) and `createExposedTask` (`:189`) both construct with `ReservedStatus.inProgress`, so
    decision 1 makes `startTask` agree with the paths that already exist rather than inventing a state.
19. **`.github/workflows/*.yml` hits are GitHub Actions vocabulary.** Both files' only match is the
    reserved `${{ github.workflow }}` context expression used to name a concurrency group; neither
    references the app feature. `scripts/ci.sh:2` mentions `.github/workflows/ci.yml` by filename.
20. **`ARCHITECTURE.md`, `website/`, `Resources/` and `project.yml` contain no workflow references.**
    `project.yml` globs `Sources` and `Tests` as directories (`:26`, `:304`), so deleted files need no
    manifest edit — only `xcodegen generate`, which `scripts/ci.sh` runs.
21. **This repo has no `.clearway/WORKFLOW.json`.** Its `.clearway/` holds only a git-ignored `TASK.md`.
22. **`WorkTask.hasContent` has no surviving reader.** Two call sites:
    `WorkTaskCoordinator+WorkflowEngine.swift:432` (the seed's autopilot default) and
    `AutopilotButton.swift:51`. Not to be confused with the *static*
    `WorkTaskAgentMetadata.hasContent(for:)`, which survives.
23. **Deleting `AgentLaunchModelTests.swift` loses no coverage of `buildAgentPromptCommand`.**
    `TerminalManagerTests.swift:93`–`:175` holds six tests on it, including the shape invariants
    (`writesPromptFile_andQuotesAgentCommand` with a `claude; rm -rf /` command,
    `keepsSpecialCharsInFile_notInShellString`, `escapesSingleQuotes_inAgentCommand`). Only the
    `applyModel`-specific "a model value stays one argv word" test dies, along with `applyModel`.

## Objective

Delete the agent-orchestration feature from Clearway, leaving no dead seam, provider, cached
definition, notification hook, test-only launcher or vestigial field behind.

### Success criteria

1. `./scripts/ci.sh` passes: `xcodegen generate`, `swiftlint lint --quiet` with zero errors, build, and
   the full test suite green.
2. The app builds and runs with: a sidebar of Planning / Prompts / worktrees (no Workflow row); Ctrl+1
   and Ctrl+2 reaching their destinations and Ctrl+3 reaching the shell; Cmd+J opening the Planning
   terminal on the Planning destination and the secondary terminal on a worktree; the task aside
   showing the task card and agent metadata with no step cards and no Autopilot row; main terminal tab
   chips with no step badge.
3. **Start Now** on a backlog task creates the worktree, relocates `TASK.md` into it, runs the project's
   `WorktreeHooks` after-create hook in the secondary terminal, and leaves the task on `in_progress`.
   No agent is launched by Clearway.
4. A `TASK.md` that previously carried `autopilot:` / `completed:` / `error_message:` loses those lines
   on its next write, and its other fields round-trip unchanged.
5. A task left on an unknown slug (e.g. `work_breakdown`) still renders — humanized label, green badge —
   and is not treated as an error.
6. **The grep audit** (below) returns only allow-listed hits.

### Grep audit (hard acceptance criterion)

Run over tracked files only, from the repo root:

```bash
git ls-files -z | grep -zv '^ghostty/' \
  | xargs -0 grep -nE 'workflow|Workflow|WORKFLOW|autopilot|Autopilot|stepSlug|launcherCommand|runningAction'
```

Allowed hits, and nothing else:

| Path | Why it stays |
| --- | --- |
| `.github/workflows/ci.yml`, `.github/workflows/build-ghosttykit.yml` | GitHub Actions' own `${{ github.workflow }}` context expression, plus the directory name itself. |
| `scripts/ci.sh:2` | Comment naming `.github/workflows/ci.yml`. |
| `CLAUDE.md` `## Pipeline` section | Documents the `/work` pipeline for this repo; unrelated to the app feature. |
| `docs/superpowers/specs/2026-09-14-remove-workflows.md`, `docs/superpowers/plans/2026-09-14-remove-workflows.md` | This spec and its plan, which name the thing being removed. |

A second, narrower sweep must return **nothing at all** — these are the seams and helpers that only
ever existed for the engine, and any hit is a leftover:

```bash
git ls-files -z -- Sources Tests | xargs -0 grep -nE \
  'resolveAgentCommand|applyModel|isModelValueSafe|isAllowlistedAgentCommand|agentsAcceptingModelFlag|PlanningConfig|planningInstructions|chainCommands|terminateSurface|freshStatus|onTasksReloaded|onClearwayChanged|setAgentSurface|agentSurfaces|skipAutoRestart|onMainTabClosed|legacyOrdered|error_message|errorMessage|seedWorkflowStatus|hasContent\b(?!\()'
```

(`WorkTaskAgentMetadata.hasContent(for:)` survives and is the one `hasContent` that may remain; the
`WorkTask` computed property does not — check the two apart by hand rather than trusting the regex.)

Untracked/ignored paths (`.clearway/`, `.work/`, `Clearway.xcodeproj/project.pbxproj`) are outside the
audit by construction: `project.pbxproj` is regenerated by `xcodegen generate` and must never be
hand-edited; `.clearway/TASK.md` and `.work/state.json` are live runtime state. Confirm separately that
`git status --porcelain` is clean before sign-off (per CLAUDE.md's Pipeline section; expect the
un-gitignored `default.profraw` after any Debug launch).

## Verification commands

From `CLAUDE.md`'s `## Pipeline` section — one command serves as both the regression check and the full
gate, because it is the only runner of the test suite and the only thing that runs `xcodegen generate`
(without which added or deleted Swift files are invisible to the build):

```bash
./scripts/ci.sh
```

Do not substitute a hand-written `xcodebuild` line: `build.sh`'s `PRODUCT_NAME` override breaks
`TEST_HOST`.

## Files this change touches

### Deleted outright — `Sources/App/` (11 files, ~2 100 lines)

| File | What it is |
| --- | --- |
| `WorkflowDefinition.swift` | The `WORKFLOW.json` Codable model, `load`/`loadRaw`/`validate`, `hasJSONWorkflow`. |
| `WorkflowLoopEngine.swift` | The pure `decideTransition` / `buildPrompt` engine. |
| `WorkTaskCoordinator+WorkflowEngine.swift` | All stateful engine plumbing, `WorkflowCountdown`, `WorkflowLaunchID`, `WorkflowAdvanceResult`. |
| `WorkflowEditorView.swift` | The editor screen (and `PressableCardButtonStyle`'s only consumer). |
| `WorkflowEditorModel.swift` | The editor's in-memory model and (de)serialization. |
| `WorkflowEditorDetailForms.swift` | Action/planning detail forms and the shared `workflow*Field` helpers. |
| `WorkflowActionCard.swift` | Editor action row + `PressableCardButtonStyle`. |
| `WorkflowSidebarActionCard.swift` | Aside step card + `CountdownRing`. |
| `WorkflowStepBadge.swift` | Tab-chip step badge. |
| `AutopilotButton.swift` | The Autopilot row. |
| `PlanningConfig.swift` | `renderPlanningPrompt` and its `{{ task.* }}` template renderer. |

### Deleted outright — `Tests/` (15 files)

`WorkflowAgentLaunchTests`, `WorkflowAgentSupersedeHarnessTests`, `WorkflowCompletionHarnessTests`,
`WorkflowCountdownHarnessTests`, `WorkflowDefinitionModelTests`, `WorkflowDefinitionTests`,
`WorkflowEditorModelTests`, `WorkflowLoopEngineHarnessTests`, `WorkflowLoopEngineTests`,
`WorkflowModelLaunchTests`, `WorkflowSidebarActionTests`, `WorkflowStepTaggingHarnessTests`,
`PlanningConfigTests`, `AgentLaunchAgentTests`, `AgentLaunchModelTests`.

### Edited — `Sources/App/`

**`WorkTaskCoordinator.swift`** — the largest single edit. Remove:
- the entire `// MARK: - WORKFLOW.json Loop Engine` block (`runningAction`, `launchGeneration`,
  `engineHalted`, `lastKnownAutopilot`, `appProvider`, `workflowAgentLauncher`, `launcherTabAppender`,
  `workflowCountdowns`, `countdownWorkItems`, `workflowCountdownScheduler`, `countdownDuration`);
- the caches and their refresh (`isWorkflowJSONProject`, `workflowDefinition`, `rawWorkflowDefinition`,
  `refreshWorkflowJSONGate`), `planningInstructions`, `planningAgentCommand`, `workflowAgentCommand`,
  `workflowAfterCreateHook`;
- the whole agent-surface subsystem per decision 10: `agentSurfaces`, `setAgentSurface`,
  `agentSurfaceIdentities`, `launchPromptFiles`, `isAgentSurface`, `handleMainTabClosed`,
  `handleChildExited`, `shouldClearLiveAgentState`, `exitObserver` and its `.ghosttyChildExited`
  registration, and the surface/prompt-file cleanup inside `handleWorktreeRemoved`;
- the `onTasksReloaded` / `onClearwayChanged` assignments and the `refreshWorkflowJSONGate()` seed in `init`.

Change: `startTask` writes `updated.status = WorkTask.ReservedStatus.inProgress` (decision 1) and drops
`updated.errorMessage = nil` (decision 7). `completePendingLaunch` keeps the relocation. `exposeTask`
and `createTask(forBranch:)` existed only to call `seedWorkflowStatus` after the manager call — delete
both and have `TaskAsideView` call `workTaskManager.expose` / `workTaskManager.createExposedTask`
directly. Rewrite the type's doc comment, which currently opens "Coordinates the task launch workflow".

**`WorkTaskCoordinator+Planning.swift`** — `planningLaunchCommand` loses its `planningInstructions`
branch (and with it the `PlanningConfig` + `buildAgentPromptCommand` + `planLogger` path), leaving the
`mainCommandProvider` → `buildBareCommand` path and the `nil` (plain shell) path. `planTask` is
otherwise unchanged.

**`WorkTask.swift`** — remove `autopilot`, `completed`, `errorMessage` (properties, the three
`frontmatterLines()` emissions, the three `parse` assignments), `ReservedStatus.legacyOrdered`
(decision 12), and the `hasContent` computed property (assumption 22). Rewrite the `status` doc comment, which
currently describes the slug-from-`WORKFLOW.json` contract, to say: a reserved backlog marker, one of
the fixed states, or an arbitrary slug left by an external writer, displayed via `displayLabel`.

**`WorkTaskManager.swift`** — remove `onTasksReloaded`, `onClearwayChanged` and both their firings in
`reload()`; remove `freshStatus`, `setAutopilot`, `rootClearwayDirectory`, `rootClearwayWatcherSource`,
`watchRootClearway()` and its re-arm/cancel sites. Verify the `tasks/` watcher still re-arms from
`write()` once `.clearway/tasks` first appears.

**`WorkTaskAgentMetadata.swift`** — drop the `errorMessage` display and the `|| task.errorMessage != nil`
clause in `hasContent(for:)`. What remains is the attempt label (keep, decision 7); collapse the now
single-child `HStack`.

**`ContentView.swift`** — remove `DetailSelection.workflow` and its arm in `bottomPanelAction`; the
hidden Ctrl-3 button; the `currentWorkflowStepProvider` and `appProvider` wiring in `onAppear`; the
`seedWorkflowStatus` call and `workflowHookCmd` / `chainCommands` in the `lastCreatedBranch` handler
(keeping the `projectHookCmd` → `runHookInSecondary` call, now `if let cmd = projectHookCmd`); the
`.workflow` detail-view branch; the `isWorkflowJSONProject:` argument in `restoreSidePanelTab`; and the
`activeTab.launcherCommand ??` fallback, which becomes `settings.resolvedMainTerminalCommand`.

**`ContentViewHelpers.swift`** — drop `resolveSidePanelTab`'s `isWorkflowJSONProject` parameter and its
branch; reword `SidePanelTab.available`'s doc comment ("never drives a workflow loop").

**`SidebarView.swift`** — delete `workflowRow` and its reference in the list body.

**`TaskAsideView.swift`** — delete the `workflowDefinition` gate, the step-cards block, the
`AutopilotButton` block, `workflowActionCards(for:definition:)` and `countdown(for:)`. Retarget
`ensureShadowTask` / Create Task to the manager per the `WorkTaskCoordinator` note above.

**`WorkTaskListView.swift`** — collapse the Plan button to its icon form (decision 3), dropping the
`planningInstructions` branch and retitling the help to the panel-toggle wording; delete
`WorkTaskCard.isTerminalAction`; drop `WorkTaskStatusBadge.isTerminalAction` and the parameter on
`badgeColor(for:isTerminalAction:)`, whose `default:` arm becomes `.green`.

**`MainTerminalTabStrip.swift`** — delete the `WorkflowStepBadge` render, the `stepName` parameter on
`TabChip` / `TerminalTabChip` and both call-site arguments, `stepName(for:)`, `badgedChipMinWidth` and
its ternary, and the now-unused `workTaskCoordinator` `@EnvironmentObject`.

**`TerminalTab.swift`** — delete `stepSlug` and `launcherCommand` (decision 11) and their init parameters.

**`TerminalManager.swift`** — delete `currentWorkflowStepProvider`, the `stepSlug:` argument in
`makeTab`, `makeTab`'s `launcherCommand:` parameter, `appendLauncherTab`'s `command:` parameter and the
`command == nil` clause in the login-shell promotion gate at `:419`, plus `skipAutoRestart` and
`onMainTabClosed` and their consumers at `:523`, `:552`, `:568`, `:635`.

**`TerminalManager+TaskTerminals.swift`** — delete `terminateSurface` (assumption 8).

**`ProjectWindow.swift`** — delete the `skipAutoRestart` and `onMainTabClosed` wiring in `onAppear`.

**`AppKeyboardShortcuts.swift`** — narrow the Ctrl+digit claim to `"1"…"2"` and update its comment.

**`AgentLaunch.swift`** — delete `isAllowlistedAgentCommand`, `allowlistedAgent`, `resolveAgentCommand`,
`agentsAcceptingModelFlag`, `applyModel`, `isModelValueSafe`, `acceptsModelFlag`. Keep `agentAllowlist`
and `buildAgentPromptCommand`, rewriting both doc comments to drop `WORKFLOW.json` (the allowlist's new
sole job is rendering Settings → Main Terminal's picker rows; `buildAgentPromptCommand`'s ARG_MAX note
should name the launcher rather than "Plan / workflow prompts").

**`WorktreeHooks.swift`** — delete `chainCommands` (assumption 7).

### Edited — `Tests/`

| File | Change |
| --- | --- |
| `TestHelpers.swift` | Delete `WorkflowHarnessTestCase` (lines 44–193) entirely. Keep `makeWorktree` and `TempRootTestCase`. |
| `PlanningLaunchCommandTests.swift` | Delete `testPlanningInstructionsWinOverTheMainTerminalCommand`; rebase the class onto `TempRootTestCase` with an inlined coordinator builder so the two surviving tests keep covering the Planning terminal's command choice, which survives intact — `testBareMainTerminalCommandWhenNoPlanningInstructions` (rename: there are no planning instructions any more) and `testNoConfiguredCommandOpensAPlainShell`. Do not delete the file: these two pin behaviour that stays. |
| `AppKeyboardShortcutsTests.swift` | `testControlDigitIsClaimed` asserts `"2"` not `"3"`; `testControlDigitToleratesStrayShiftOrOption` uses `"2"`; `testControlDigitBeyondTheSidebarDestinationsIsNotClaimed` gains `"3"`; add a Ctrl+3 pin under `// MARK: - Retired shortcuts` following the `testRetiredCommandControlDigitsAreNotClaimed` convention. |
| `SidePanelTabTests.swift` | There is no Workflow *tab* — the coupling is `resolveSidePanelTab`'s `isWorkflowJSONProject` gate. Delete `testJSONProjectNoStoredTabSelectsTaskForAnyStatus` and `testMainClampsJSONDefaultToTodos`. Rewrite three whose expected value came from that gate: `testStoredTabBeatsJSONProjectRule` (retarget to "a stored tab wins over the status rule"), `testInvalidStoredRawValueFallsThrough` (expects `.task` only because the gate was `true` — re-express against `taskStatus: in_progress`), and `testPersistedNotesTabFallsBackToValidTab` (drop its JSON half, keep the non-JSON half). Drop the `isWorkflowJSONProject:` argument from every remaining call. |
| `BottomPanelActionTests.swift` | Drop `action(.workflow)` from `testDestinationsWithoutABottomPanelGetNothing`. |
| `TerminalTabKindTests.swift` | Delete `testLauncherCommandIsUnsetUnlessStamped`; drop `stepSlug:` from the `TerminalTab` constructions at `:50` and `:57`. |
| `WorkTaskTests.swift` | Delete `testAutopilotRoundTrips`, `testCompletedRoundTrips`, `testFileWithoutCompletedFieldParsesToNil`, `testFileWithoutAutopilotFieldParsesToNil`. Add one test pinning decision 2: a `TASK.md` carrying `autopilot:`/`completed:`/`error_message:` parses, and re-serializing drops those three lines while preserving the rest. `testArbitrarySlugRoundTrips` and `testDisplayLabels` stay (decision 2's display-as-is rule). |
| `WorkTaskManagerTests.swift` | Delete the `setAutopilot` staleness test and `testReloadNoOpDoesNotFireOnTasksReloaded`; rebase the two `onTasksReloaded` observers (`:555`, `:608`) onto assertions about `manager.tasks`. |
| `WorkTaskManagerWatcherTests.swift` | Rebase `:57`/`:76` off `onTasksReloaded` onto an expectation driven by `manager.tasks` so the debounced file-watcher reload stays covered. |
| `WorkTaskCoordinatorTests.swift` | Delete `testRawCacheHoldsPlanningWithoutEnablingGate`, `testRawAndValidatedCacheBothPresentForRealWorkflow`, and the private `makeCoordinator(workflowJSON:)` helper (`:54`–`:66`) they alone use. Extend `testStartTaskUsesFreshDiskContentNotStaleSnapshot`, or add a sibling, pinning decision 1: `startTask` writes `in_progress`. |
| `WorktreeHooksTests.swift` | Delete the four `chainCommands` tests (`:78`–`:95`). |

### Edited — docs

**`README.md`** — delete lines 56–166 (`## Task workflows (.clearway/WORKFLOW.json)` and all of its
subsections). Replace with a short `## Tasks` section that rehomes the three facts that section was the
only home for: (a) starting a task creates a worktree and opens a terminal — Clearway launches no agent
on its own and the status is yours to drive; (b) the agent CLIs Clearway knows (`claude`, `grok`,
`codex`) and that Settings → Main Terminal picks the default; (c) Ctrl-C in an agent's terminal, or
closing its tab, ends it. Everything else in the deleted span (actions, routes, slugs, hooks, planning
templates, per-entry models, the context block, autopilot) has no surviving analog and is dropped.

**`CLAUDE.md`** — delete lines 166–394 (`## Workflow engine` through `### Loop guard / stopping a step`).
Surgical edits elsewhere:
- L127: `task/worktree/workflow logic` → `task/worktree logic`.
- L136-139 (`AppKeyboardShortcuts.swift` bullet): add Ctrl+3 to the retired-shortcut pin list, keeping
  the existing distinction between a shortcut the app once owned and a SwiftUI default dropped as
  collateral.
- Add, in the `Sources/App/` bullet list, the facts rehomed out of the deleted section that still
  describe live code: `agentAllowlist` as the single source of Settings → Main Terminal's picker rows;
  `buildAgentPromptCommand`'s unquoted `$1 "$(cat "$2")"` expansion and the word-splitting consequence
  (a security-adjacent gotcha that survives with the launcher); and `appendLauncherTab`'s promotion to
  a login shell when Main Terminal is "None", stated without the stamped-tab exemption.
- Leave untouched: the `## Concurrency` section (including `ClaudeSessionFiles.makeWatcher` and
  `ScheduledWork`), the `PanelCommands.swift` bullet's `PanelToggle` nil-gate rule and its Planning
  bottom panel example (the panel survives, decision 3), and the `## Pipeline` section.
- The step-badge chip-colour note (L379-381) dies with `WorkflowStepBadge`; no chip carries a badge
  afterwards, so there is nothing to rehome it onto.

`ARCHITECTURE.md`, `website/`, `project.yml`, `Resources/`, `.github/workflows/` and `scripts/` need no
edits (assumptions 19–20).

## Out of scope

- **Migrating or deleting anyone's `.clearway/WORKFLOW.json`.** The file is simply never read (decision 2).
- **Restoring a status picker** anywhere in the UI (decision 1).
- **Renaming `planTask` / `planningLaunchCommand` / `DetailSelection.planning` / `planningTerminalOpened`.**
  "Planning" still names the backlog destination and the per-task terminal; only the planning *agent*
  goes. Renaming would churn surviving surfaces for no behavioural gain.
- **`WorktreeGroupStore.openFileWatcher`'s known fd leak** (CLAUDE.md, `Sources/App/` bullet list) —
  pre-existing and unrelated; it still needs its own task.
- **`agentAllowlist`'s contents.** The three names stay as they are; only the second list
  (`agentsAcceptingModelFlag`) is removed, and with it the two-lists-with-separate-contracts rule.
- **Any change to the Prompts feature, the Todos panel, worktree groups, or the Ghostty wrappers.**
