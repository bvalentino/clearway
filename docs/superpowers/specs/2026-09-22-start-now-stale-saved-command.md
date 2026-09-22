# Start Now menu items run a stale saved command after it is edited

**Date:** 2026-09-22
**Base:** 66145eb214d293794647be6d0599737c1dc00220 (Release v2.0.0)

Picking an agent command from the Start Now dropdown runs the command text as it was when AppKit
first built the menu, not as it is now. Each item's action captures the `SavedCommand` value, and
editing a command keeps its id and the item count, so the toolbar `NSMenu` is never rebuilt and the
old closure, with the old text, is what runs. PR #254 fixed the same mechanism for the task. This
change applies the same fix to the command: the item keeps only the command's id and looks the
command up in the live command list when it is clicked, through the existing
`CommandDefaults.resolve(_:in:)`. If the command has been deleted or is no longer agent-kind, the
click does nothing. The same retention leaves a renamed command's toolbar item showing its old
name, so the toolbar `Menu` is also keyed on the agent-command list, the way `RunCommandMenu` and
`OpenInMenu` already are.

This is a revision. After the first breakdown the operator settled two points: reuse
`CommandDefaults.resolve` instead of adding a new static (D11), and fix the stale label now (D13).
D11-D15 record them. Rows they replace are marked superseded and left in place for the record.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | Lazy resolution, or force a rebuild with `.id(savedCommandManager.agentCommands)` on the toolbar `Menu`? | **Partly superseded by D13 and D14.** Lazy resolution for the action stays. The `.id` key is now added as well, for the label. | The task brief settles it, and PR #254 made the same call for the task (`docs/superpowers/specs/2026-09-21-start-now-toolbar-menu-plans-previously-selected-task.md`, D1). `RunCommandMenu` does use `.id(savedCommandManager.menuCommands)` (`Sources/App/RunCommandMenu.swift:68`), but mixing both approaches inside `startNowItems` would leave the task resolved lazily and the command rebuilt by identity, two different guards against one hazard. Resolving both at click time is one rule for the whole item. |
| D2 | Where does the resolution rule live? | **Superseded by D11.** `static func startNowCommand(id: UUID, in agentCommands: [SavedCommand]) -> SavedCommand?` on `WorkTaskCoordinator`, in `WorkTaskCoordinator+TaskTerminal.swift` directly after `startNowTarget(row:selection:)`. | The acceptance criteria put its test beside the `startNowTarget` cases. That suite asserts coordinator statics with no instance (`Tests/TaskTerminalLaunchCommandTests.swift:99-138`), and `startNowTarget` is the task half of the same click-time lookup (`WorkTaskCoordinator+TaskTerminal.swift:130-132`). An instance method on `SavedCommandManager` would need a store-backed manager in the test for a one-line lookup. |
| D3 | Look up in `savedCommandManager.commands` or `.agentCommands`? | **Superseded by D11.** `.agentCommands`. | That list is what built the menu (`WorkTaskListView.swift:273`), and it is documented as "the one answer to 'which commands may run as an agent'" (`SavedCommandManager.swift:70-74`). A command switched to terminal kind after the menu was built then resolves to nothing, so the click does nothing. Looking in `commands` would pass it to `planCommand`, which refuses it and logs an error (`WorkTaskCoordinator.swift:186-190`). The outcome is the same, but the second path treats an ordinary edit as a logged fault. |
| D4 | What does the item's closure capture? | Only `command.id` (a `UUID`), bound as a local before the `Button` so the closure never refers to `command`. Its body resolves the task (unchanged) and then the command, and calls `plan` only when both resolve. | An id cannot go stale: `update` keeps the id and position (`SavedCommandManager.swift:84-88`). Binding the id first means the closure body cannot reach the captured value. Reading `command.id` inside the closure would still capture the whole `SavedCommand`. |
| D5 | The deleted-command case. | Resolution returns `nil`, and the item's action does nothing: no plan, no confirmation, no log. | This is the brief's "do nothing", and it matches the `nil`-task case in the same closure (`WorkTaskListView.swift:278`). A delete usually changes the item count, which rebuilds the menu, so AppKit mostly stops offering the item anyway. The guard covers any retained closure that is still reachable. |
| D6 | Does `PlanRequest` (the pending confirmation) also switch to an id? | No. It keeps the resolved `SavedCommand` value. | It is formed at click time from the command that was just resolved (`WorkTaskListView.swift:288-295`), and the confirmation dialog that holds it is modal on this window. The command editor and the Commands list are in this same window, so the command cannot be edited while the dialog is up. Changing it would add a second lookup and no behaviour. |
| D7 | Row context menu. | No separate change. It already goes through `startNowItems(for: task)` (`WorkTaskListView.swift:229`), so the fix applies to both call sites at once. | The acceptance criterion "row context menu behaves the same" is met by the shared function. |
| D8 | Documentation. | **Superseded by D15.** Extend the `startNowItems` docstring (`WorkTaskListView.swift:249-271`) and the Start Now passage in `Sources/App/CLAUDE.md` (lines 240-248) from "never capture a `WorkTask`" to "never capture a `WorkTask` or a `SavedCommand`", naming `startNowCommand(id:in:)` next to `startNowTarget`. Add a matching docstring to the new static. | Both notes say they are the only guard on the call site's laziness, because no test can reach it (`WorkTaskListView.swift:267`, `Sources/App/CLAUDE.md:247-248`). The command half needs the same guard. |
| D9 | Test placement and cases. | **Superseded by D12.** New cases in `Tests/TaskTerminalLaunchCommandTests.swift`, directly after the `startNowTarget` cases under `// MARK: - Confirming a plan`. They assert that an id resolves to the live list's entry, not an earlier copy; that a deleted id resolves to `nil`; and that an id whose command is absent from the agent list resolves to `nil`. Update the suite's docstring (lines 4-10) to list the new rule. | The brief names this file. The first case is the regression: two lists with the same id and different `text` must each give back their own entry. That test fails to compile on the base commit, where the function does not exist. |
| D10 | What the tests cannot prove. | Same limit as PR #254 (its spec, D5). The rule is pinned, but not the fact that the call site resolves inside the action closure, and not the `.id` key on the toolbar `Menu`. | `planTask` needs a non-optional `ghostty_app_t` (`Tests/TaskTerminalLaunchCommandTests.swift:7-9`), and the project has no view-inspection dependency. D15's notes guard the call site instead. |
| D11 | The lookup rule (operator decision, supersedes D2 and D3). | Reuse `CommandDefaults.resolve(_:in:)` (`Sources/App/SavedCommand.swift:62-65`). The item's action calls `CommandDefaults.resolve(commandId, in: savedCommandManager.commands)`. No new static. | `resolve` is already the rule "an id resolves only to a live agent-kind command" (`commands.first { $0.id == id && $0.kind == .agent }`), used by `afterCreateCommand` (`SavedCommandManager.swift:66-68`) and the Start Task sheet (`SidebarSheets.swift:224`). Its kind clause gives D3's outcome: a command switched to terminal kind resolves to `nil` and never reaches `planCommand`'s logged kind guard. Passing `.commands` rather than `.agentCommands` is correct here because `resolve` applies the kind filter itself. Its docstring gains one sentence naming Start Now as a caller, so a later change to the rule for the default slot does not silently change what a Start Now click runs. |
| D12 | Does Start Now need its own test of the rule? (supersedes D9) | No new test. The acceptance line "the resolution rule has a unit test alongside the `startNowTarget` cases" is met by the existing `CommandDefaults.resolve` cases in `Tests/SavedCommandTests.swift:203-221`. | Those four cases cover every branch Start Now relies on: the live agent command is returned from the list passed in (`testResolveFindsTheLiveAgentCommand`), a deleted id is `nil` (`testResolveIsNilForAnIdNamingNoCommand`), and a terminal-kind command is `nil` (`testResolveIsNilForATerminalKindCommand`). The "edited copy wins" case D9 planned adds nothing: `resolve` is a pure lookup over its argument and holds no state that could return an earlier copy. The regression lives at the call site (what the closure captures), which no test can reach (D10). A Start-Now-named test would call the same function with the same inputs. |
| D13 | Is the stale label in scope? (operator decision) | Yes, fixed in this change. | With only click-time resolution, renaming an agent command leaves the toolbar item under its old name while the click runs the renamed command. `Button(command.name)` (`WorkTaskListView.swift:278`) is evaluated when the menu is built, and the documented split-button behaviour means it is never re-evaluated in place (next row). |
| D14 | How is the label fixed, and for which menu? (partly supersedes D1 and D7) | Add `.id(savedCommandManager.agentCommands)` to the toolbar Start Now `Menu` (`WorkTaskListView.swift:79-87`), after `.applyPrimaryActionStyle()`. The row context menu gets no key. | The toolbar `Menu` carries `primaryAction:`, so SwiftUI realizes it as an `NSSegmentedControl` whose `NSMenu` "is filled once, when the control is built, and never refilled" (`Sources/App/CLAUDE.md:735-743`). `RunCommandMenu` (`RunCommandMenu.swift:68`) and `OpenInMenu` (`OpenInMenu.swift:47`) solved this by keying the view on what the dropdown draws, and the same note says "Do not narrow the key to the items' labels", so the key is the full `agentCommands` value (`SavedCommand` is `Hashable` over every field, `SavedCommand.swift:11`), not the names. The row context menu's Start Now is a plain submenu, and the same note records that a plain `Menu` "is filled by its coordinator each time it opens, which is why the sidebar's submenu ... need[s] no key". The operator's hand-check (success criterion 4) covers both menus. If the context menu shows a stale name there, that is a finding for the build log, and the fix is the same `.id` on the context submenu's `Menu`. With the key in place a rebuilt toolbar menu also captures fresh values, so click-time resolution (D11) is no longer the only thing keeping the text current. It stays anyway: it is the same one-line shape as the task half, and it keeps the action correct if the key is ever narrowed or dropped. |
| D15 | Documentation (supersedes D8). | Extend the `startNowItems` docstring (`WorkTaskListView.swift:249-270`) and the Start Now passage in `Sources/App/CLAUDE.md` (lines 240-248) from "never capture a `WorkTask`" to "never capture a `WorkTask` or a `SavedCommand`", naming `CommandDefaults.resolve(_:in:)` next to `startNowTarget`. Add Start Now's `.id(savedCommandManager.agentCommands)` to the list of keyed split buttons in the `Sources/App/CLAUDE.md` `.id` rule (lines 735-737). Add one sentence to `CommandDefaults.resolve`'s docstring naming Start Now as a caller. | The call-site laziness and the key are both untestable (D10), so these notes are their guards. |

