# Rename Planning to Tasks

**Date:** 2026-09-14
**Base:** b049206589b9eb8e94a0630de38c7e3cebf5a1db
**PR:** #215

The sidebar's first destination is still called "Planning", a name from the era when Clearway ran a
planning agent ahead of the work. PR #214 removed the workflow engine and that agent; what is left
is a task backlog, and the destination is where work starts rather than where it is planned. This
change renames the row to "Tasks" and carries the rename through every `planning`-named identifier,
file, test and doc comment behind it. It is a pure rename: no behaviour, no persisted format and no
keyboard shortcut changes.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Is the scope the visible label only, or the code too? | Both. The sidebar row becomes "Tasks" **and** every `planning`-named code identifier, file name, test name, doc comment and CLAUDE.md reference follows. | Operator |
| 2 | What does the bottom-panel toggle's tooltip say? | "Show terminal" / "Hide terminal" (`WorkTaskListView.swift:106`), dropping the qualifier rather than replacing it — the button lives in the task list's own toolbar, so "task terminal" would restate its context. | Operator |
| 3 | What noun replaces "planning" in the terminal's identifiers? | **`taskTerminal`.** `TerminalManager` already names this exact surface that way — `isTaskTerminalVisible`, `toggleTaskTerminal`, `openTaskTerminalWithCommand`, `beginTaskLaunch`, `existingTaskSurface` (`WorkTaskCoordinator+Planning.swift:17-33`), and `WorkTaskListView.taskTerminalOpen` (`:217`). Renaming onto the vocabulary already in the layer below is the only choice that leaves one name for one thing. | Spec author |
| 4 | What does `WorkTaskCoordinator.planTask` become? | `toggleTaskTerminal(taskId:app:focusOnReveal:)`. It toggles: it hides an open terminal and otherwise opens one. The name repeats `TerminalManager.toggleTaskTerminal(for:app:projectPath:)`, which is correct — the coordinator's is the app-level entry point that resolves the launch command first, and every call site is qualified by its receiver. `openOrHideTaskTerminal` was rejected: longer, and it names the mechanism rather than the operation. | Spec author |
| 5 | What does `WorkTaskListView.planTask()` become? | `toggleTaskTerminal()`, matching the coordinator method it forwards to. No collision: `WorkTaskListView`'s other private helpers are `taskTerminalOpen` and `startTask(_:)`. | Spec author |
| 6 | Does the notification's raw string change with its constant? | Yes. `Notification.Name("planningTerminalOpened")` → `Notification.Name("taskTerminalOpened")`. The name never crosses a process or a disk boundary — it is posted in `WorkTaskCoordinator` and observed in `TaskDetailView` only (`TaskDetailView.swift:164`) — so a stale raw value would be dead weight, not compatibility. | Spec author |
| 7 | Is `DetailSelection` persisted anywhere that renaming `.planning` would break? | No, so `.planning` → `.tasks` is free. Verified: the enum is `Hashable` only, never `Codable`, and its only storage is the two `@State` properties in `ContentView` (`:65-66`). See Assumptions. | Spec author |
| 8 | Do "plan"-shaped test fixture strings get renamed? | No. `"Pre-plan draft"`, `"Post-plan title"`, `"Planned title"`, `"Full planned brief."`, `"Planned via watcher"` (`WorkTaskCoordinatorTests.swift:93-146`, `WorkTaskManagerTests.swift:547-560`, `WorkTaskManagerWatcherTests.swift:27-38`, `TaskEditorBuffersTests.swift:144-270`) are fixture payloads describing an agent having planned the task — still an accurate description of what runs in that terminal. They are not references to the destination. Renaming them is churn with no meaning change. Doc comments in those same files that name the *terminal* or the *destination* are in scope (see Files). | Spec author |
| 9 | Where "Planning" reads as the pre-worktree pool rather than the view, what word wins? | "Tasks" where the sentence names the destination; the project's existing word **"backlog"** where it names the pool, because "a fresh Tasks task" and "`.new` is Tasks-only" do not read. Exact sites listed in Files. | Spec author |
| 10 | Do the shipped `docs/superpowers/` spec and plan for #214 get updated? | No. Those documents are the record of what shipped on their date and are never edited after merge (the spec-stage convention states this). Their "Planning" references stay. | Spec author |
| 11 | Does anything about keyboard shortcuts change? | No. ⌃1 still selects the destination, ⌘J still toggles the panel. `AppKeyboardShortcuts.claims` matches on `"1"…"2"` by character (`:33-40`) and names no destination, so it needs no edit and no new retired-shortcut pin. | Spec author |

