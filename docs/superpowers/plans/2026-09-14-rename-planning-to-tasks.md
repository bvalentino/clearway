# Plan: Rename Planning to Tasks

**Date:** 2026-09-14
**Base:** b049206589b9eb8e94a0630de38c7e3cebf5a1db
**PR:** #215

Breaks down `docs/superpowers/specs/2026-09-14-rename-planning-to-tasks.md`. Every design decision is
settled there; read it before starting a task, and read this file for what your task is and how it is
checked.

## Architecture decisions carried from the spec

1. **Pure rename.** No behaviour, no persisted format, no keyboard shortcut changes. A diff that
   changes what the app does is a defect. (Spec, Out of scope)
2. **The terminal's noun is `taskTerminal`**, the vocabulary `TerminalManager` already uses
   (`isTaskTerminalVisible`, `toggleTaskTerminal`, `openTaskTerminalWithCommand`). (Decision 3)
3. **`WorkTaskCoordinator.planTask` becomes `toggleTaskTerminal(taskId:app:focusOnReveal:)`** and
   `WorkTaskListView.planTask()` becomes `toggleTaskTerminal()`. The name repeating
   `TerminalManager.toggleTaskTerminal(for:app:projectPath:)` is correct — every call site is
   qualified by its receiver. (Decisions 4, 5)
4. **The notification's raw string changes with its constant**: `Notification.Name("planningTerminalOpened")`
   → `Notification.Name("taskTerminalOpened")`. One poster, one observer, never crosses a process or
   disk boundary. (Decision 6, assumption 2)
5. **`DetailSelection.planning` → `.tasks` is free**: the enum is `Hashable` only, never `Codable`,
   and lives in two `@State` properties. (Decision 7, assumption 1)
6. **The toolbar tooltip drops the qualifier**: "Show terminal" / "Hide terminal", not "Show task
   terminal" — the button sits in the task list's own toolbar. (Decision 2)
7. **Test fixture strings containing "plan"/"planned" are not renamed.** `"Pre-plan draft"`,
   `"Post-plan title"`, `"Planned title"`, `"Full planned brief."`, `"Planned via watcher"` are
   payloads describing an agent having planned a task, not references to the destination. Doc
   comments in those same files that name the *terminal* or the *destination* are in scope.
   (Decision 8)
8. **"Backlog", not "Tasks", where the prose names the pre-worktree pool.** "a fresh Planning task" →
   "a fresh backlog task"; "`.new` is planning-only" → "`.new` is backlog-only". "Tasks" only where
   the sentence names the destination. (Decision 9)
9. **`project.yml` is not edited.** Sources are globbed by directory, so the two file renames need
   only `xcodegen generate`, which `./scripts/ci.sh` runs. (Assumption 4)
10. **`docs/superpowers/` records for #214 are not edited.** Shipped documents, never touched after
    merge. (Decision 10)
11. **`AppKeyboardShortcuts` is untouched.** The Ctrl+digit claim matches scalars `"1"…"2"` and names
    no destination. No new retired-shortcut pin. (Decision 11, assumption 6)

## Regression check

Every task's check is the project's one runner:

```bash
./scripts/ci.sh
```

It runs `xcodegen generate` (without which the two renamed files are invisible to the build),
SwiftLint, the build and the full test suite. Do not hand-write an `xcodebuild` line.

## Dependency graph

```
T1 (sidebar destination)  ──┐
                            ├── independent, any order
T2 (coordinator + list view, incl. both file renames)
        │
        └── T3 (notification constant + remaining Sources prose)
                    │
T4 (Tests prose + CLAUDE.md) ── independent of all three
```

T3 edits `Sources/App/WorkTaskCoordinator+TaskTerminal.swift`, which only exists after T2 does the
`git mv`. T1 and T4 depend on nothing. Each task leaves the tree compiling and the suite green.

### T1: Rename the sidebar destination to Tasks

**Files:** `Sources/App/ContentView.swift`, `Sources/App/SidebarView.swift`,
`Tests/BottomPanelActionTests.swift`

**What it does.** Renames the two `ContentView` enum cases and every reference, retitles the sidebar
row, and updates the `ContentView` prose that names the destination.

