# Plan: Remove the workflow engine, autopilot, and the Workflow view

**Date:** 2026-09-14
**Base:** 92f0e661ccf2a880fd4e982e33df1184d7d7d9fc

Breaks down `docs/superpowers/specs/2026-09-14-remove-workflows.md`. Every design decision is settled
there; read it before starting a task, and read this file for what your task is and how it is checked.

## Architecture decisions carried from the spec

1. **Start Now writes `status = in_progress`.** No status picker is restored anywhere; the Ready to
   Start toggle, the status badges and the legacy fixed-state labels all stay. (Decision 1)
2. **`autopilot`, `completed` and `error_message` leave the model and the frontmatter**, so they
   vanish from a `TASK.md` on its next write. An unknown status slug is displayed as-is via
   `humanize`; `.clearway/WORKFLOW.json` is simply never read again — no warning, no migration, no
   deletion. (Decisions 2, 7)
3. **The Plan *button* and the planning agent go; the Planning bottom panel stays.** Cmd+J and the
   panel-toggle icon still open the per-task terminal on Settings → Main Terminal or a login shell.
   (Decision 3)
4. **Per-project `WorktreeHooks` (`afterCreate` / `beforeRemove`) survives**; `WORKFLOW.json`'s
   `hooks.after_create` goes, and with it `WorktreeHooks.chainCommands` (one command remains, so
   there is nothing to chain). (Decision 4, assumption 7)