## Assumptions

Each verified against the codebase at base `b049206`.

1. **`DetailSelection` is never serialized.** Declared `enum DetailSelection: Hashable` with no
   `Codable` conformance (`Sources/App/ContentView.swift:18`); its only holders are
   `@State private var detailSelection` and `@State private var sidebarSelection`
   (`:65-66`). `grep -rn 'DetailSelection' Sources Tests` reaches only `ContentView.swift`,
   `SidebarView.swift` and `Tests/BottomPanelActionTests.swift`. Renaming `.planning` therefore
   cannot invalidate stored state.
2. **`WorkTaskNotification.planningTerminalOpened` has exactly one poster and one observer.**
   Posted at `Sources/App/WorkTaskCoordinator+Planning.swift:38`, observed at
   `Sources/App/TaskDetailView.swift:164`. No other match for `planningTerminalOpened` in `Sources`
   or `Tests`.
3. **"Planning" appears in exactly one user-visible string.** `destinationRow("Planning", …)` at
   `Sources/App/SidebarView.swift:189`. The only other user-visible planning copy is the tooltip
   pair at `Sources/App/WorkTaskListView.swift:106`, which decision 2 rewords. No `Resources/`,
   `README.md`, `scripts/` or `.github/` file contains the word (grep: no match).
4. **`xcodegen` picks up Swift files by directory, not by name.** `project.yml:25-26` lists
   `sources: - path: Sources` and `:303-304` `- path: Tests`, so renaming a file needs
   `xcodegen generate` (which `./scripts/ci.sh` runs) and no `project.yml` edit.
5. **Nothing outside the app reads these names.** `.work/state.json` (which contains a `planTask`
   key) is gitignored via `~/.gitignore:34`, and `.clearway/TASK.md` is untracked; both are session
   state, not code.
6. **The Ctrl+digit claim is destination-count-based, not destination-name-based.**
   `Sources/App/AppKeyboardShortcuts.swift:33-40` matches scalars `"1"…"2"`. Unaffected.

No empirical probes were needed; nothing was written to the repo outside this spec.

## Objective

After this change, a user opening Clearway sees **Tasks** where the sidebar said Planning, and a
developer grepping for `planning` in `Sources/` and `Tests/` finds nothing. Behaviour is byte-for-byte
identical.

### Success criteria

1. The sidebar's first row reads "Tasks" with the same icon logic and `⌃1` hint.
2. The task list's bottom-panel toolbar button reads "Show terminal" / "Hide terminal".
3. `git ls-files -- Sources Tests | xargs grep -ni 'planning\|planTask'` returns nothing.
4. No file under `Sources/` or `Tests/` has "Planning" in its name.
5. `./scripts/ci.sh` passes: `xcodegen generate`, SwiftLint clean, build and the full test suite.
6. Manually: ⌃1 reaches the destination, ⌘J and the toolbar button open and hide the per-task
   terminal, and opening it still flips a non-empty task's editor to preview.

## Verification

```bash
./scripts/ci.sh
```

The project's one runner of the test suite; it also runs `xcodegen generate`, without which the two
renamed files would be invisible to the build. It is both the per-task regression check and the
sign-off gate here.

## Files this change touches

### Renamed files

| From | To |
| --- | --- |
| `Sources/App/WorkTaskCoordinator+Planning.swift` | `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` |
| `Tests/PlanningLaunchCommandTests.swift` | `Tests/TaskTerminalLaunchCommandTests.swift` |

### Identifier renames

| From | To | Declared at |
| --- | --- | --- |
| `DetailSelection.planning` | `DetailSelection.tasks` | `ContentView.swift:19` |
| `BottomPanelAction.planningTerminal` | `BottomPanelAction.taskTerminal` | `ContentView.swift:43` |
| `WorkTaskCoordinator.planTask(taskId:app:focusOnReveal:)` | `toggleTaskTerminal(taskId:app:focusOnReveal:)` | `WorkTaskCoordinator+Planning.swift:13` |
| `WorkTaskCoordinator.planningLaunchCommand()` | `taskTerminalLaunchCommand()` | `WorkTaskCoordinator+Planning.swift:44` |
| `WorkTaskNotification.planningTerminalOpened` (raw `"planningTerminalOpened"`) | `taskTerminalOpened` (raw `"taskTerminalOpened"`) | `WorkTaskWindow.swift:18` |
| `SidebarView.planningRow` | `tasksRow` | `SidebarView.swift:187` |
| `WorkTaskListView.planTask()` | `toggleTaskTerminal()` | `WorkTaskListView.swift:222` |
| `PlanningLaunchCommandTests` | `TaskTerminalLaunchCommandTests` | `PlanningLaunchCommandTests.swift:9` |
| `tempRootPrefix` `"clearway-planning-launch"` | `"clearway-task-terminal-launch"` | `PlanningLaunchCommandTests.swift:11` |
| `testPlanningHostsThePlanningTerminal` | `testTasksHostTheTaskTerminal` | `BottomPanelActionTests.swift:23` |