- `Sources/App/ContentView.swift`: `DetailSelection.planning` → `.tasks` (declared `:19`; referenced
  `:34`, `:65`, `:66`, `:150`, `:262`, `:362`, `:423`, `:631`, `:722`, `:905`).
  `BottomPanelAction.planningTerminal` → `.taskTerminal` (declared `:43`; referenced `:34`, `:110`).
  Prose: `:145` "navigates to it in Planning" → "in Tasks"; `:149` "so Planning mounts" → "so Tasks
  mounts"; `:602` "navigating away from Planning/Prompts" → "away from Tasks/Prompts". (`:614`
  already says Tasks.)
- `Sources/App/SidebarView.swift`: `planningRow` → `tasksRow` (`:73`, `:187`); the user-visible label
  `destinationRow("Planning", …)` → `"Tasks"` (`:189`); `.tag(DetailSelection.tasks)` (`:190`). The
  icon logic and the `⌃1` hint are unchanged.
- `Tests/BottomPanelActionTests.swift`: `testPlanningHostsThePlanningTerminal` →
  `testTasksHostTheTaskTerminal` (`:23`); body becomes
  `XCTAssertEqual(action(.tasks), .taskTerminal)` (`:24`).

Do **not** touch `planTask`, `planningLaunchCommand` or `planningTerminalOpened` here; those are T2
and T3. `ContentView.swift:113` still reads `workTaskCoordinator.planTask(…)` after this task.

**Acceptance criteria.**
1. The sidebar's first row reads "Tasks", with the same `tray`/`tray.full` icon logic and `⌃1` hint.
2. No occurrence of `planning` remains in `SidebarView.swift`, `BottomPanelActionTests.swift`, or in
   `ContentView.swift` outside line `:113`'s `planTask` call.
3. Behaviour is unchanged: the enum is still `Hashable`-only with the same three cases, and
   `bottomPanelAction(for:)` still maps the same selections to the same panels.

**Verification.**
- `./scripts/ci.sh` passes (`BottomPanelActionTests` included).
- `grep -ni 'planning' Sources/App/SidebarView.swift Tests/BottomPanelActionTests.swift` returns
  nothing.
- `grep -ni 'planning' Sources/App/ContentView.swift` returns nothing (the surviving `:113` match is
  `planTask`, which that grep does not hit).

### T2: Rename the coordinator and list-view entry points onto the task terminal

**Files:** `Sources/App/WorkTaskCoordinator+Planning.swift` (renamed),
`Tests/PlanningLaunchCommandTests.swift` (renamed), `Sources/App/ContentView.swift`,
`Sources/App/WorkTaskListView.swift`, `Sources/App/WorkTaskCoordinator.swift`

**What it does.** Renames both files with `git mv` so history follows, renames the two coordinator
members and the list view's private forwarder, and rewords the toolbar tooltip.

- `git mv Sources/App/WorkTaskCoordinator+Planning.swift Sources/App/WorkTaskCoordinator+TaskTerminal.swift`
  and `git mv Tests/PlanningLaunchCommandTests.swift Tests/TaskTerminalLaunchCommandTests.swift`. No
  `project.yml` edit; `./scripts/ci.sh` runs `xcodegen generate`.
- In the renamed source file: `planTask(taskId:app:focusOnReveal:)` →
  `toggleTaskTerminal(taskId:app:focusOnReveal:)` (`:13`); `planningLaunchCommand()` →
  `taskTerminalLaunchCommand()` (declared `:44`, called `:22`). Doc comments at `:6` ("Toggles the
  planning terminal") and `:41` ("The command the planning terminal runs") say "task terminal".
  Leave the `WorkTaskNotification.planningTerminalOpened` post at `:38` alone — that is T3.
- `Sources/App/ContentView.swift:113`: `workTaskCoordinator.toggleTaskTerminal(taskId: taskId, app: app, focusOnReveal: true)`.
- `Sources/App/WorkTaskListView.swift`: `Button(action: toggleTaskTerminal)` (`:102`); `.help` becomes
  `taskTerminalOpen ? "Hide terminal" : "Show terminal"` (`:106`); `private func planTask()` →
  `private func toggleTaskTerminal()` (`:222`), forwarding to
  `workTaskCoordinator.toggleTaskTerminal(taskId: id, app: app)` (`:224`). The existing private
  `taskTerminalOpen` computed property is untouched and does not collide.
- In the renamed test file: class `PlanningLaunchCommandTests` → `TaskTerminalLaunchCommandTests`
  (`:9`); `tempRootPrefix` `"clearway-planning-launch"` → `"clearway-task-terminal-launch"` (`:11`);
  both `coordinator.planningLaunchCommand()` calls (`:18`, `:36`) follow the rename; the doc comment
  at `:4-7` is rewritten for the new names — it currently names "the planning terminal (the Plan icon
  and Cmd+J)" and `planTask`, and the Plan icon no longer exists, so it should say the toolbar toggle
  and ⌘J, and name `toggleTaskTerminal`.
