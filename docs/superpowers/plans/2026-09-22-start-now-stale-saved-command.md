# Plan: Start Now menu items run a stale saved command after it is edited

Breaks down `docs/superpowers/specs/2026-09-22-start-now-stale-saved-command.md`.

**Date:** 2026-09-22
**Base:** 66145eb214d293794647be6d0599737c1dc00220 (Release v2.0.0)

Revised after the operator's two decisions (spec D11-D15). The earlier plan's `startNowCommand`
static and its tests are dropped.

## Architecture decisions carried from the spec

- Each Start Now item's action resolves its command at click time with the existing
  `CommandDefaults.resolve(commandId, in: savedCommandManager.commands)`
  (`Sources/App/SavedCommand.swift:62-65`). No new static. `resolve` already filters to agent kind,
  so a deleted command or one switched to terminal kind gives `nil` (D11).
- If the command does not resolve, the action does nothing: no plan, no confirmation, no log (D5).
- Each item's closure captures only a `UUID` bound as a local before the `Button`. The closure body
  never names `command` (D4).
- No new tests. The rule is covered by the existing `CommandDefaults.resolve` cases in
  `Tests/SavedCommandTests.swift:203-221`. The call site cannot be reached from a test (D10, D12).
- The toolbar Start Now `Menu` carries `.id(savedCommandManager.agentCommands)`, the full value,
  not the names, matching `RunCommandMenu` and `OpenInMenu`. A renamed command then rebuilds the
  toolbar's `NSMenu` and shows its new name (D13, D14).
- The row context menu's Start Now submenu gets no key. A plain `Menu` is refilled each time it
  opens. The operator's hand-check covers it (D14).
- `PlanRequest` and the confirmation dialog keep the resolved `SavedCommand` value (D6).
- Documentation: the `startNowItems` docstring and the Start Now passage in `Sources/App/CLAUDE.md`
  forbid capturing a `SavedCommand` as well as a `WorkTask` and name `CommandDefaults.resolve`. The
  `.id` rule in `Sources/App/CLAUDE.md` lists Start Now's key. `CommandDefaults.resolve`'s
  docstring names Start Now as a caller (D15).
- Out of scope: `RunCommandMenu`, `WorktreeCommands`, `planCommand`'s kind guard, the omission
  gate, the "Add Agent Command…" door, `startNowTarget`'s rule, `resolve`'s behaviour, and any key
  on the row context menu.

## Dependency graph

```
T1 (items resolve their command at click time via CommandDefaults.resolve)
      │
      └── T2 (toolbar Start Now Menu keyed on agentCommands)
```

T2 has no code dependency on T1. It follows T1 because both edit `startNowItems`'s docstring and
the same `Sources/App/CLAUDE.md` section, so running them in order avoids a conflicting edit.

### T1: Resolve each Start Now item's command at click time

**Files:** `Sources/App/WorkTaskListView.swift`, `Sources/App/SavedCommand.swift`,
`Sources/App/CLAUDE.md`

**Depends on:** none.

**What it does.**

In `startNowItems(for row:)` (currently `Sources/App/WorkTaskListView.swift:271-286`), change only
the `ForEach` body:

```swift
ForEach(commands) { command in
    let commandId = command.id
    Button(command.name) {
        if let task = WorkTaskCoordinator.startNowTarget(row: row, selection: selectedTask),
           let current = CommandDefaults.resolve(commandId, in: savedCommandManager.commands) {
            plan(task, using: current)
        }
    }
}
```

The label still uses `command.name`, because it is evaluated when the menu is built (T2 handles the
label). Only the action closure must avoid `command`. The gate, `let commands =
savedCommandManager.agentCommands`, the `Divider()`, and "Add Agent Command…" do not change. `plan`,
`runPlan`, `PlanRequest`, and the confirmation dialog do not change either. Pass `.commands`, not
`.agentCommands`: `resolve` applies the kind filter itself.

If the `@ViewBuilder` rejects the `let` inside `ForEach`'s content closure, bind the id another way
that keeps `command` out of the action closure (for example a small helper that takes the id and
returns the `Button`), and record the deviation in the build log.