### Call sites and copy

| File | Change |
| --- | --- |
| `Sources/App/ContentView.swift` | `.planning` → `.tasks` at `:19`, `:34`, `:65`, `:66`, `:150`, `:262`, `:362`, `:423`, `:631`, `:722`, `:905`; `.planningTerminal` → `.taskTerminal` at `:34`, `:43`, `:110`; `planTask` call → `toggleTaskTerminal` at `:113`; prose "Planning" → "Tasks" at `:145`, `:149`, `:602` (`:614` already says Tasks) |
| `Sources/App/SidebarView.swift` | `planningRow` → `tasksRow` (`:73`, `:187`); label `"Planning"` → `"Tasks"` (`:189`); `.tag(DetailSelection.tasks)` (`:190`) |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | Method and helper renamed; doc comments at `:6`, `:41` say "task terminal"; notification constant updated at `:38` |
| `Sources/App/WorkTaskCoordinator.swift` | Comment `:31` "the planning terminal just wrote" → "the task terminal just wrote" |
| `Sources/App/WorkTaskListView.swift` | `Button(action: toggleTaskTerminal)` (`:102`); `.help` → "Hide terminal" / "Show terminal" (`:106`); private func renamed (`:222-224`) |
| `Sources/App/TaskDetailView.swift` | Observer reads `WorkTaskNotification.taskTerminalOpened` (`:164`); comment `:166` "beside the task terminal" |
| `Sources/App/WorkTaskWindow.swift` | Constant renamed with its raw value; doc comment `:16` "task terminal" |
| `Sources/App/WorkTask.swift` | `:20` "out of the Planning backlog" → "out of the Tasks backlog"; `:73` "a fresh Planning task" → "a fresh backlog task" (decision 9) |
| `Sources/App/WorkTaskManager.swift` | `:131` "without cluttering Planning" → "Tasks"; `:134` "reserved for Planning (pre-worktree)" → "reserved for Tasks (pre-worktree)" |
| `Tests/BottomPanelActionTests.swift` | Test renamed; `action(.tasks)` == `.taskTerminal` (`:23-25`) |
| `Tests/TaskTerminalLaunchCommandTests.swift` | Class, prefix and the doc comment at `:4-7` — which names "the planning terminal (the Plan icon and Cmd+J)" and `planTask` — rewritten for the new names; the Plan icon no longer exists, so the doc says the toolbar toggle and ⌘J |
| `Tests/WorkTaskCoordinatorTests.swift` | `:101` comment "ran in the planning terminal" → "task terminal". Fixture strings at `:93-146` untouched (decision 8) |
| `Tests/TerminalManagerTests.swift` | `:273` "A plan launch awaits the resolved PATH" → "A task-terminal launch awaits …" |
| `Tests/WorkTaskManagerTests.swift` | `:84` "`.new` is planning-only" → "`.new` is backlog-only"; `:248` "surfacing it in Planning" → "in Tasks" |
| `Tests/WorkTaskTests.swift` | `:20` "Planning tasks aren't cluttered" → "backlog tasks aren't cluttered" |
| `CLAUDE.md` | `:152` "the Planning bottom panel needs `ghosttyApp.app`" → "the Tasks bottom panel …" |

## Out of scope

- **Behaviour of any kind.** No shortcut, no panel rule, no launch path, no file format changes.
  A diff that changes what the app does is a defect in this task.
- **`project.yml`.** Sources are globbed by directory (assumption 4).
- **`docs/superpowers/specs/2026-09-14-remove-workflows.md` and its plan.** Shipped records,
  never edited after merge (decision 10).
- **Test fixture strings containing "plan"/"planned"** (decision 8).
- **`WorkTaskCoordinator.startTask` / `completePendingLaunch` and the rest of the coordinator.**
  Only the two members named above move.
- **The `WorktreeGroupStore.openFileWatcher` fd leak** and every other known follow-up recorded in
  CLAUDE.md. Untouched here.