- `Sources/App/WorkTaskCoordinator.swift:31`: comment "whatever the planning terminal just wrote" →
  "whatever the task terminal just wrote".

**Acceptance criteria.**
1. `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` and `Tests/TaskTerminalLaunchCommandTests.swift`
   exist; the two old paths do not; `git status` shows renames, not add+delete.
2. The only remaining `planning` match in the renamed source file is the notification post at `:38`.
3. `grep -ni 'planning\|planTask' Sources/App/WorkTaskListView.swift Sources/App/WorkTaskCoordinator.swift Tests/TaskTerminalLaunchCommandTests.swift`
   returns nothing, and `grep -n 'planTask' Sources/App/ContentView.swift` returns nothing.
4. The toolbar button's tooltip reads "Hide terminal" when the terminal is open and "Show terminal"
   when it is not.
5. Behaviour is unchanged: the `focusOnReveal` defaults, the `beginTaskLaunch`/`endTaskLaunch`
   bracketing, the `mainCommandProvider()` nil-check and the argument each call site passes are all
   as before.

**Verification.**
- `./scripts/ci.sh` passes. `TaskTerminalLaunchCommandTests` must appear in the run — if the two
  renamed files were invisible to the build, `xcodegen generate` did not pick them up.
- `git status --porcelain` shows the two paths as `R`.

**Depends on:** nothing (T1 is independent, but both touch `ContentView.swift`; run them in order to
keep the diffs readable).

### T3: Rename the notification constant and finish the Sources prose

**Files:** `Sources/App/WorkTaskWindow.swift`, `Sources/App/TaskDetailView.swift`,
`Sources/App/WorkTaskCoordinator+TaskTerminal.swift`, `Sources/App/WorkTask.swift`,
`Sources/App/WorkTaskManager.swift`

**What it does.** Renames the notification constant together with its raw string, updates its single
poster and single observer, and clears the last `planning` doc comments in `Sources/`.

- `Sources/App/WorkTaskWindow.swift`: `static let planningTerminalOpened = Notification.Name("planningTerminalOpened")`
  → `static let taskTerminalOpened = Notification.Name("taskTerminalOpened")` (`:18`); the doc
  comment at `:16` says "task terminal".
- `Sources/App/WorkTaskCoordinator+TaskTerminal.swift:38`: the post uses
  `WorkTaskNotification.taskTerminalOpened`.
- `Sources/App/TaskDetailView.swift`: the `.onReceive` publisher reads
  `WorkTaskNotification.taskTerminalOpened` (`:164`); the comment at `:166` says "beside the task
  terminal".
- `Sources/App/WorkTask.swift`: `:20` "stays out of the Planning backlog" → "out of the Tasks
  backlog"; `:73` "Planning task isn't cluttered" → "backlog task isn't cluttered" (decision 9 —
  this sentence names the pool).
- `Sources/App/WorkTaskManager.swift`: `:131` "without cluttering Planning" → "without cluttering
  Tasks"; `:134` "reserved for Planning (pre-worktree)" → "reserved for Tasks (pre-worktree)".

**Acceptance criteria.**
1. `grep -rn 'planningTerminalOpened' Sources Tests` returns nothing, and the new raw value is
   `"taskTerminalOpened"` — the constant and its string change together.