## Assumptions

Each was checked by reading the source at the base commit. No probe scripts were written, in the
repo or in the scratchpad.

**A1: The item captures the command value.** `ForEach(commands) { command in Button(command.name) {
... plan(task, using: command) } }` over `let commands = savedCommandManager.agentCommands`
(`Sources/App/WorkTaskListView.swift:273-281`). The closure holds the `SavedCommand` struct from
the moment the menu was built.

**A2: The captured fields are what runs.** `plan` passes the command to `runPlan` or into
`PlanRequest` (`WorkTaskListView.swift:288-295`). `runPlan` calls `workTaskCoordinator.planTask(task,
using: command, app:)` (`:301-305`), `planTask` calls `planCommand(for:using:)`
(`WorkTaskCoordinator+TaskTerminal.swift:141-142`), and `planCommand` re-reads the task but
substitutes placeholders into the command it was handed (`WorkTaskCoordinator.swift:185-193`).
Nothing downstream looks the command up again.

**A3: An edit keeps the id and the item count.** `SavedCommandManager.update` replaces the entry
with the same id at the same index (`Sources/App/SavedCommandManager.swift:84-88`). `ForEach`
identity is the id (`SavedCommand: Identifiable`, `Sources/App/SavedCommand.swift:11,18`), so an
edit to the text changes no item and does not change the content's structural identity.