5. **`agentAllowlist` and `buildAgentPromptCommand` survive** (Settings → Main Terminal's picker rows;
   the prompt launcher's submit path). `resolveAgentCommand`, `applyModel`, `agentsAcceptingModelFlag`,
   `isModelValueSafe`, `acceptsModelFlag`, `isAllowlistedAgentCommand` and `allowlistedAgent` go.
   (Decision 5)
6. **Ctrl+3 is retired with no alias**; the Ctrl+digit claim narrows to `"1"…"2"` and gains a
   not-claimed pin in `AppKeyboardShortcutsTests`. (Decision 6)
7. **The agent-surface bookkeeping is engine-only and goes wholesale** — `agentSurfaces`,
   `agentSurfaceIdentities`, `launchPromptFiles`, `isAgentSurface`, `handleMainTabClosed`,
   `handleChildExited`, `shouldClearLiveAgentState`, the `.ghosttyChildExited` observer, `appProvider`,
   and with them `TerminalManager.skipAutoRestart` / `onMainTabClosed`. (Decision 10)
8. **`TerminalTab.stepSlug` and `TerminalTab.launcherCommand` go**, along with every seam that fed
   them: `currentWorkflowStepProvider`, `makeTab`'s `launcherCommand:`, `appendLauncherTab`'s
   `command:`, and the `command == nil` clause in the login-shell promotion gate. (Decisions 11, 14, 15)
9. **`WorkTaskManager`'s engine feeds go** — `onTasksReloaded`, `onClearwayChanged`, `freshStatus`,
   `setAutopilot` and the root `.clearway/` watcher. The debounced reload itself stays; it notifies
   nobody. The `tasks/` watcher and the per-worktree `.clearway/` watchers are separate and survive.
   (Decision 9, assumption 11)
10. **Renaming is out of scope.** `planTask`, `planningLaunchCommand`, `DetailSelection.planning` and
    `planningTerminalOpened` keep their names: "Planning" still names the backlog destination and the
    per-task terminal.

## Verification

Every task's regression check is the same single command, run from the repo root **after the last
edit**:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project (without which added or deleted Swift files are invisible to the
build), lints, builds, and runs the test suite. Never substitute a hand-written `xcodebuild` line —
`build.sh`'s `PRODUCT_NAME` override breaks `TEST_HOST`. Deleted and added files need no `project.yml`
edit: it globs `Sources` and `Tests` as directories.

Each task must leave the tree building and green on its own. The ordering below exists for exactly
that reason: a task never deletes a declaration whose callers are still standing.

## Dependency graph

```
T1 Workflow sidebar destination + editor ─┐
T2 Step badge on terminal tabs ───────────┤
T3 Planning agent ────────────────────────┼──> T6 Loop engine + coordinator state ──┬──> T7 Task model / manager / metadata
T4 Task aside step cards + Autopilot ─────┤                                         ├──> T8 Agent-launch helpers + chainCommands
T5 Workflow-derived status gates ─────────┘                                         └──> T9 Terminal-layer seams
                                                                                              │
                                              T10 Docs + grep audit <─────────────────────────┘
```

T1–T5 are independent of each other and of the engine: each removes a *reader* of engine state, which
never breaks the engine. They may run in any order, or in parallel if the orchestrator can serialize
their `ci.sh` runs — but `ContentView.swift` is touched by T1, T2, T5, T6 and T9, and
`TerminalTab.swift` / `TerminalManager.swift` by both T2 and T9, so parallel runs need rebasing.
Sequential, in the numbered order, is simpler and is the intended dispatch.

T6 is the cut: it deletes the engine and everything that calls into it. T7, T8 and T9 sweep the
declarations T6 leaves with no callers; they are independent of each other. T10 is last, because the
grep audit only comes clean once every code task has landed.

**Note on task size.** The breakdown guidance caps a task at five files. Several tasks below exceed
that in raw file count because a deletion cluster must land atomically to keep the build green — but
no task edits more than five source files; the rest are whole-file deletions (source or test), which
carry no reasoning. The one genuinely large task is T6, and it cannot be split further: the engine's
declarations and its remaining callers must disappear in the same commit or the build breaks.

---

### T1: Retire the Workflow sidebar destination and the WORKFLOW.json editor

**Files edited:** `Sources/App/SidebarView.swift`, `Sources/App/ContentView.swift`,
`Sources/App/AppKeyboardShortcuts.swift`, `Tests/AppKeyboardShortcutsTests.swift`,
`Tests/BottomPanelActionTests.swift`

**Files deleted:** `Sources/App/WorkflowEditorView.swift`, `Sources/App/WorkflowEditorModel.swift`,
`Sources/App/WorkflowEditorDetailForms.swift`, `Sources/App/WorkflowActionCard.swift`,
`Tests/WorkflowEditorModelTests.swift`

**What it does.** Removes the editor screen and the sidebar row that reaches it.

- `SidebarView.swift`: delete `workflowRow` (`:199`) and its reference in the list body (`:75`).
- `ContentView.swift`: delete `case workflow` from `DetailSelection` (`:21`), its arm in
  `bottomPanelAction`'s `.noPanel` list (`:36`), the hidden Ctrl+3 button (`:376-378`), and the
  `else if detailSelection == .workflow { WorkflowEditorView(…) }` branch (`:923-924`).
- `AppKeyboardShortcuts.swift`: narrow the Ctrl+digit claim at `:38` from `"1"…"3"` to `"1"…"2"` and
  update the surrounding comment, which explains that the range stops at the last destination that
  exists.
- `AppKeyboardShortcutsTests.swift`: `testControlDigitIsClaimed` asserts `"2"` not `"3"`;
  `testControlDigitToleratesStrayShiftOrOption` uses `"2"`;
  `testControlDigitBeyondTheSidebarDestinationsIsNotClaimed` gains `"3"`; add a Ctrl+3 pin under
  `// MARK: - Retired shortcuts`, following the existing `testRetiredCommandControlDigitsAreNotClaimed`
  convention.
- `BottomPanelActionTests.swift`: drop `action(.workflow)` from
  `testDestinationsWithoutABottomPanelGetNothing`.
- The four deleted sources go together: `WorkflowEditorView` is the only consumer of
  `WorkflowEditorModel`, `WorkflowEditorDetailForms` and `PressableCardButtonStyle`
  (`WorkflowActionCard.swift:78`). `WorkflowSidebarActionCard`'s mention of `WorkflowActionCard` is a
  doc comment only (`:7`) — reword or drop that sentence so it does not name a deleted type.

**Acceptance criteria:**
- No `DetailSelection.workflow`, no Workflow sidebar row, no `WorkflowEditor*` or `WorkflowActionCard`
  file remains.
- Ctrl+3 is not claimed; Ctrl+1 and Ctrl+2 still are.

**Verified by:** `./scripts/ci.sh` green, and
`git ls-files -- Sources Tests | xargs grep -n 'WorkflowEditor\|PressableCardButtonStyle\|DetailSelection.workflow'`
returns nothing.

---

### T2: Remove the step badge from terminal tabs

**Files edited:** `Sources/App/MainTerminalTabStrip.swift`, `Sources/App/TerminalTab.swift`,
`Sources/App/TerminalManager.swift`, `Sources/App/ContentView.swift`,
`Tests/TerminalTabKindTests.swift`

**Files deleted:** `Sources/App/WorkflowStepBadge.swift`,
`Tests/WorkflowStepTaggingHarnessTests.swift`

**What it does.** Deletes the per-tab step tag and everything that computed it.

- `MainTerminalTabStrip.swift`: delete the `WorkflowStepBadge` render (`:20-21`), the `stepName`
  parameter on `TabChip` (`:8`) and `TerminalTabChip` (`:70`, `:79`) and both call-site arguments
  (`:226`, `:237`), `stepName(for:)` (`:203-206`), `badgedChipMinWidth` (`:139`) and the ternary at
  `:144` (the width becomes `Self.chipMinWidth`), and the now-unused
  `@EnvironmentObject workTaskCoordinator` (`:100`). Reword the file's opening doc comment, which
  describes the chip as "an optional workflow step badge, the title, and the close button".
- `TerminalTab.swift`: delete `stepSlug` and its init parameter. **Leave `launcherCommand` alone** —
  it still has a writer (`runWorkflowAction`) until T6; T9 removes it.
- `TerminalManager.swift`: delete `currentWorkflowStepProvider` (`:179`) and the `stepSlug:` argument
  inside the private `makeTab` (`:192`). Keep `makeTab`'s `launcherCommand:` parameter.
- `ContentView.swift`: delete the `terminalManager.currentWorkflowStepProvider = …` wiring in
  `onAppear` (`:385-387`).
- `TerminalTabKindTests.swift`: drop `stepSlug:` from the `TerminalTab` constructions at `:50` and
  `:57`. Keep `testLauncherCommandIsUnsetUnlessStamped` (T9 deletes it).
- `WorkflowStepTaggingHarnessTests.swift` is deleted whole: it exists to pin the stamp.

**Acceptance criteria:**
- No tab chip renders a badge; chip width is uniform.
- `TerminalTab` has no `stepSlug`; `TerminalManager` has no `currentWorkflowStepProvider`.

**Verified by:** `./scripts/ci.sh` green, and
`git ls-files -- Sources Tests | xargs grep -n 'stepSlug\|WorkflowStepBadge\|currentWorkflowStepProvider'`
returns nothing.

---

### T3: Remove the planning agent

**Files edited:** `Sources/App/WorkTaskCoordinator+Planning.swift`,
`Sources/App/WorkTaskCoordinator.swift`, `Sources/App/WorkTaskListView.swift`,
`Tests/PlanningLaunchCommandTests.swift`

**Files deleted:** `Sources/App/PlanningConfig.swift`, `Tests/PlanningConfigTests.swift`

**What it does.** The planning *agent* and its prompt template go; the planning *terminal* stays.

- `WorkTaskCoordinator+Planning.swift`: `planningLaunchCommand(for:)` loses its
  `if let instructions = planningInstructions { … }` branch, and with it the `PlanningConfig` +
  `buildAgentPromptCommand` + `planLogger` path (delete `planLogger` and the now-unused `os` import if
  nothing else in the file uses them). What remains is the `mainCommandProvider` →
  `buildBareCommand` path and the `nil` (plain shell) path. Update the function's doc comment, which
  currently describes a three-way choice. `planTask` is otherwise unchanged.
- `WorkTaskCoordinator.swift`: delete `planningInstructions` (`:170`) and `planningAgentCommand`
  (`:178`). Leave the rest of the coordinator to T6.
- `WorkTaskListView.swift`: collapse the Plan button to its icon form — delete the
  `if workTaskCoordinator.planningInstructions != nil { Text("Plan") }` branch (`:129-131`) and
  retitle the `.help` (`:136`) to the panel-toggle wording (show/hide the planning terminal), since
  there is no plan agent to run.
- `PlanningLaunchCommandTests.swift`: delete `testPlanningInstructionsWinOverTheMainTerminalCommand`.
  Rebase the class off `WorkflowHarnessTestCase` onto `TempRootTestCase` with an inlined coordinator
  builder (the harness itself is deleted in T6, and this is the only survivor that uses it), and drop
  `makeLaunchFixture`'s `planningEntry` parameter and its `writeWorkflowJSON` call. Keep both
  remaining tests — they pin behaviour that survives intact: rename
  `testBareMainTerminalCommandWhenNoPlanningInstructions` (there are no planning instructions any
  more — e.g. `testBareMainTerminalCommandWhenConfigured`) and keep
  `testNoConfiguredCommandOpensAPlainShell` as is.

**Acceptance criteria:**
- Cmd+J / the Plan icon still opens the per-task terminal on the Main Terminal command, or a plain
  shell when none is configured.
- No `PlanningConfig`, no `planningInstructions`, no `planningAgentCommand`.
- `PlanningLaunchCommandTests` compiles without `WorkflowHarnessTestCase` and its two tests pass.

**Verified by:** `./scripts/ci.sh` green, and
`git ls-files -- Sources Tests | xargs grep -n 'PlanningConfig\|planningInstructions\|planningAgentCommand\|renderPlanningPrompt'`
returns nothing.

---

### T4: Remove the task aside's step cards and Autopilot row

**Files edited:** `Sources/App/TaskAsideView.swift`, `Sources/App/WorkTaskCoordinator.swift`

**Files deleted:** `Sources/App/WorkflowSidebarActionCard.swift`, `Sources/App/AutopilotButton.swift`

**What it does.** The aside keeps the task card and agent metadata and loses every workflow control.

- `TaskAsideView.swift`: delete the `workflowDefinition` computed gate (`:20-22`), the step-cards
  block (`:54-57`), the `AutopilotButton` block (`:68-70`), `workflowActionCards(for:definition:)`
  (`:81-107`) and `countdown(for:)` (`:113-119`). Retarget the two Create Task doors at `:131` and
  `:148` from `workTaskCoordinator.exposeTask` / `workTaskCoordinator.createTask(forBranch:)` to
  `workTaskManager.expose(task)` / `workTaskManager.createExposedTask(forBranch:)` — the view already
  holds `@EnvironmentObject private var workTaskManager` (`:6`). `ensureShadowTask` (`:34`) stays on
  the coordinator. `workTaskManager.expose` returns the exposed task and `createExposedTask` an
  optional, matching the shapes the two doors already consume; re-read the coordinator's deleted
  wrappers for the `task(forWorktree:)` re-read they did afterwards and keep it if the view needs it.
- `WorkTaskCoordinator.swift`: delete `exposeTask(_:forBranch:)` (`:444-449`) and
  `createTask(forBranch:)` (`:452-456`) — they existed only to call `seedWorkflowStatus` after the
  manager call. Keep `ensureShadowTask`.
- `WorkflowSidebarActionCard.swift` (which also declares `CountdownRing`) and `AutopilotButton.swift`
  are deleted whole.

**Acceptance criteria:**
- The aside on a worktree shows the task card and agent metadata only — no step cards, no countdown
  ring, no Autopilot row.
- Create Task on a worktree with no task still creates and opens one.

**Verified by:** `./scripts/ci.sh` green, and
`git ls-files -- Sources Tests | xargs grep -n 'AutopilotButton\|WorkflowSidebarActionCard\|CountdownRing\|exposeTask'`
returns nothing.

---

### T5: Remove the workflow-derived status gates

**Files edited:** `Sources/App/WorkTaskListView.swift`, `Sources/App/ContentView.swift`,
`Sources/App/ContentViewHelpers.swift`, `Tests/SidePanelTabTests.swift`

**What it does.** Two surviving views stop asking the coordinator whether the project has a
`WORKFLOW.json`.

- `WorkTaskListView.swift`: delete `WorkTaskCard.isTerminalAction` (`:279-283`) and its use at `:295`;
  delete `WorkTaskStatusBadge.isTerminalAction` (`:372`) and the parameter on
  `badgeColor(for:isTerminalAction:)` (`:403`), whose `default:` arm becomes `.green` (`:412`); update
  the two call sites at `:395`/`:396`.
- `ContentViewHelpers.swift`: drop `resolveSidePanelTab`'s `isWorkflowJSONProject` parameter (`:49`)
  and its `if isWorkflowJSONProject { return .task }` branch (`:55`); update the function's doc
  comment (`:45`) and reword `SidePanelTab.available`'s (`:36`), which says "never drives a workflow
  loop".
- `ContentView.swift`: drop the `isWorkflowJSONProject:` argument in `restoreSidePanelTab` (`:615`)
  and reword the doc comment at `:483` that names the workflow loop.
- `SidePanelTabTests.swift`: delete `testJSONProjectNoStoredTabSelectsTaskForAnyStatus` and
  `testMainClampsJSONDefaultToTodos`. Rewrite the three whose expected value came from the gate:
  `testStoredTabBeatsJSONProjectRule` (retarget to "a stored tab wins over the status rule"),
  `testInvalidStoredRawValueFallsThrough` (re-express against `taskStatus: in_progress` — it expected
  `.task` only because the gate was `true`), and `testPersistedNotesTabFallsBackToValidTab` (drop its
  JSON half, keep the non-JSON half). Drop the `isWorkflowJSONProject:` argument from every remaining
  call.

**Acceptance criteria:**
- A task on an unknown slug still renders with a green badge.
- `resolveSidePanelTab` takes `(stored:taskStatus:current:isMain:)` and nothing else.

**Verified by:** `./scripts/ci.sh` green, and
`git ls-files -- Sources Tests | xargs grep -n 'isWorkflowJSONProject\|isTerminalAction'` returns only
the coordinator's own `isWorkflowJSONProject` declaration (deleted in T6).

---

### T6: Delete the loop engine and its coordinator state

**Files edited:** `Sources/App/WorkTaskCoordinator.swift`, `Sources/App/ContentView.swift`,
`Sources/App/ProjectWindow.swift`, `Tests/WorkTaskCoordinatorTests.swift`,
`Tests/TestHelpers.swift`

**Files deleted:** `Sources/App/WorkflowDefinition.swift`, `Sources/App/WorkflowLoopEngine.swift`,
`Sources/App/WorkTaskCoordinator+WorkflowEngine.swift`, and the ten engine test files
`Tests/WorkflowAgentLaunchTests.swift`, `Tests/WorkflowAgentSupersedeHarnessTests.swift`,
`Tests/WorkflowCompletionHarnessTests.swift`, `Tests/WorkflowCountdownHarnessTests.swift`,
`Tests/WorkflowDefinitionModelTests.swift`, `Tests/WorkflowDefinitionTests.swift`,
`Tests/WorkflowLoopEngineHarnessTests.swift`, `Tests/WorkflowLoopEngineTests.swift`,
`Tests/WorkflowModelLaunchTests.swift`, `Tests/WorkflowSidebarActionTests.swift`

**What it does.** The cut. Deletes the engine, its stateful plumbing, and every remaining caller. This
task cannot be split: the declarations and their last callers must go in the same commit.

- `WorkTaskCoordinator.swift`:
  - delete the whole `// MARK: - WORKFLOW.json Loop Engine` block (`:35-114`): `runningAction`,
    `launchGeneration`, `engineHalted`, `lastKnownAutopilot`, `appProvider`, `workflowAgentLauncher`,
    `launcherTabAppender`, `workflowCountdowns`, `countdownWorkItems`, `workflowCountdownScheduler`,
    `countdownDuration`;
  - delete the caches and their refresh (`isWorkflowJSONProject` `:132`, `workflowDefinition` `:144`,
    `rawWorkflowDefinition` `:152`, `refreshWorkflowJSONGate` `:158`), `workflowAgentCommand(for:action:)`
    (`:192`) and `workflowAfterCreateHook()` (`:356`);
  - delete the whole agent-surface subsystem (decision 10): `agentSurfaces` (`:16`),
    `setAgentSurface` (`:20`), `agentSurfaceIdentities` (`:28`), `launchPromptFiles` (`:33`),
    `isAgentSurface` (`:324`), `handleMainTabClosed` (`:337`), `shouldClearLiveAgentState` (`:371`),
    `handleChildExited` (`:378`), `exitObserver` (`:199`) and its `.ghosttyChildExited` registration
    in `init`, and the surface/prompt-file cleanup inside `handleWorktreeRemoved` (`:303-322` — keep
    whatever teardown is not agent-surface bookkeeping);
  - delete the `onTasksReloaded` / `onClearwayChanged` assignments and the `refreshWorkflowJSONGate()`
    seed from `init`, leaving an `init` that only stores its three dependencies;
  - in `startTask`, replace `updated.errorMessage = nil` with
    `updated.status = WorkTask.ReservedStatus.inProgress` (decisions 1 and 7), and rewrite the two
    comment blocks (`:253-256`, `:265-267`) that describe the JSON seed;
  - rewrite the type's doc comment, which opens "Coordinates the task launch workflow", and
    `completePendingLaunch`'s, which credits the seed with the agent launch. The relocation itself
    stays.
- `ContentView.swift`: in the `lastCreatedBranch` handler, delete the
  `workTaskCoordinator.seedWorkflowStatus(forBranch:)` call and its comment block (`:305-309`) and the
  `workflowHookCmd` line (`:314`); the hook call becomes
  `if let cmd = projectHookCmd, let app = ghosttyApp.app { … }` (leaving `WorktreeHooks.chainCommands`
  dead — T8 deletes it). Delete the `workTaskCoordinator.appProvider = …` wiring and its comment
  (`:389-391`).
- `ProjectWindow.swift`: delete the `terminalManager.skipAutoRestart` and
  `terminalManager.onMainTabClosed` wiring in `onAppear` (`:118-123`). The properties themselves go in
  T9.
- `Tests/TestHelpers.swift`: delete `WorkflowHarnessTestCase` (lines 44–193) entirely. Keep
  `makeWorktree` and `TempRootTestCase`.
- `Tests/WorkTaskCoordinatorTests.swift`: delete `testRawCacheHoldsPlanningWithoutEnablingGate`,
  `testRawAndValidatedCacheBothPresentForRealWorkflow` and the private `makeCoordinator(workflowJSON:)`
  helper (`:54-66`) they alone use. Extend `testStartTaskUsesFreshDiskContentNotStaleSnapshot`, or add
  a sibling test, pinning decision 1: `startTask` on a backlog task writes `in_progress`.

**Acceptance criteria:**
- Clearway launches no agent on its own. Start Now creates the worktree, relocates `TASK.md`, runs the
  project's `WorktreeHooks` after-create hook in the secondary terminal, and leaves the task on
  `in_progress`.
- No `WorkflowDefinition`, `WorkflowLoopEngine`, `WorkflowCountdown`, `seedWorkflowStatus`,
  `advanceWorkflow`, `runWorkflowAction`, `agentSurfaces` or `handleChildExited` remains.
- A new test pins `startTask` → `in_progress`.

**Verified by:** `./scripts/ci.sh` green, and
`git ls-files -- Sources Tests | xargs grep -nE 'WorkflowDefinition|WorkflowLoopEngine|seedWorkflowStatus|agentSurfaces|setAgentSurface|appProvider|WorkflowHarnessTestCase'`
returns nothing.

---

### T7: Strip autopilot, completed and error_message from the task model, manager and metadata view

**Files edited:** `Sources/App/WorkTask.swift`, `Sources/App/WorkTaskManager.swift`,
`Sources/App/WorkTaskAgentMetadata.swift`, `Tests/WorkTaskTests.swift`,
`Tests/WorkTaskManagerTests.swift`, `Tests/WorkTaskManagerWatcherTests.swift`

**What it does.** Removes the model fields and manager plumbing T6 left with no writers.

- `WorkTask.swift`: delete `errorMessage` (`:19`), `autopilot` (`:31`), `completed` (`:39`), their
  three `frontmatterLines()` emissions (`:138`, `:143`, `:146`) and their three `parse` assignments
  (`:232`, `:236`, `:239`); delete `ReservedStatus.legacyOrdered` (`:72`, decision 12) and the
  `hasContent` computed property (`:45`, assumption 22 — **not** the static
  `WorkTaskAgentMetadata.hasContent(for:)`, which survives). Rewrite the `status` doc comment, which
  describes the slug-from-`WORKFLOW.json` contract, to say: a reserved backlog marker, one of the
  fixed states, or an arbitrary slug left by an external writer, displayed via `displayLabel`.
- `WorkTaskManager.swift`: delete `onTasksReloaded` (`:47`), `onClearwayChanged` (`:56`) and both
  their firings in `reload()` (`:391`, `:408`); delete `freshStatus` (`:277`), `setAutopilot` (`:290`),
  `rootClearwayDirectory` (`:19`, `:61`), `rootClearwayWatcherSource` (`:21`), `watchRootClearway()`
  (`:518`) and its re-arm (`:355`) and cancel (`:122`) sites. Confirm by reading that the `tasks/`
  watcher (`:509`) still re-arms from `write()` once `.clearway/tasks` first appears — that path must
  not be collateral damage.
- `WorkTaskAgentMetadata.swift`: drop `|| task.errorMessage != nil` from `hasContent(for:)` (`:9`) and
  the error display (`:22`); collapse the now single-child `HStack` (`:14`).
- `Tests/WorkTaskTests.swift`: delete `testAutopilotRoundTrips`, `testCompletedRoundTrips`,
  `testFileWithoutCompletedFieldParsesToNil`, `testFileWithoutAutopilotFieldParsesToNil`. Add one test
  pinning decision 2: a `TASK.md` carrying `autopilot:` / `completed:` / `error_message:` parses, and
  re-serializing drops those three lines while preserving every other field.
  `testArbitrarySlugRoundTrips` and `testDisplayLabels` stay.
- `Tests/WorkTaskManagerTests.swift`: delete the `setAutopilot` staleness test and
  `testReloadNoOpDoesNotFireOnTasksReloaded`; rebase the two `onTasksReloaded` observers (`:555`,
  `:608`) onto assertions about `manager.tasks`.
- `Tests/WorkTaskManagerWatcherTests.swift`: rebase `:57` / `:76` off `onTasksReloaded` onto an
  expectation driven by `manager.tasks`, so the debounced file-watcher reload stays covered.

**Acceptance criteria:**
- A `TASK.md` with `autopilot:` / `completed:` / `error_message:` round-trips without them and keeps
  every other field.
- The debounced reload and the `tasks/` and per-worktree watchers still work, covered by the rebased
  watcher tests.
- The agent-metadata row shows the attempt label only.

**Verified by:** `./scripts/ci.sh` green, and
`git ls-files -- Sources Tests | xargs grep -nE 'autopilot|Autopilot|errorMessage|error_message|onTasksReloaded|onClearwayChanged|freshStatus|legacyOrdered'`
returns nothing.

---

### T8: Delete the dead agent-launch helpers and chainCommands

**Files edited:** `Sources/App/AgentLaunch.swift`, `Sources/App/WorktreeHooks.swift`,
`Tests/WorktreeHooksTests.swift`

**Files deleted:** `Tests/AgentLaunchAgentTests.swift`, `Tests/AgentLaunchModelTests.swift`

**What it does.** Removes the resolution and model-flag helpers that only the engine and the editor
called.

- `AgentLaunch.swift`: delete `isAllowlistedAgentCommand` (`:14`), `allowlistedAgent` (`:21`),
  `resolveAgentCommand` (`:36`), `agentsAcceptingModelFlag` (`:95`), `applyModel` (`:99`),
  `isModelValueSafe` (`:110`) and `acceptsModelFlag` (`:116`). **Keep** `agentAllowlist` (`:7`) and
  `buildAgentPromptCommand` (`:66`), rewriting both doc comments to drop `WORKFLOW.json`: the
  allowlist's sole remaining job is rendering Settings → Main Terminal's picker rows
  (`SettingsView.swift:11`), and `buildAgentPromptCommand`'s ARG_MAX note should name the prompt
  launcher rather than "Plan / workflow prompts".
- `WorktreeHooks.swift`: delete `chainCommands` (`:29`) — T6 removed its only call site.
- `Tests/WorktreeHooksTests.swift`: delete the four `chainCommands` tests (`:78-95`).
- The two deleted test files cover only `resolveAgentCommand` and `applyModel`. Deleting
  `AgentLaunchModelTests.swift` loses no coverage of `buildAgentPromptCommand`:
  `TerminalManagerTests.swift:93-175` holds six tests on it, including the shape invariants
  (`writesPromptFile_andQuotesAgentCommand`, `keepsSpecialCharsInFile_notInShellString`,
  `escapesSingleQuotes_inAgentCommand`).

**Acceptance criteria:**
- `AgentLaunch.swift` declares exactly `agentAllowlist` and `buildAgentPromptCommand` (plus whatever
  private helper `buildAgentPromptCommand` itself needs), with no `WORKFLOW.json` in its prose.
- Settings → Main Terminal still lists claude / grok / codex; the prompt launcher still submits.

**Verified by:** `./scripts/ci.sh` green, and
`git ls-files -- Sources Tests | xargs grep -nE 'resolveAgentCommand|applyModel|isModelValueSafe|isAllowlistedAgentCommand|agentsAcceptingModelFlag|acceptsModelFlag|chainCommands'`
returns nothing.

---

### T9: Remove the terminal layer's workflow seams

**Files edited:** `Sources/App/TerminalTab.swift`, `Sources/App/TerminalManager.swift`,
`Sources/App/TerminalManager+TaskTerminals.swift`, `Sources/App/ContentView.swift`,
`Tests/TerminalTabKindTests.swift`

**What it does.** Removes the launcher-command stamp and the agent-surface hooks, now that nothing
writes or reads them.

- `TerminalTab.swift`: delete `launcherCommand` and its init parameter (decision 11).
- `TerminalManager.swift`: delete `makeTab`'s `launcherCommand:` parameter (`:187`) and the field it
  set (`:193`); delete `appendLauncherTab`'s `command:` parameter (`:388`, `:395`) and the
  `command == nil` clause in the login-shell promotion gate around `:419`, so the gate turns purely on
  `mainCommandProvider()`; delete `skipAutoRestart` (`:165`) and `onMainTabClosed` (`:212`) and their
  consumers at `:523`, `:552`, `:568` and `:635`, along with the comments at `:337`, `:493` and `:568`
  that describe the agent-surface bailout.
- `TerminalManager+TaskTerminals.swift`: delete `terminateSurface` (`:102`, assumption 8).
- `ContentView.swift`: at `:817`, replace `let launcherCommand = activeTab.launcherCommand` and the
  `??` fallback with `settings.resolvedMainTerminalCommand`, passed to both `PromptLauncherView`
  (`:820`) and the submit (`:833`).
- `Tests/TerminalTabKindTests.swift`: delete `testLauncherCommandIsUnsetUnlessStamped`.

**Acceptance criteria:**
- Cmd+T opens a launcher on the Main Terminal command, or a login shell when Main Terminal is "None".
- The prompt launcher's placeholder and submit both name `settings.resolvedMainTerminalCommand`.
- A dead surface still auto-restarts as before (nothing suppresses it any more).

**Verified by:** `./scripts/ci.sh` green, and
`git ls-files -- Sources Tests | xargs grep -nE 'launcherCommand|skipAutoRestart|onMainTabClosed|terminateSurface'`
returns nothing.

---

### T10: Rewrite the docs and clear the grep audit

**Files edited:** `README.md`, `CLAUDE.md`

**What it does.** Removes the feature's documentation and rehomes the facts inside it that remain true
of surviving code.

- `README.md`: delete lines 56–166 (`## Task workflows (.clearway/WORKFLOW.json)` and every
  subsection). Replace with a short `## Tasks` section carrying the three facts that span was the only
  home for: (a) starting a task creates a worktree and opens a terminal — Clearway launches no agent
  on its own, and the status is yours to drive; (b) the agent CLIs Clearway knows (`claude`, `grok`,
  `codex`), with Settings → Main Terminal picking the default; (c) Ctrl-C in an agent's terminal, or
  closing its tab, ends it. Everything else in the deleted span (actions, routes, slugs, hooks,
  planning templates, per-entry models, the context block, autopilot) has no surviving analog and is
  dropped.
- `CLAUDE.md`: delete lines 166–394 (`## Workflow engine` through `### Loop guard / stopping a step`).
  Then, surgically:
  - L127: `task/worktree/workflow logic` → `task/worktree logic`.
  - L134-136 (the `AppKeyboardShortcuts.swift` bullet's retired-shortcut sentence): add ⌃3 to the pin list,
    keeping the existing distinction between a shortcut the app once owned and a SwiftUI default
    dropped as collateral.
  - Add to the `Sources/App/` bullet list the facts rehomed out of the deleted section that still
    describe live code: `agentAllowlist` as the single source of Settings → Main Terminal's picker
    rows; `buildAgentPromptCommand`'s unquoted `$1 "$(cat "$2")"` expansion and its word-splitting
    consequence (a security-adjacent gotcha that survives with the launcher); and
    `appendLauncherTab`'s promotion to a login shell when Main Terminal is "None", stated without the
    stamped-tab exemption.
  - Leave untouched: the `## Concurrency` section, the `PanelCommands.swift` bullet (the Planning
    bottom panel survives — decision 3), and the `## Pipeline` section.
  - The step-badge chip-colour note (L379-381) dies with `WorkflowStepBadge`; no chip carries a badge
    afterwards, so there is nothing to rehome it onto.
- `ARCHITECTURE.md`, `website/`, `project.yml`, `Resources/`, `.github/workflows/` and `scripts/` need
  no edits (spec assumptions 19–20).

**Acceptance criteria:** the spec's grep audit passes.

```bash
git ls-files -z | grep -zv '^ghostty/' \
  | xargs -0 grep -nE 'workflow|Workflow|WORKFLOW|autopilot|Autopilot|stepSlug|launcherCommand|runningAction'
```

returns only: `.github/workflows/ci.yml` and `.github/workflows/build-ghosttykit.yml` (GitHub Actions'
own `${{ github.workflow }}` and the directory name), `scripts/ci.sh:2`, `CLAUDE.md`'s `## Pipeline`
section, and this plan plus its spec. And

```bash
git ls-files -z -- Sources Tests | xargs -0 grep -nE \
  'resolveAgentCommand|applyModel|isModelValueSafe|isAllowlistedAgentCommand|agentsAcceptingModelFlag|PlanningConfig|planningInstructions|chainCommands|terminateSurface|freshStatus|onTasksReloaded|onClearwayChanged|setAgentSurface|agentSurfaces|skipAutoRestart|onMainTabClosed|legacyOrdered|error_message|errorMessage|seedWorkflowStatus|hasContent'
```

returns only `WorkTaskAgentMetadata.hasContent(for:)` and its call sites — check that one by hand
rather than trusting the regex.

**Verified by:** `./scripts/ci.sh` green, plus both greps above.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A task deletes a declaration whose caller is still standing, breaking the build mid-plan. | High | T1–T5 only remove *readers*; T6 is the single cut; T7–T9 only remove declarations T6 orphaned. Each task ends on a green `./scripts/ci.sh`. |
| `xcodegen generate` is skipped, so deleted files still build. | High | Every task's regression check is `./scripts/ci.sh`, which runs it. Never a hand-written `xcodebuild` line. |
| T7's `WorkTaskManager` surgery takes out the `tasks/` watcher re-arm along with the root `.clearway/` one. | High | T7 names the check explicitly, and the rebased `WorkTaskManagerWatcherTests` cover the debounced reload. |
| `git status` goes dirty from `default.profraw` after any Debug launch (it is not gitignored). | Low | Read the list before staging; never `git add -A`. |

## Build log

### T1: Retire the Workflow sidebar destination and the WORKFLOW.json editor

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorkflowEditorView.swift` | Deleted |
| `Sources/App/WorkflowEditorModel.swift` | Deleted |
| `Sources/App/WorkflowEditorDetailForms.swift` | Deleted |
| `Sources/App/WorkflowActionCard.swift` | Deleted (took `PressableCardButtonStyle` with it) |
| `Tests/WorkflowEditorModelTests.swift` | Deleted |
| `Sources/App/SidebarView.swift` | `workflowRow` and its list-body reference removed |
| `Sources/App/ContentView.swift` | `DetailSelection.workflow`, its `.noPanel` arm, the hidden Ctrl+3 button and the `.workflow` detail branch removed |
| `Sources/App/AppKeyboardShortcuts.swift` | Ctrl+digit claim narrowed from `"1"…"3"` to `"1"…"2"`; comment updated |
| `Sources/App/WorkflowSidebarActionCard.swift` | Doc comment no longer names the deleted `WorkflowActionCard` |
| `Tests/AppKeyboardShortcutsTests.swift` | `testControlDigitIsClaimed` asserts `"2"`; `testControlDigitToleratesStrayShiftOrOption` uses `"2"`; `testControlDigitBeyondTheSidebarDestinationsIsNotClaimed` gained `"3"`; new `testRetiredControlDigitThreeIsNotClaimed` pin |
| `Tests/BottomPanelActionTests.swift` | `action(.workflow)` dropped |

**Evidence: the Ctrl+3 pins watched failing against the unfixed claim range**

With `scalar <= "3"` temporarily restored in `AppKeyboardShortcuts.swift` and
`-only-testing:ClearwayTests/AppKeyboardShortcutsTests`:

```
Tests/AppKeyboardShortcutsTests.swift:68: error: -[ClearwayTests.AppKeyboardShortcutsTests testControlDigitBeyondTheSidebarDestinationsIsNotClaimed] : XCTAssertFalse failed
Tests/AppKeyboardShortcutsTests.swift:133: error: -[ClearwayTests.AppKeyboardShortcutsTests testRetiredControlDigitThreeIsNotClaimed] : XCTAssertFalse failed
```

The range was restored to `"1"…"2"` immediately afterwards.

**Deviations from the plan:** none.

**Gate:** `./scripts/ci.sh` — passed, exit 0. `Executed 502 tests, with 0 failures (0 unexpected)`.

**Task-scoped grep:**
`git ls-files -- Sources Tests | xargs grep -n 'WorkflowEditor\|PressableCardButtonStyle\|DetailSelection.workflow'`
returns nothing.

### T2: Remove the step badge from terminal tabs

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorkflowStepBadge.swift` | Deleted |
| `Tests/WorkflowStepTaggingHarnessTests.swift` | Deleted |
| `Sources/App/MainTerminalTabStrip.swift` | Badge render, `stepName` parameter on `TabChip`/`TerminalTabChip` and both call-site arguments, `stepName(for:)`, `badgedChipMinWidth` and the width ternary, and the `workTaskCoordinator` `@EnvironmentObject` removed; opening doc comment reworded |
| `Sources/App/TerminalTab.swift` | `stepSlug` property and init parameter removed |
| `Sources/App/TerminalManager.swift` | `currentWorkflowStepProvider` removed; `makeTab` no longer stamps a slug and its doc comment shrank to what it still does |
| `Sources/App/ContentView.swift` | `currentWorkflowStepProvider` wiring in `onAppear` removed |
| `Tests/TerminalTabKindTests.swift` | `stepSlug:` dropped from all five `TerminalTab` constructions |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` for the two deletions |

**Evidence**

This task is a pure deletion with no behavioural branch left to exercise, so no regression test was
written: there is nothing that could pass before the change and fail after it. The bar is enforced by
the compiler instead — `stepSlug` and `currentWorkflowStepProvider` no longer exist, so any surviving
reader is a build error, and `TerminalTabKindTests`' five `TerminalTab` constructions are the standing
compile-time pin on the initializer's shape. The deleted harness test
(`WorkflowStepTaggingHarnessTests`) existed only to pin the stamp that is gone.

**Deviations from the plan**

- The plan listed only `:50` and `:57` of `TerminalTabKindTests.swift` as carrying `stepSlug:`; there
  were five constructions in total (`:6`, `:15`, `:22`, `:32`, `:50`, `:55`). All were updated, since
  the parameter no longer exists.
- Rather than leaving a `let minWidth = Self.chipMinWidth` local and a now-constant `minWidth:`
  parameter on `equalWidthLayout` / `scrollableLayout`, the parameter was dropped and both helpers read
  `Self.chipMinWidth` directly. The parameter existed only because the width varied with the badge.
- `WorkTaskCoordinator.workflowActionName` is now callerless. Left in place deliberately: T6 deletes
  `WorkTaskCoordinator+WorkflowEngine.swift` whole.

**Gate:** `./scripts/ci.sh` — passed, exit 0. `Executed 492 tests, with 0 failures (0 unexpected)`.

**Task-scoped grep:**
`git ls-files -- Sources Tests | xargs grep -n 'stepSlug\|WorkflowStepBadge\|currentWorkflowStepProvider'`
returns nothing.

### T3: Remove the planning agent

**What landed**

| File | State |
| --- | --- |
| `Sources/App/PlanningConfig.swift` | Deleted |
| `Tests/PlanningConfigTests.swift` | Deleted |
| `Sources/App/WorkTaskCoordinator+Planning.swift` | `planningLaunchCommand`'s planning-instructions branch removed with `planLogger` and the `os` import; doc comments updated; the now-unused `for task:` parameter dropped |
| `Sources/App/WorkTaskCoordinator.swift` | `planningInstructions` and `planningAgentCommand` removed |
| `Sources/App/WorkTaskListView.swift` | Plan button collapsed to its icon form; `.help` retitled to show/hide the planning terminal |
| `Tests/PlanningLaunchCommandTests.swift` | Rebased off `WorkflowHarnessTestCase` onto `TempRootTestCase` with an inlined coordinator builder; planning-instructions test deleted; bare-command test renamed `testBareMainTerminalCommandWhenConfigured` |
| `Tests/WorkflowAgentLaunchTests.swift` | `// MARK: - Plan` section (helper + two tests) removed; header comment updated |
| `Tests/WorkflowModelLaunchTests.swift` | `testPlanningCommandHonorsPlanningModel` and `testPlanningCommandUnchangedWithoutPlanningModel` removed; the fixture's now-unread `planning` entry and the header comment updated |
| `Tests/WorkflowLoopEngineHarnessTests.swift` | Two `planningAgentCommand` assertions removed from the launch-resolution tests |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` for the two deletions |

**Evidence**

A pure deletion with no behavioural branch left to exercise, so no regression test was written: the
surviving path (bare Main Terminal command, else plain shell) is unchanged and is already pinned by
the two tests kept in `PlanningLaunchCommandTests`. The compiler is the bar for the removal —
`planningInstructions`, `planningAgentCommand` and `PlanningConfig` no longer exist, so any surviving
reader is a build error.

**Deviations from the plan**

- `planningLaunchCommand(for:)` became `planningLaunchCommand()`. With the planning-instructions branch
  gone the task was read nowhere in the body, and an ignored parameter is dead weight. `planTask`'s
  `guard let task = …` became `guard workTaskManager.tasks.contains(where:)`, which is the existence
  check it was actually doing.
- The plan did not list the three engine test files that also read `planningAgentCommand`
  (`WorkflowAgentLaunchTests`, `WorkflowModelLaunchTests`, `WorkflowLoopEngineHarnessTests`). Their
  Plan-specific tests and assertions were removed here so the tree stays green; T6 deletes all three
  files whole.

**Gate:** `./scripts/ci.sh` — passed, exit 0. `Executed 483 tests, with 0 failures (0 unexpected)`.

**Task-scoped grep:**
`git ls-files -- Sources Tests | xargs grep -n 'PlanningConfig\|planningInstructions\|planningAgentCommand\|renderPlanningPrompt'`
returns nothing.

### T4: Remove the task aside's step cards and Autopilot row

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorkflowSidebarActionCard.swift` | Deleted (took `CountdownRing` with it) |
| `Sources/App/AutopilotButton.swift` | Deleted |
| `Sources/App/TaskAsideView.swift` | `workflowDefinition` gate, step-cards block, `AutopilotButton` block, `workflowActionCards(for:definition:)` and `countdown(for:)` removed; `taskContent` collapsed back to a bare `ScrollView`; Create Task doors retargeted to `workTaskManager.expose` / `workTaskManager.createExposedTask`; the now-unread `worktreeId` property dropped |
| `Sources/App/ContentView.swift` | `worktreeId:` argument dropped from the `TaskAsideView` construction |
| `Sources/App/WorkTaskCoordinator.swift` | `exposeTask(_:forBranch:)` and `createTask(forBranch:)` removed; `ensureShadowTask` kept |
| `Sources/App/WorkTaskCoordinator+WorkflowEngine.swift` | `seedWorkflowStatus`'s comment no longer names the deleted `exposeTask` |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` for the two deletions |

**Evidence**

A pure deletion with no behavioural branch left to exercise, so no regression test was written: there
is nothing that could pass before the change and fail after it. The two Create Task doors are the one
behaviour that changes hands, and it is a like-for-like retarget — `WorkTaskManager.expose` returns the
exposed task and `createExposedTask` returns the fresh pool entry after its own `reload()`, which are
exactly the shapes the deleted coordinator wrappers returned. The coordinator's
`workTaskManager.task(forWorktree:) ?? …` re-read was there only because `seedWorkflowStatus` wrote
`status`/`autopilot` between the manager call and the return; with the seed gone there is nothing to
re-read past, so it was not carried over. The compiler is the bar for the removal —
`AutopilotButton`, `WorkflowSidebarActionCard`, `CountdownRing`, `exposeTask` and
`createTask(forBranch:)` no longer exist, so any surviving reader is a build error.

**Deviations from the plan**

- `TaskAsideView.worktreeId` was dropped along with the `AutopilotButton` block, its only reader, and
  the argument removed from the single call site in `ContentView.swift`. The plan did not list
  `ContentView.swift` for this task, but the property became dead *because of* this task; leaving it
  would have left a stored property nothing reads.
- `taskContent`'s outer `VStack(spacing: 0)` existed only to pin the Autopilot row below the
  `ScrollView`. With the row gone the wrapper was removed rather than left as a single-child stack.
- `WorkTaskCoordinator+WorkflowEngine.swift` was edited (one comment) so the task-scoped grep comes
  clean; the file itself is deleted whole in T6.
- `setWorkflowActionCurrent`, `runWorkflowAction`, `workflowCountdown`, `pauseFromCountdown` and
  `WorkflowDefinition.actionProgress` are now callerless in `Sources`. Left in place deliberately: T6
  deletes `WorkTaskCoordinator+WorkflowEngine.swift` and `WorkflowDefinition.swift` whole, and their
  tests (`WorkflowSidebarActionTests`, `WorkflowCountdownHarnessTests`) go with them.

**Gate:** `./scripts/ci.sh` — passed, exit 0. `Executed 483 tests, with 0 failures (0 unexpected)`.

**Task-scoped grep:**
`git ls-files -- Sources Tests | xargs grep -n 'AutopilotButton\|WorkflowSidebarActionCard\|CountdownRing\|exposeTask'`
returns nothing.