2. `git ls-files -- Sources | xargs grep -ni 'planning\|planTask'` returns nothing.
3. Behaviour is unchanged: still exactly one poster and one observer, the observer still guards on
   `note.object as? UUID == taskId` and still gates on `!previewMarkdown.isEmpty`.

**Verification.**
- `./scripts/ci.sh` passes.
- Manual: open the per-task terminal on a task with a non-empty body and confirm the editor flips to
  preview; open it on an empty-bodied task and confirm it does not.

**Depends on:** T2 (the renamed source file must exist).

### T4: Finish the prose in Tests and CLAUDE.md

**Files:** `Tests/WorkTaskCoordinatorTests.swift`, `Tests/TerminalManagerTests.swift`,
`Tests/WorkTaskManagerTests.swift`, `Tests/WorkTaskTests.swift`, `CLAUDE.md`

**What it does.** Comment-only edits. No test body, no assertion and no fixture string changes.

- `Tests/WorkTaskCoordinatorTests.swift:101`: "Whatever ran in the planning terminal" → "in the task
  terminal". The `"Pre-plan draft"` / `"Post-plan title"` / `"Full planned brief."` fixtures at
  `:93-146` and the `:89` doc comment's "pre-plan UI snapshot … post-plan disk" stay (decision 8).
- `Tests/TerminalManagerTests.swift:273`: "A plan launch awaits the resolved PATH" → "A task-terminal
  launch awaits the resolved PATH".
- `Tests/WorkTaskManagerTests.swift`: `:84` the assertion *message* "`.new` is planning-only; worktree
  tasks start in-progress" → "`.new` is backlog-only; worktree tasks start in-progress" (decision 9 —
  the message text only; the assertion itself is unchanged). `:248` "without surfacing it in
  Planning" → "in Tasks".
- `Tests/WorkTaskTests.swift:20`: "Planning tasks aren't cluttered" → "backlog tasks aren't
  cluttered" (decision 9).
- `CLAUDE.md:152`: "the Planning bottom panel needs `ghosttyApp.app`" → "the Tasks bottom panel needs
  `ghosttyApp.app`".

**Acceptance criteria.**
1. `git ls-files -- Sources Tests | xargs grep -ni 'planning\|planTask'` returns nothing, and no file
   under `Sources/` or `Tests/` has "Planning" in its name (both spec success criteria 3 and 4 — this
   is the task that closes them, given T1–T3 are in).
2. `grep -n 'Planning' CLAUDE.md` returns nothing.
3. The five "plan"-shaped fixture strings listed in decision 8 are byte-identical to base, and no
   assertion, fixture or test name changed — only comment and message text.

**Verification.**
- `./scripts/ci.sh` passes.
- `git diff --stat` for this task shows changes confined to the five files above, and
  `git diff` shows only comment lines and one assertion-message string.

**Depends on:** nothing.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A renamed file is invisible to the build because `xcodegen generate` did not run | Build or test host fails confusingly | T2's verification requires `TaskTerminalLaunchCommandTests` to appear in the `ci.sh` run; never hand-write an `xcodebuild` line |
| A blind find-and-replace of `plan` renames the protected fixture strings | Silent churn, decision 8 violated | T4 pins those strings byte-identical as an acceptance criterion; the renames in T1–T3 are per-identifier, not textual |
| A line grows past SwiftLint's limit when "planning" becomes the longer "task terminal" | Lint warning in new code | `ci.sh` runs SwiftLint; rewrap the comment rather than leaving a new warning |
| `default.profraw` appears after a Debug launch and is not gitignored | Blocks sign-off | Run `git status --porcelain` before committing and never `git add -A` |

## Out of scope

As the spec's Out of scope section states: no behaviour change of any kind, no `project.yml` edit, no
edits to `docs/superpowers/specs/2026-09-14-remove-workflows.md` or its plan, no renaming of the
"plan"/"planned" test fixture strings, no other `WorkTaskCoordinator` member, and no work on the
`WorktreeGroupStore.openFileWatcher` fd leak.

## Build log

### T1: Rename the sidebar destination to Tasks