Extend the `startNowItems` docstring (lines 249-270). The paragraph beginning "That same retention
is why an item may not **capture** a `WorkTask` either" gains the command half. An edit keeps a
command's id and the item count, so an item that captured a `SavedCommand` ran the text from when
the menu was first built. Each item therefore captures only the command's id and resolves it inside
its action through `CommandDefaults.resolve(_:in:)` against the live `savedCommandManager.commands`.
Keep the closing "No test can catch a regression here; this docstring is the guard."

In `Sources/App/SavedCommand.swift`, add one sentence to `CommandDefaults.resolve`'s docstring
(lines 58-61) saying Start Now items resolve their command through it on each click, so a change to
this rule changes what those items run. No code change in that file.

In `Sources/App/CLAUDE.md`, extend the Start Now passage (lines 240-248, the sentences beginning
"That same retention forbids an item from **capturing** a `WorkTask`") the same way: capturing a
`WorkTask` **or a `SavedCommand`** is forbidden. Add the symptom (an edited agent command ran its
pre-edit text) and name `CommandDefaults.resolve(_:in:)` next to `startNowTarget`. The existing
statement that the rule is unit-tested but the call-site laziness is not should cover both rules.
Insert or amend sentences in place. Do not delete or reword the omission-gate, `.disabled`, or
`readiness` sentences.

**Acceptance criteria.**
1. No action closure in `startNowItems` refers to `command`. It refers only to a `UUID` bound before
   the `Button`, and calls `plan` only when both `startNowTarget` and
   `CommandDefaults.resolve(commandId, in: savedCommandManager.commands)` resolve.
2. No `startNowCommand` symbol exists and no test file changes. `git diff --stat` shows only the
   three files above.
3. The `startNowItems` docstring and the `Sources/App/CLAUDE.md` Start Now passage both forbid
   capturing a `SavedCommand`, name `CommandDefaults.resolve(_:in:)`, and record the stale-text
   symptom. `resolve`'s docstring names Start Now as a caller.

**Verification.** `./scripts/ci.sh` exits 0 (the existing `CommandDefaults.resolve` tests in
`Tests/SavedCommandTests.swift` still pass). `swiftlint lint --quiet` reports zero errors and no new
warnings. Criteria 1-3 are read off `git diff`. Spec success criteria 1-3 are hand-checks for the
operator. Build agents do not launch the app or take screenshots.

### T2: Key the toolbar Start Now menu on the agent-command list

**Files:** `Sources/App/WorkTaskListView.swift`, `Sources/App/CLAUDE.md`

**Depends on:** T1 (same docstring and doc section, see the dependency graph).

**What it does.**

On the toolbar Start Now `Menu` (currently `Sources/App/WorkTaskListView.swift:79-87`), add
`.id(savedCommandManager.agentCommands)` after `.applyPrimaryActionStyle()`:

```swift
Menu {
    startNowItems(for: nil)
} label: {
    Text("Start Now")
} primaryAction: {
    if let task = startableTask { startTask(task) }
}
.applyPrimaryActionStyle()
.id(savedCommandManager.agentCommands)
```

Key on the full `agentCommands` value, not on the names. `Sources/App/CLAUDE.md` says "Do not
narrow the key to the items' labels". Do not add a key to the row context menu's Start Now submenu
(`WorkTaskListView.swift:227-232`). It is a plain `Menu` and is refilled each time it opens.

Add one sentence to the `startNowItems` docstring saying the toolbar control is keyed on
`savedCommandManager.agentCommands`, because a split button's `NSMenu` is filled once and a renamed
command would otherwise keep its old label. Point to the `.id` rule in `Sources/App/CLAUDE.md`
rather than restating it.