**A4: AppKit keeps the toolbar menu and its closures while that identity is unchanged.** This is
recorded as observed behaviour in `WorkTaskListView.swift:249-267` and `Sources/App/CLAUDE.md:235-246`,
and it is the mechanism PR #254 fixed (commit 27f30f5). The brief says the command case is unproven
in the app. Build agents do not launch the app (memory: no screenshot verification by agents), so
the operator confirms it by hand. The fix is correct either way.

**A5: `savedCommandManager` in a retained closure is the live manager.** It is an
`@EnvironmentObject` (`WorkTaskListView.swift:10`) over a long-lived `@MainActor final class`
(`SavedCommandManager.swift:10-11`). A copied view struct holds the same reference, so reading
`agentCommands` at click time sees the current list. This is the same assumption PR #254's spec
records as A4 for `workTaskManager`.

**A6: The pattern of resolving an id against the live list already exists here.**
`SavedCommandManager.lastRunCommand` is `commands.first { $0.id == lastRunId }`, "resolved against
the live list on every read, so an id naming a command that has since been deleted reads as nothing"
(`SavedCommandManager.swift:21-23`). `CommandDefaults.resolve`, which Start Now now reuses (D11), is
the same rule with a kind clause added.

**A7: The Run button's menu is not affected.** Its `Menu` carries
`.id(savedCommandManager.menuCommands)` (`Sources/App/RunCommandMenu.swift:68`). `SavedCommand` is
`Hashable` over every field (`SavedCommand.swift:11`), so editing a command's text changes that id
and rebuilds the menu. It is not part of this change.