| File | State |
| --- | --- |
| `Sources/App/ContentView.swift` | `DetailSelection.planning` → `.tasks` (declaration + 10 references), `BottomPanelAction.planningTerminal` → `.taskTerminal` (declaration + 2 references), prose "Planning" → "Tasks" at the `newTaskAction` doc comment, the synchronous-write comment, and the `commitListsColumnWidth` doc comment. `planTask` call at `:113` left for T2. |
| `Sources/App/SidebarView.swift` | `planningRow` → `tasksRow` (declaration + `body` reference), label `"Planning"` → `"Tasks"`, `.tag(DetailSelection.tasks)`. Icon logic and `⌃1` hint unchanged. |
| `Tests/BottomPanelActionTests.swift` | `testPlanningHostsThePlanningTerminal` → `testTasksHostTheTaskTerminal`; body `XCTAssertEqual(action(.tasks), .taskTerminal)`. |

Renames were applied per identifier with word-boundary `perl -pi -e`, `planningTerminal` before
`planning`, so no textual over-reach. Every replacement string is shorter than what it replaced, so
no line could cross SwiftLint's length limit.

**Evidence.** This task is a pure rename with no new behaviour, so there is no regression test to
watch fail: the compiler is the oracle. `DetailSelection` is exhaustively switched in
`bottomPanelAction(for:)` and matched in eight `ContentView` sites, so a missed reference is a build
error rather than a silent behaviour change. `BottomPanelActionTests` continues to pin the
`.tasks → .taskTerminal` mapping, which is the only rule the rename could have disturbed.

**Deviations from the plan.** None to the diff. One environment deviation: the worktree had never
been provisioned — `ghostty/` was an empty, uninitialized submodule directory, so the first
`./scripts/ci.sh` failed with `Unable to resolve module dependency: 'GhosttyKit'` before compiling
any Swift. Fixed by running the project's own `./scripts/worktree-post-create.sh`, which copies the
primary worktree's built `ghostty/` in and writes the gitignored `BuildInfo.generated.swift`. No
tracked file was touched by it.

**Gate.** `./scripts/ci.sh` — exit 0. `xcodegen generate`, SwiftLint clean (no violations),
build succeeded, `Executed 306 tests, with 0 failures (0 unexpected)`.

**Acceptance criteria.** All met.
1. Sidebar's first row reads "Tasks" with the same `tray`/`tray.full` logic and `⌃1` hint.
2. `grep -ni 'planning' Sources/App/ContentView.swift Sources/App/SidebarView.swift Tests/BottomPanelActionTests.swift`
   returns nothing; `grep -n 'planTask' Sources/App/ContentView.swift` returns only `:113`.
3. `DetailSelection` is still `Hashable`-only with the same three cases and `bottomPanelAction(for:)`
   maps the same selections to the same panels.

### T2: Rename the coordinator and list-view entry points onto the task terminal

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator+Planning.swift` → `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | `git mv`. `planTask(taskId:app:focusOnReveal:)` → `toggleTaskTerminal(…)`, `planningLaunchCommand()` → `taskTerminalLaunchCommand()` (declaration + call). Doc comments at `:6` and `:41` say "task terminal". The `WorkTaskNotification.planningTerminalOpened` post at `:38` is untouched — T3. |
| `Tests/PlanningLaunchCommandTests.swift` → `Tests/TaskTerminalLaunchCommandTests.swift` | `git mv`. Class → `TaskTerminalLaunchCommandTests`; `tempRootPrefix` → `"clearway-task-terminal-launch"`; both helper calls follow the rename; the `:4-7` doc comment rewritten — it named the removed Plan icon and `planTask`, and now names the toolbar toggle, ⌘J and `toggleTaskTerminal`. |
| `Sources/App/ContentView.swift` | `:113` calls `workTaskCoordinator.toggleTaskTerminal(taskId:app:focusOnReveal:)`. |
| `Sources/App/WorkTaskListView.swift` | `Button(action: toggleTaskTerminal)`; `.help` → `"Hide terminal"` / `"Show terminal"`; `private func planTask()` → `toggleTaskTerminal()`, forwarding to the renamed coordinator method. The private `taskTerminalOpen` property is untouched and does not collide. |
| `Sources/App/WorkTaskCoordinator.swift` | `:31` comment "the planning terminal just wrote" → "the task terminal just wrote". |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `ci.sh`; the two file references follow the renames. No `project.yml` edit (assumption 4). |

