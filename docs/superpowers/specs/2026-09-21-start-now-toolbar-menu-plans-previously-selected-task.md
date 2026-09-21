# Start Now toolbar menu plans the previously selected task

**Date:** 2026-09-21
**Base:** 8d032a4ddb48fc35f97eb5e4618efa3de44ac48c (Require pipeline load generators to bound their own lifetime (#251))

Picking an agent command from the Start Now toolbar dropdown plans whichever task was selected when
that menu was first built, not the one selected now. AppKit keeps the toolbar's `NSMenu` and the
`Button` closures built with it alive across selection changes, and each closure captured a
`WorkTask` value, so planning task B after having planned task A warns that A's terminal is busy,
replaces A's surface, kills the agent running there, and snaps the selection back to A. This change
stops the items capturing a task: the item passes only *where* its task comes from (a row, or the
selection) and the task itself is resolved when the item is clicked.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | Lazy resolution or force the menu to rebuild with `.id(selection)`? | Lazy resolution. | The task brief settles it: `.id(selection)` papers over the stale capture by throwing the menu away, and leaves the next closure that captures a value to reintroduce the bug. Removing the capture is the durable fix. |
| D2 | How does `startNowItems` distinguish the two call sites once it no longer takes a task? | It takes the *row*: `startNowItems(for row: WorkTask?)`, where `nil` means "the toolbar, whose items plan the current selection". The row context menu passes its own `task`. | One parameter, no new type, and the toolbar call site literally carries no task to go stale. A closure parameter (`() -> WorkTask?`) would work too but leaves the lateness as an unenforced convention inside each caller's closure body and gives the test nothing to name (D4). |
| D3 | Where is the target resolved? | Inside the item's action closure, from `selectedTask` — the view's existing computed property, which reads the live `selection` binding and the live `workTaskManager.tasks`. | This is the shape the two neighbouring toolbar menus already use and neither has the bug: the More-actions Delete item reads `selectedTask` inside its closure (`WorkTaskListView.swift:121-123`) and the split button's primary half reads `startableTask` inside its closure (`WorkTaskListView.swift:83-85`). The dropdown becomes consistent with the file rather than novel. |
| D4 | What is the testable extraction, given the acceptance criteria require a unit test? | `static func startNowTarget(row: WorkTask?, selection: WorkTask?) -> WorkTask?` on `WorkTaskCoordinator`, in `WorkTaskCoordinator+TaskTerminal.swift` beside `planNeedsConfirmation`. Both the build-time gate and the item action call it. | The criteria name `WorkTaskCoordinator` as the home, and that file already holds every pure rule this menu reads (`planNeedsConfirmation`, `taskTerminalToggle`, `planWorkingDirectory`). Keeping the rule out of the `@ViewBuilder` is also what makes the row-wins-over-selection precedence reviewable in one place. |
| D5 | What the test can and cannot prove. | It pins the rule — a row item plans its row, an item with no row plans the selection it is handed, the function holds no state so it can never return an earlier selection — and it cannot pin that the call site sits inside the action closure. | Laziness at a SwiftUI call site is not observable from XCTest: this suite's own docstring already records that `planTask` and `toggleTaskTerminal` are unreachable because they take a non-optional `ghostty_app_t` (`Tests/TaskTerminalLaunchCommandTests.swift:7-9`), and there is no view-inspection dependency in the project. The call site is guarded instead by the `startNowItems` docstring and the `Sources/App/CLAUDE.md` note (D8). Recorded here so review does not re-open it. |
| D6 | Does the row context menu keep passing a `WorkTask` value rather than an id? | Yes. | Only the id travels: `planCommand` discards the passed value's fields and re-reads `workTaskManager.freshTask(id: task.id)` before substituting placeholders (`WorkTaskCoordinator.swift:186-187`). A row's id cannot go stale for that row, and the brief states the row path is already correct. |
| D7 | Does the "commands omitted when nothing selected" gate stay? | Yes, unchanged. | The brief suggests lazy resolution removes the need for it. It does not: if the menu was built with nothing selected the items are absent, so there is nothing to resolve late, and only a structural-identity change puts them back. Rendering them unconditionally instead would trade the omission for a silently dead menu item, which is worse than the one knowingly no-op control the app already documents. |
| D8 | Documentation. | Rewrite the `startNowItems` docstring to add the stale-capture rule beside the stale-enabled-flag rule it already records, and extend the Start Now paragraph in `Sources/App/CLAUDE.md` (lines 104-118) with the same. | The existing docstring already names AppKit's menu retention as the hazard for the enabled flag (`WorkTaskListView.swift:247-250`); the captured task is the second face of the same behaviour and belongs in the same note. This is the only durable guard on the call site (D5). |
| D9 | Test file. | Extend `Tests/TaskTerminalLaunchCommandTests.swift`, under its existing `// MARK: - Confirming a plan` section. | That suite is already scoped to "the pure rules behind the doors onto the task terminal" and already pins `planNeedsConfirmation` "for the Start Now dropdown". A new file would add nothing but a second place to look. |
| D10 | Any change to the confirmation dialog, `plan`, `runPlan`, or `planTask`? | No. | They are correct once the right task reaches them. `plan` takes the task it is given; `runPlan`'s `selection = task.id` is deliberate (`WorkTaskListView.swift:279-284`) and, with the right task, is what keeps the selection on B instead of snapping to A. |

## Assumptions

Each was verified by reading the source at the base commit. No probe scripts were written — in the
repo or in the scratchpad; every check below is a read.

**A1 — The toolbar's dropdown items capture a `WorkTask` value.** The toolbar `Menu` builds its
content as `startNowItems(for: selectedTask)` (`Sources/App/WorkTaskListView.swift:78-87`), and each
item is `Button(command.name) { plan(task, using: command) }` over the `task` bound by the enclosing
`if let task` (`WorkTaskListView.swift:260-264`). The task is a value, fixed when the closure was
formed.

**A2 — AppKit keeps that menu, and therefore those closures, across selection changes.** Recorded in
the project's own notes as observed behaviour: a toolbar menu "first built with nothing selected kept
its commands greyed out after a task was selected", and only "changing the item set changes the
content's structural identity, which rebuilds the menu"
(`Sources/App/WorkTaskListView.swift:247-250`, `Sources/App/CLAUDE.md:114-118`). Selecting a
different task changes no item, so the menu survives with its closures.

**A3 — A stale closure's `selection` binding still reads and writes the live value.** `selection` is
`Binding<UUID?>` over `@State private var selectedTaskId` in `ContentView`
(`ContentView.swift:81`, passed at `ContentView.swift:755`). The reported symptom is itself the
proof of write-through: `runPlan` sets `selection = task.id` from inside the stale closure
(`WorkTaskListView.swift:284`) and the selection visibly jumps back to A. Reads go through the same
storage, so `selectedTask` evaluated inside the closure yields the *current* selection. This is the
mechanism the whole fix rests on.

**A4 — `workTaskManager` in a stale view copy is the live object.** It is an `@EnvironmentObject`
(`WorkTaskListView.swift:6`) over a long-lived reference type, so a copied view struct holds the same
manager and `tasks` reflects the current list.

**A5 — Every downstream step is keyed by the task id that arrives from the menu.**
`plan` gates on `terminalManager.taskHasActiveProcess(task.id)` (`WorkTaskListView.swift:269-277`),
`runPlan` sets `selection = task.id` (`:282-286`), and `planTask` runs against
`taskId = task.id` (`WorkTaskCoordinator+TaskTerminal.swift:101-117`). Nothing downstream re-derives
the task, so the wrong id is carried end to end.

**A6 — Planning destroys the target's existing surface.** `run(_:inTaskTerminalFor:app:directory:)`
calls `openTaskTerminal` (`TerminalManager+Commands.swift:66,79`), which removes and closes any
surface the task already had before creating the new one
(`TerminalManager+TaskTerminals.swift:76-99`). This is why the stale id is destructive rather than
merely wrong, and why `planNeedsConfirmation` exists.

**A7 — The two neighbouring toolbar menus resolve late and are unaffected.** The More-actions menu's
Delete item reads `selectedTask` inside its action (`WorkTaskListView.swift:120-127`) and the split
button's primary action reads `startableTask` inside its action (`WorkTaskListView.swift:83-85`).
Both are computed properties evaluated at click time, which is consistent with only the dropdown
being reported as broken.

**A8 — The row context menu is not affected and must keep planning its own row.** Its content is
`startNowItems(for: task)` inside `ForEach(backlogTasks)` (`WorkTaskListView.swift:218-235`). Per the
brief this path is correct today, and D6 records why passing the row's value stays safe.

**A9 — `WorkTaskCoordinator` is the established home for this menu's pure rules, and they are tested
as free-standing statics.** `planNeedsConfirmation`, `taskTerminalToggle` and `planWorkingDirectory`
are `static` on the coordinator (`WorkTaskCoordinator+TaskTerminal.swift:67,90`,
`WorkTaskCoordinator.swift:194`) and asserted directly, with no coordinator instance, in
`Tests/TaskTerminalLaunchCommandTests.swift:46-105`.

**A10 — Extracting a view rule and unit-testing it is the project's convention for menus that cannot
be rendered in a test.** `agentMenuRows` is a free function in `Sources/App/AgentLaunch.swift:19`
tested by `Tests/AgentMenuRowTests.swift`, whose docstring gives the same reason: "The menu itself
needs a live `ghostty_app_t` to render, so the rule is tested rather than the view."

**A11 — The test target compiles `Tests/` wholesale and `ci.sh` regenerates the project.** The test
target's sources are `- path: Tests` (`project.yml:307-308`), and `ci.sh` runs `xcodegen generate`
before building (`CLAUDE.md:31-34`). Extending an existing file needs no project edit either way.

## Objective

Picking an agent command from the Start Now toolbar dropdown plans the task that is selected at the
moment of the click, whatever the menu was built with.

### Success criteria

1. Plan task A with an agent command from the toolbar dropdown; select task B; pick the same command
   from the toolbar dropdown. No "processes still running" confirmation appears, B gets a fresh task
   terminal, A's surface and the agent in it are untouched, and the selection stays on B.
2. The same sequence from a row's context menu still plans that row's task, whether or not it is the
   selected one.
3. With the selection on a task whose terminal *is* busy, the toolbar dropdown still raises the
   replace confirmation, and the dialog names that task.
4. With nothing selected, the toolbar dropdown still shows only "Add Agent Command…"; selecting a
   task still makes the command items appear (D7 — behaviour unchanged).
5. `WorkTaskCoordinator.startNowTarget(row:selection:)` exists and is covered by unit tests
   asserting: a row wins over the selection; with no row the selection is the target; with neither,
   the target is `nil`; and consecutive calls with different selections return different tasks, so
   the rule carries no memory of an earlier selection.
6. `./scripts/ci.sh` green, `swiftlint lint --quiet` with zero errors.

## Verification commands

Copied from the project's `## Pipeline` section — both the regression check and the full gate are the
same command:

```
./scripts/ci.sh        # xcodegen generate + swiftlint + build + test suite
swiftlint lint --quiet # manual lint, zero errors required
git status --porcelain # before any CI stamp or sign-off; expect an un-gitignored default.profraw after a Debug launch
```

Criteria 1-4 are operator checks by hand; build agents do not launch the app.

## Files this change touches

| File | Change |
| --- | --- |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | Add `static func startNowTarget(row:selection:)` beside `planNeedsConfirmation`, with the docstring that carries the AppKit reason. |
| `Sources/App/WorkTaskListView.swift` | `startNowItems(for:)` takes the row rather than the task; its gate and each command item resolve through `startNowTarget`; toolbar call site passes `nil`; docstring extended. |
| `Tests/TaskTerminalLaunchCommandTests.swift` | New cases under `// MARK: - Confirming a plan` for criterion 5. |
| `Sources/App/CLAUDE.md` | Extend the Start Now paragraph (lines 104-118) with the stale-capture rule. |

## Out of scope

- `.id(selection)` on the toolbar `Menu`, or any other forced menu rebuild (D1).
- Changing the omission gate, or rendering the command items unconditionally (D7).
- The row context menu's structure, the "Start Task…" item, and the Copy/Delete/Mode toolbar items —
  all already resolve late (A7) and none is reported broken.
- `planNeedsConfirmation`'s rule, `runPlan`'s deliberate `selection = task.id`, and anything in
  `TerminalManager+TaskTerminals.swift` or `WorkTaskCoordinator+TaskTerminal.swift` beyond the new
  static: the brief establishes the surface bookkeeping is correct and only the id fed in is wrong.
- Any behaviour of the Start Now split button's primary half.
