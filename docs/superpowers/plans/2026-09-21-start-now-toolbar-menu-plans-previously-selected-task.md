# Plan: Start Now toolbar menu plans the previously selected task

Breaks down `docs/superpowers/specs/2026-09-21-start-now-toolbar-menu-plans-previously-selected-task.md`.

**Date:** 2026-09-21
**Base:** 8d032a4ddb48fc35f97eb5e4618efa3de44ac48c (Require pipeline load generators to bound their own lifetime (#251))

## Architecture decisions carried from the spec

- The fix is **lazy resolution**, not a forced menu rebuild. No `.id(selection)` on the toolbar
  `Menu`, no structural-identity trick: the dropdown items stop capturing a `WorkTask` value at
  all, so AppKit retaining the `NSMenu` and its closures across selection changes becomes harmless
  (D1).
- `startNowItems` takes the **row**, not the task: `startNowItems(for row: WorkTask?)`. `nil` means
  "the toolbar, whose items plan the current selection"; the row context menu passes its own
  `task`. The toolbar call site then literally carries no task that can go stale (D2).
- The target is resolved **inside the item's action closure**, from the view's existing
  `selectedTask` computed property, which reads the live `selection` binding and the live
  `workTaskManager.tasks`. This is what the two neighbouring toolbar menus already do — the More
  actions Delete item and the split button's primary half — and neither has the bug (D3, A7).
- The rule itself is a free-standing static:
  `WorkTaskCoordinator.startNowTarget(row: WorkTask?, selection: WorkTask?) -> WorkTask?`, in
  `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` beside `planNeedsConfirmation`. Both the
  build-time gate and each item action go through it, so the row-wins-over-selection precedence is
  reviewable in one place instead of inside a `@ViewBuilder` (D4, A9, A10).
- The test pins the rule and **cannot** pin that the call site is inside the action closure —
  laziness at a SwiftUI call site is not observable from XCTest, and this project has no
  view-inspection dependency. The call site is guarded by prose instead: the `startNowItems`
  docstring and the `Sources/App/CLAUDE.md` note (D5, D8). Do not reopen this in review.
- The row context menu keeps passing a `WorkTask` **value**. Only the id travels downstream —
  `planCommand` re-reads `workTaskManager.freshTask(id: task.id)` before substituting placeholders
  — and a row's id cannot go stale for that row (D6, A8).
- The "command items are omitted when there is nothing to plan" gate **stays, unchanged**. Lazy
  resolution does not remove the need for it: a menu built with nothing selected has no items to
  resolve late, and rendering them unconditionally would trade the omission for a silently dead
  menu item (D7).
- Nothing changes in the confirmation dialog, `plan`, `runPlan`, or `planTask`. `runPlan`'s
  `selection = task.id` is deliberate and, once the right task reaches it, is what keeps the
  selection on B instead of snapping back to A (D10).
- Out of scope: `.id(selection)` or any forced rebuild; the omission gate; the row context menu's
  structure, "Start Task…", and the Copy/Delete/Mode toolbar items; `planNeedsConfirmation`'s rule;
  anything in `TerminalManager+TaskTerminals.swift`; the split button's primary half.

## Dependency graph

```
T1 (WorkTaskCoordinator.startNowTarget + its unit tests)
      │
      └── T2 (startNowItems takes the row; items resolve through startNowTarget)
                │
                └── T3 (extend the Start Now note in Sources/App/CLAUDE.md)
```

T1 lands first because T2's gate and every item action call the static it adds. T3 describes the
shape T2 creates, so it is written last.

### T1: Add startNowTarget to WorkTaskCoordinator, with its unit tests

**Files:** `Sources/App/WorkTaskCoordinator+TaskTerminal.swift`,
`Tests/TaskTerminalLaunchCommandTests.swift`

**Depends on:** none.

**What it does.**

In `Sources/App/WorkTaskCoordinator+TaskTerminal.swift`, beside `planNeedsConfirmation`
(currently lines 88-92), add:

```swift
static func startNowTarget(row: WorkTask?, selection: WorkTask?) -> WorkTask? {
    row ?? selection
}
```

The docstring carries the reason the function exists at all, not just what it returns:

- Which task a Start Now item plans. A row context menu's items plan their own row; the toolbar's
  items have no row and plan whatever is selected **at the moment of the click**.
- The function holds no state, so it can never answer with an earlier selection. That is the whole
  point: AppKit keeps a toolbar's `NSMenu` and the `Button` closures built with it alive across
  selection changes, so an item that captured a `WorkTask` value planned the task that was selected
  when the menu was first built — replacing that task's terminal, killing the agent in it, and
  snapping the selection back to it.
- Callers must therefore pass `selection:` from a property read **inside** the action closure
  (`selectedTask`), never from a value bound when the menu was built.

In `Tests/TaskTerminalLaunchCommandTests.swift`, under the existing `// MARK: - Confirming a plan`
section (after `testPlanNeedsConfirmationOnlyWhenAProcessIsRunning`), add cases covering spec
criterion 5. `WorkTask(title:)` is enough to build fixtures — `id` defaults to a fresh `UUID()`
(`Sources/App/WorkTask.swift`), and the tests in `Tests/WorkTaskManagerTests.swift` use the same
initializer. No coordinator instance is needed; these are statics, asserted directly, exactly as
`planNeedsConfirmation` and `taskTerminalToggle` already are in this file.

The cases:

1. A row wins over the selection: `startNowTarget(row: rowTask, selection: selectedTask)` is
   `rowTask`. Also assert it with `selection: nil`.
2. With no row, the selection is the target: `startNowTarget(row: nil, selection: selectedTask)` is
   `selectedTask`.
3. With neither, the target is `nil`.
4. Consecutive calls with different selections return different tasks: call
   `startNowTarget(row: nil, selection: taskA)` then `startNowTarget(row: nil, selection: taskB)`
   and assert the second is `taskB`, not `taskA`. Docstring that this is the regression — the rule
   carries no memory of an earlier selection.

**Acceptance criteria.**
1. `WorkTaskCoordinator.startNowTarget(row:selection:)` exists as a `static func` in
   `Sources/App/WorkTaskCoordinator+TaskTerminal.swift`, takes only its two parameters, reads no
   instance state, and is `nonisolated`-safe by being a pure function of its arguments.
2. Its docstring names AppKit's menu retention as the hazard and states that `selection:` must be
   read inside the action closure.
3. The four cases above exist in `Tests/TaskTerminalLaunchCommandTests.swift` under
   `// MARK: - Confirming a plan` and pass.
4. No call site changes in this task — `WorkTaskListView.swift` is untouched.

**Verification.** `./scripts/ci.sh` is green; the new cases run inside it. Then
`swiftlint lint --quiet` reports no new warnings. Criteria 1, 2 and 4 are read off the source and
`git diff --stat` (two files, no view file).

### T2: Make the Start Now items resolve their task at click time

**Files:** `Sources/App/WorkTaskListView.swift`

**Depends on:** T1.

**What it does.** One function and one call site change; everything else in the file is untouched.

`startNowItems(for task: WorkTask?)` (currently lines ~252-264) becomes
`startNowItems(for row: WorkTask?)`:

- The gate stops binding a task value. It still omits the command items when there is nothing to
  plan (D7), but asks the rule rather than a captured value — e.g.
  `if WorkTaskCoordinator.startNowTarget(row: row, selection: selectedTask) != nil,
  ghosttyApp.readiness == .ready, !commands.isEmpty`. The `readiness` half and the unconditional
  `Divider()` + "Add Agent Command…" door are unchanged.
- Each item's action resolves the target itself:

  ```swift
  Button(command.name) {
      if let task = WorkTaskCoordinator.startNowTarget(row: row, selection: selectedTask) {
          plan(task, using: command)
      }
  }
  ```

  The closure captures `row` (which for the toolbar is `nil`) and the view struct, not a task. The
  `selectedTask` read happens when the item is clicked, against the live `selection` binding and
  the live `workTaskManager` (A3, A4).

The toolbar call site (line 80) becomes `startNowItems(for: nil)`. The row context menu call site
(line 219) stays `startNowItems(for: task)` (D6, A8).

The `startNowItems` docstring gains the stale-capture rule beside the stale-enabled-flag rule it
already records (D8): AppKit keeps this menu and the closures built with it alive across selection
changes, so an item may not capture a `WorkTask`; it takes the *row* it belongs to (`nil` for the
toolbar) and resolves the target through `WorkTaskCoordinator.startNowTarget` inside its action.
Capturing a value here is what made the toolbar dropdown plan the previously selected task. No
test can catch a regression of this (D5) — the docstring is the guard.

`plan`, `runPlan`, `PlanRequest`, the confirmation dialog, `startableTask`, `selectedTask` and the
primary action are all unchanged.

**Acceptance criteria.**
1. `startNowItems` takes `row:` and no longer binds a `WorkTask` outside the item action closures;
   `grep -n "Button(command.name)" Sources/App/WorkTaskListView.swift` shows the action calling
   `WorkTaskCoordinator.startNowTarget`.
2. The toolbar call site passes `nil`; the row context menu call site still passes its `task`.
3. The omission gate still omits the command items when there is no target, when
   `ghosttyApp.readiness != .ready`, or when there are no agent commands, and "Add Agent Command…"
   stays unconditional.
4. The docstring records the stale-capture rule and names `startNowTarget` as the required route.
5. Nothing else in the file changes: `plan`, `runPlan`, the confirmation dialog and the split
   button's primary action are byte-identical in the diff.

**Verification.** `./scripts/ci.sh` is green, then `swiftlint lint --quiet` with zero errors and no
new warnings. Criteria 1-5 are read off `git diff Sources/App/WorkTaskListView.swift`. Spec success
criteria 1-4 are hand-checks the operator runs at sign-off; per project memory, build agents do not
launch the app or take screenshots — do not attempt to verify them by running Clearway.

### T3: Record the stale-capture rule in the per-file notes

**Files:** `Sources/App/CLAUDE.md`

**Depends on:** T2.

**What it does.** The Start Now paragraph (lines 104-118) already explains why the command items
are omitted rather than disabled, and names AppKit's unreliable `NSMenuItem` enabled-flag update as
the reason. The captured task is the second face of that same retention, so it belongs in the same
passage (D8).

Add, in that paragraph: the same retention means a menu item may not **capture** a `WorkTask`
either. `startNowItems` takes the *row* it is built for — `nil` from the toolbar, the row's own
task from a context menu — and each item resolves its target inside its action through
`WorkTaskCoordinator.startNowTarget(row:selection:)`, which falls back to the live `selectedTask`.
Note the symptom this prevents, because it is not cheap to rediscover: an item that captured the
selection planned the task selected when the menu was first built, which replaced that task's
terminal, killed the agent running there, and snapped the selection back to it. Note that no test
covers the call site — the rule is unit-tested, the laziness is not (D5) — so this note and the
`startNowItems` docstring are the only guards.

Keep the existing sentences about the omission gate, `readiness` vs. `ghosttyApp.app`, and the
absent `.disabled` intact; this is an extension of the paragraph, not a rewrite.

**Acceptance criteria.**
1. `Sources/App/CLAUDE.md` states that Start Now menu items must not capture a `WorkTask`, names
   `startNowItems(for row:)` and `WorkTaskCoordinator.startNowTarget(row:selection:)`, and records
   the symptom.
2. It records that the call-site laziness is not test-covered.
3. No existing sentence in that paragraph is deleted or contradicted, and nothing elsewhere in the
   file now describes `startNowItems` as taking a task — `grep -n "startNowItems"
   Sources/App/CLAUDE.md` shows every mention consistent with T2's signature.

**Verification.** Read the diff against criteria 1-3. `./scripts/ci.sh` need not be re-run for a
Markdown-only change if T2's run was green and nothing else changed since; if any Swift file
changed in the same working tree, run it.

## Build log

### T1: Add startNowTarget to WorkTaskCoordinator, with its unit tests

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | `static func startNowTarget(row:selection:)` added immediately after `planNeedsConfirmation`, with the docstring naming AppKit's menu retention and the read-inside-the-closure requirement. |
| `Tests/TaskTerminalLaunchCommandTests.swift` | Four cases added under `// MARK: - Confirming a plan`, ahead of `// MARK: - Toggling the task terminal`. |
| `Sources/App/WorkTaskListView.swift` | Untouched, as the task requires. `git diff --stat` shows two files. |

**Evidence.** The four cases were written first and watched fail against the unfixed code —
`./scripts/ci.sh` stopped at the test target's compile:

```
❌ Tests/TaskTerminalLaunchCommandTests.swift:57:33: type 'WorkTaskCoordinator' has no member 'startNowTarget'
❌ Tests/TaskTerminalLaunchCommandTests.swift:58:44: type 'WorkTaskCoordinator' has no member 'startNowTarget'
❌ Tests/TaskTerminalLaunchCommandTests.swift:65:44: type 'WorkTaskCoordinator' has no member 'startNowTarget'
❌ Tests/TaskTerminalLaunchCommandTests.swift:70:42: type 'WorkTaskCoordinator' has no member 'startNowTarget'
❌ Tests/TaskTerminalLaunchCommandTests.swift:83:44: type 'WorkTaskCoordinator' has no member 'startNowTarget'
❌ Tests/TaskTerminalLaunchCommandTests.swift:85:42: type 'WorkTaskCoordinator' has no member 'startNowTarget'
```

That is the whole failure this rule can be watched for: the behavioural regression it guards against
lives at the SwiftUI call site, which no test in this project can reach (D5). The
`testStartNowTargetCarriesNoMemoryOfAnEarlierSelection` case pins the statelessness the fix rests on,
not the laziness.

**Deviations.** None. The function is not annotated `nonisolated`: `WorkTaskCoordinator` is
`@MainActor`, so its statics are too, and `planNeedsConfirmation` and `taskTerminalToggle` beside it
carry no annotation either. Acceptance criterion 1 asks that the function be safe to call that way —
a pure function of its two arguments reading no instance state — which it is; adding the keyword
would make it the only annotated rule in the file.

**Gate.** `./scripts/ci.sh` → `==> CI passed.`, `Executed 787 tests, with 0 failures`. The four new
cases are confirmed `Passed` in the `.xcresult`. `swiftlint lint --quiet` → no output, exit 0.
`git status --porcelain` → the two modified files above and nothing else.

### T2: Make the Start Now items resolve their task at click time

| File | State |
| --- | --- |
| `Sources/App/WorkTaskListView.swift` | `startNowItems(for row: WorkTask?)`; the gate asks `WorkTaskCoordinator.startNowTarget(row:selection: selectedTask)` instead of binding a task; each `Button(command.name)` action resolves through the same static before calling `plan`; toolbar call site (line 80) passes `nil`; row context menu (line 224) still passes its `task`; docstring extended with the stale-capture rule. |
| Everything else in the file | Untouched. `git diff --stat` → one file, 18 insertions, 4 deletions, in exactly two hunks: the toolbar call site and `startNowItems`. `plan`, `runPlan`, `PlanRequest`, the confirmation dialog, `startableTask`, `selectedTask` and the split button's primary action do not appear in the diff. |

**Evidence.** No test was written for this task and none could be. The behaviour T2 changes is *when*
`selectedTask` is read — before the menu is built, or inside the item's action — and laziness at a
SwiftUI call site is not observable from XCTest in this project (D5; the suite has no view-inspection
dependency, and `Tests/TaskTerminalLaunchCommandTests.swift:7-9` already records why this menu's
launch paths are unreachable). Reverting line 80 to `startNowItems(for: selectedTask)` would
reintroduce the bug and still compile, and all 787 tests would still pass — that is the finding, not
a gap to close here. The rule the fix rests on is watched-red-then-green in T1's build log; the call
site is guarded by the `startNowItems` docstring and, in T3, by `Sources/App/CLAUDE.md`.

**Deviations.** None. The gate is written as `startNowTarget(...) != nil` rather than `if let`,
because binding the value at build time is the defect: a bound name would be in scope inside the
`ForEach` and an item could use it. The target is resolved twice — once for the gate, once per click
— and that is the point, not duplication: the gate answers "is there anything to plan *now*", the
action answers "what is selected *at this click*", and the two questions are asked at different
times.

**Gate.** `./scripts/ci.sh` → `==> CI passed.`, `Executed 787 tests, with 0 failures`.
`swiftlint lint --quiet` → no output, exit 0. `git status --porcelain` → `M
Sources/App/WorkTaskListView.swift` and nothing else; no `default.profraw`, since no Debug launch
happened outside the test host.