Identifier renames were applied with word-boundary `perl -pi -e`, never textually, so nothing outside
the two names moved. No replacement pushed a line past SwiftLint's 200-column warning (the longest
touched line, `ContentView.swift:113`, is 101 columns).

**Evidence.** A pure rename with no new behaviour, so there is no regression test to watch fail — the
compiler is the oracle, as in T1. Every renamed member is called from a different file
(`ContentView` and `WorkTaskListView` both reach the coordinator), so a missed call site is a build
error, not a silent behaviour change. The tooltip and file renames are covered by the criteria
checks below rather than by a test.

The one risk the compiler cannot catch — a renamed file falling out of the build because
`xcodegen generate` missed it — was checked directly rather than by test count alone:

```
$ xcrun xcresulttool get test-results tests --path …/Test-ClearwayTests-2026.09.14_22-30-47--0400.xcresult
  "nodeIdentifier" : "TaskTerminalLaunchCommandTests/testBareMainTerminalCommandWhenConfigured()", "result" : "Passed"
  "nodeIdentifier" : "TaskTerminalLaunchCommandTests/testNoConfiguredCommandOpensAPlainShell()",   "result" : "Passed"
```

**Deviations from the plan.** None.

**Gate.** `./scripts/ci.sh` — exit 0. `xcodegen generate`, SwiftLint clean, build succeeded,
`Executed 306 tests, with 0 failures (0 unexpected)` — the same 306 as T1, so neither renamed file
dropped out of the build. `git status --porcelain` clean apart from the tracked files above; no
untracked `default.profraw`.

**Acceptance criteria.** All met.
1. Both new paths exist, both old paths are gone, and `git status --porcelain` shows `R` for each.
2. The only `planning` match left in the renamed source file is the notification post at `:38`.
3. `grep -ni 'planning\|planTask' Sources/App/WorkTaskListView.swift Sources/App/WorkTaskCoordinator.swift Tests/TaskTerminalLaunchCommandTests.swift`
   returns nothing, and `grep -n 'planTask' Sources/App/ContentView.swift` returns nothing.
4. The toolbar tooltip reads "Hide terminal" when open, "Show terminal" when not.
5. Behaviour unchanged: the `focusOnReveal: Bool = false` default, the `beginTaskLaunch` /
   `endTaskLaunch` bracketing, the `mainCommandProvider()` nil-check and every call site's arguments
   are byte-identical apart from the two names.

### T3: Rename the notification constant and finish the Sources prose

| File | State |
| --- | --- |
| `Sources/App/WorkTaskWindow.swift` | `planningTerminalOpened` → `taskTerminalOpened`, constant and raw string together (`Notification.Name("taskTerminalOpened")`). Doc comment says "task terminal". |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | The single poster at `:38` reads `WorkTaskNotification.taskTerminalOpened`. Nothing else in the file moved. |
| `Sources/App/TaskDetailView.swift` | The single `.onReceive` publisher reads the renamed constant; the comment says "beside the task terminal". The `note.object as? UUID == taskId` guard and the `!previewMarkdown.isEmpty` gate are byte-identical. |
| `Sources/App/WorkTask.swift` | `:20` "out of the Planning backlog" → "out of the Tasks backlog" (names the destination); `:73` "a fresh Planning task" → "a fresh backlog task" (names the pool — decision 9). |
| `Sources/App/WorkTaskManager.swift` | `:131` "without cluttering Planning" → "Tasks"; `:134` "reserved for Planning (pre-worktree)" → "reserved for Tasks (pre-worktree)". |

The constant rename was applied with a word-boundary `perl -pi -e` across exactly the three files
that mention it, the raw string with a separate literal substitution, so the two could not drift
apart. Every replacement is shorter than what it replaced, so no line could cross SwiftLint's limit.

**Evidence.** A pure rename with no new behaviour, so there is no regression test to watch fail —
the compiler is the oracle, as in T1 and T2. `WorkTaskNotification.taskTerminalOpened` is referenced
from two files other than its declaration, so a missed reference is a build error rather than a
silent behaviour change. The one thing the compiler could not catch — the constant and its raw
string drifting apart — is settled by the diff: both lines changed in the same hunk, and
`grep -rn 'planningTerminalOpened' Sources Tests` returns nothing.