In `Sources/App/CLAUDE.md`, in the `.id` rule (lines 735-737, "each one carries `.id(<its own
dropdown's contents>)` — `.id(settings.menuOpenInApps)` on `OpenInMenu`,
`.id(savedCommandManager.menuCommands)` on `RunCommandMenu`"), add
`.id(savedCommandManager.agentCommands)` on the Start Now toolbar item in `WorkTaskListView`. In the
Start Now passage (around lines 257-262, "On the toolbar it is a split button in its **own**
`ToolbarGroupBreak` capsule"), add one clause that the toolbar control carries this key and the
context submenu needs none. Amend in place and do not reword the surrounding sentences.

**Acceptance criteria.**
1. The toolbar Start Now `Menu` carries `.id(savedCommandManager.agentCommands)`. The context-menu
   submenu has no `.id`.
2. The `startNowItems` docstring and both `Sources/App/CLAUDE.md` passages record the key. The
   `.id` rule lists Start Now beside `OpenInMenu` and `RunCommandMenu`.
3. `git diff` for this task touches only the toolbar `Menu`, the `startNowItems` docstring, and the
   two `Sources/App/CLAUDE.md` passages.

**Verification.** `./scripts/ci.sh` exits 0. `swiftlint lint --quiet` reports zero errors and no new
warnings. Criteria 1-3 are read off `git diff`. No test can reach the key (spec D10). Spec success
criterion 4 (rename a command, reopen the toolbar dropdown and a row's context menu, the new name
shows) is a hand-check for the operator. If the context menu shows the old name there, the fix is
the same `.id` on its `Menu`, recorded as a finding (spec D14).

## Build log

### T1: Resolve each Start Now item's command at click time

| File | State |
| --- | --- |
| `Sources/App/WorkTaskListView.swift` | `startNowItems` binds `let commandId = command.id` before each `Button`; the action plans only when `startNowTarget` and `CommandDefaults.resolve(commandId, in: savedCommandManager.commands)` both resolve, passing the resolved command. The closure no longer names `command`. Docstring forbids capturing a `SavedCommand` and names `CommandDefaults.resolve(_:in:)`. |
| `Sources/App/SavedCommand.swift` | `CommandDefaults.resolve` docstring names Start Now as a caller. No code change. |
| `Sources/App/CLAUDE.md` | Start Now passage forbids capturing a `WorkTask` or a `SavedCommand`, records the pre-edit-text symptom, names `CommandDefaults.resolve(_:in:)`, and says both rules are unit-tested while the call-site laziness is not. |

**Evidence.** No watched failure: per spec D10/D12 the regression lives at the call site (what the
closure captures), which no test in this project can reach, and the lookup rule is already covered by
the existing `CommandDefaults.resolve` cases in `Tests/SavedCommandTests.swift`. No test file
changed, so the TDD red step does not apply to this task.

**Deviations.** None. The `let commandId` inside the `ForEach` content closure compiled under
`@ViewBuilder`, so the fallback helper was not needed.

**Gate.** `./scripts/ci.sh` exit 0 (840 tests, 0 failures, "CI passed."). `swiftlint lint --quiet`
on the two Swift files: zero output, exit 0.

### T2: Key the toolbar Start Now menu on the agent-command list

| File | State |
| --- | --- |
| `Sources/App/WorkTaskListView.swift` | The toolbar Start Now `Menu` carries `.id(savedCommandManager.agentCommands)` after `.applyPrimaryActionStyle()`. The row context submenu has no key. The `startNowItems` docstring gains one paragraph naming the key and pointing to the `.id` rule in `Sources/App/CLAUDE.md`. |
| `Sources/App/CLAUDE.md` | The `.id` rule lists `.id(savedCommandManager.agentCommands)` on the Start Now toolbar item beside `OpenInMenu` and `RunCommandMenu`. The Start Now toolbar sentence adds that the control carries this key and the context submenu needs none. |

**Evidence.** No watched failure. Per spec D10 no test can reach a view's `.id` key, and no test
file changed.

**Deviations.** None.

**Gate.** `./scripts/ci.sh` exit 0 (840 tests, 0 failures, "CI passed."). `swiftlint lint --quiet
Sources/App/WorkTaskListView.swift`: zero output, exit 0.