**A8: `SavedCommand` can be built directly in a test.** The memberwise
`SavedCommand(id:name:kind:text:agent:autoRun:)` is already used across the tests
(`Tests/WorkTaskCoordinatorTests.swift:606`, `Tests/CommandPlaceholdersTests.swift:15`).

**A9: A new test case needs no project edit.** The test target's sources are `- path: Tests`
(`project.yml:308`), and `ci.sh` regenerates the project (`CLAUDE.md`, "Verifying a change").

## Objective

A Start Now item, whether in the toolbar dropdown or a row's context menu, runs the agent command as
it is at the moment of the click.

### Success criteria

1. Open the toolbar dropdown, edit an agent command's text, then pick that command from the same
   dropdown: the terminal runs the edited text.
2. Open the toolbar dropdown, delete an agent command, then pick it from the same dropdown if AppKit
   still offers it: nothing runs, no confirmation appears, and nothing crashes.
3. The same two sequences through a row's context menu behave the same.
4. Rename an agent command, then reopen the toolbar dropdown and a row's context menu: each shows
   the new name.
5. Each item's action resolves its command through `CommandDefaults.resolve(_:in:)` against
   `savedCommandManager.commands`. No `startNowCommand` static exists. The rule's unit tests are the
   existing `CommandDefaults.resolve` cases in `Tests/SavedCommandTests.swift:203-221` (D12).
6. No item closure in `startNowItems` refers to the `command` loop value. It refers only to a
   `UUID` bound before the `Button`.
7. The toolbar Start Now `Menu` carries `.id(savedCommandManager.agentCommands)`.
8. `./scripts/ci.sh` exits 0, and `swiftlint lint --quiet` reports zero errors.

Criteria 1-4 are checked by the operator by hand. Build agents do not launch the app.

## Verification commands

From the project's `## Pipeline` section. The regression check and the full gate are the same
command:

```
./scripts/ci.sh        # xcodegen generate + swiftlint + build + test suite
swiftlint lint --quiet # manual lint, zero errors required
git status --porcelain # before any CI stamp or sign-off; expect an un-gitignored default.profraw after a Debug launch
```

## Files this change touches

| File | Change |
| --- | --- |
| `Sources/App/WorkTaskListView.swift` | In `startNowItems(for:)`, bind `command.id` before each `Button`. The action resolves the command through `CommandDefaults.resolve(commandId, in: savedCommandManager.commands)` and plans only when both the task and the command resolve. Add `.id(savedCommandManager.agentCommands)` to the toolbar Start Now `Menu`. Extend the docstring (D15). |
| `Sources/App/SavedCommand.swift` | One sentence in `CommandDefaults.resolve`'s docstring naming Start Now as a caller (D11). No code change. |
| `Sources/App/CLAUDE.md` | Extend the Start Now stale-capture sentences (lines 240-248) to cover the command, and add Start Now to the keyed split buttons in the `.id` rule (lines 735-737) (D15). |

No test file changes (D12).

## Out of scope

- A key on the row context menu's Start Now submenu, unless the hand-check shows it stale (D14).
- `PlanRequest` and the confirmation dialog (D6).
- `RunCommandMenu`, which already rebuilds on edit (A7), and the `WorktreeCommands` menu-bar items.
- `planCommand`'s kind guard and its error log. They stay as the backstop for other callers.
- The omission gate on the command items and the "Add Agent Command…" door, which do not change.
- Any change to `startNowTarget`'s rule or to `CommandDefaults.resolve`'s behaviour.
- A new `startNowCommand` static or new tests for the lookup (D11, D12).