Note the notification is posted and observed in-process only, so the raw-string change carries no
compatibility risk (spec assumption 2).

**Deviations from the plan.** None.

**Gate.** `./scripts/ci.sh` — exit 0. `xcodegen generate`, SwiftLint clean (no violations),
build succeeded, `Executed 306 tests, with 0 failures (0 unexpected)` — the same 306 as T1 and T2.
`git status --porcelain` shows only the five files above; no untracked `default.profraw`.

**Acceptance criteria.** All met.
1. `grep -rn 'planningTerminalOpened' Sources Tests` returns nothing and the raw value is
   `"taskTerminalOpened"`; the constant and its string changed together.
2. `git ls-files -- Sources | xargs grep -ni 'planning\|planTask'` returns nothing.
3. Behaviour unchanged: still exactly one poster (`WorkTaskCoordinator+TaskTerminal.swift:38`) and
   one observer (`TaskDetailView.swift:164`); the observer still guards on
   `note.object as? UUID == taskId` and still gates on `!previewMarkdown.isEmpty`.

### T4: Finish the prose in Tests and CLAUDE.md

| File | State |
| --- | --- |
| `Tests/WorkTaskCoordinatorTests.swift` | `:101` "ran in the planning terminal" → "ran in the task terminal". The `"Pre-plan draft"` / `"Post-plan title"` / `"Full planned brief."` fixtures and the `:89` doc comment's "pre-plan … post-plan" are untouched (decision 8). |
| `Tests/TerminalManagerTests.swift` | `:273` "A plan launch" → "A task-terminal launch". The three-line doc comment was rewrapped so no line grows past the file's ~100-column convention. |
| `Tests/WorkTaskManagerTests.swift` | `:84` assertion *message* "`.new` is planning-only" → "`.new` is backlog-only" (decision 9); the assertion itself is byte-identical. `:248` "surfacing it in Planning" → "in Tasks". |
| `Tests/WorkTaskTests.swift` | `:20-21` doc comment reworded off "Planning tasks aren't cluttered" — see the deviation below. |
| `Sources/App/WorkTask.swift` | `:72-73` the doubled "backlog" from T3 tightened — see the deviation below. |
| `CLAUDE.md` | `:152` "the Planning bottom panel needs `ghosttyApp.app`" → "the Tasks bottom panel needs `ghosttyApp.app`". |

**Evidence.** Comment-only edits plus one assertion-message string: there is no behaviour to regress
and therefore no regression test to watch fail. The compiler is not an oracle for prose either, so
the guarantee comes from the diff being closed under inspection — `git diff -U0` is six hunks, every
changed line a `//`, `///` or Markdown line except `WorkTaskManagerTests.swift:84`, whose change is
confined to the string literal inside `XCTAssertEqual`'s message argument. The five protected
fixture strings from decision 8 were re-grepped after the edits and all 24 occurrences across
`TaskEditorBuffersTests`, `WorkTaskCoordinatorTests`, `WorkTaskManagerTests` and
`WorkTaskManagerWatcherTests` are byte-identical to base.

**Deviations from the plan.** Two, both wording:

1. `Sources/App/WorkTask.swift:72-73` is not in T4's file list. T3's edit left the sentence saying
   "backlog" twice — "an absent line means backlog (no worktree), so a fresh **backlog** task isn't
   cluttered…" — where the second use restates the clause that just defined it. Dropped to "so a
   fresh task isn't cluttered", which keeps decision 9's word exactly once, where it does work.
2. `Tests/WorkTaskTests.swift:20` was planned as "Planning tasks aren't cluttered" → "backlog tasks
   aren't cluttered". That produces the same repetition: the sentence already opens "A backlog task
   (no worktree) serializes without a `worktree:` line". Written as "— so it isn't cluttered with
   `worktree: null` —" instead. Decision 9's intent is satisfied (the sentence names the pool as
   "backlog", once, and never says "Planning"); only the second mention is elided.

**Gate.** `./scripts/ci.sh` — exit 0, run after the last edit. `xcodegen generate`, SwiftLint clean
(no violations reported), build succeeded, `Executed 306 tests, with 0 failures (0 unexpected)` — the
same 306 as T1–T3. `git status --porcelain` shows only the six files above; no untracked
`default.profraw`.

**Acceptance criteria.** All met.
1. `git ls-files -- Sources Tests | xargs grep -ni 'planning\|planTask'` returns nothing (exit 1),
   and `git ls-files -- Sources Tests | grep -i planning` returns nothing — closing spec success
   criteria 3 and 4.
2. `grep -n 'Planning' CLAUDE.md` returns nothing.
3. The five decision-7 fixture strings are byte-identical to base; no assertion, fixture or test name
   changed. `git diff --stat` is 6 files, 10 insertions, 10 deletions.

### Simplify

`/simplify` over `b049206...HEAD` (reuse, simplification, efficiency, altitude) found nothing to
apply: the two findings raised — the coordinator's `toggleTaskTerminal` sharing a name with
`TerminalManager.toggleTaskTerminal`, and the unqualified "Hide terminal" / "Show terminal" tooltip —
are both already settled in the spec (decisions 4 and 2), so no code changed.

**Gate.** `./scripts/ci.sh` — exit 0. `xcodegen generate`, SwiftLint clean, build succeeded,
`Executed 306 tests, with 0 failures (0 unexpected)`.

### Review

`/pr-review-toolkit:review-pr code tests errors types` over `b049206...HEAD`, four agents from fresh
contexts. **No Critical and no in-scope Important findings.** The `code` pass returned nothing at any
severity; `types` returned no Critical or Important.

Independently re-verified: spec success criteria 3 and 4 hold
(`git ls-files -- Sources Tests | xargs grep -ni 'planning\|planTask'` exits 1, no "Planning" filename),
and repo-wide the only surviving matches are this change's own spec and plan. `project.pbxproj` swaps
both renamed files in every `PBXBuildFile`, `PBXFileReference`, group and `Sources` build-phase
section, so neither file was dropped from a target. `taskTerminalOpened` has one declaration, one
poster and one observer; `DetailSelection` reaches no `Codable`, `AppStorage`, `SceneStorage` or
`UserDefaults` path, so the case rename writes nothing to disk. `WorkTask.ReservedStatus` and
`SidePanelTab.task`'s persisted `"Task"` rawValue are byte-identical to base.

Three findings restated decisions the spec already settled — the coordinator/`TerminalManager`
`toggleTaskTerminal` name (decision 4) and the unqualified tooltip (decision 2), the latter raised by
both `errors` and `types`. The table wins; they are recorded as follow-ups below, not reopened.

**Applied.** One fix, documentation only: five citations in this plan read "decision 7" where the
spec numbers the protected-fixture-strings rule **8** (7 is the `DetailSelection`-persistence row), so
an auditor following the reference landed on the wrong row. No Swift changed, so the gate recorded
above still stands — `docs/` is outside the `Sources`/`Tests` globs in `project.yml`.

**Follow-ups, each out of scope here because this task forbids behaviour changes.**

1. The `.taskTerminal` `PanelToggle` gate (`ContentView.swift:111`) carries `selectedTaskId` and
   `ghosttyApp.app` but not the task-existence check its action opens with
   (`WorkTaskCoordinator+TaskTerminal.swift:14`), so after deleting the selected task — neither delete
   handler at `WorkTaskListView.swift:141`/`:159` clears `selection` — ⌘J stays enabled and does
   nothing. The toolbar door for the same action does gate on existence via `selectedTask`. Identical
   at base `b049206`; the rename rewrote only the case label and the callee on those lines.
2. `WorkTaskManager.deleteTask` (`:245`) drops the `removeItem` error with `try?` and no log, so a
   failed delete dismisses the alert and the task returns on the next watcher pass.
3. The sidebar destination "Tasks" and the worktree aside tab "Task"
   (`ContentViewHelpers.swift:32`) now differ only by a plural. Retitling the aside is a migration,
   not a rename: its rawValue is persisted through `setSidePanelTab` and parsed back by string.
