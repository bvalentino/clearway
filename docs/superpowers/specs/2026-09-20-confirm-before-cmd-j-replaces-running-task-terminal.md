# Confirm before Cmd+J replaces a running task terminal

**Date:** 2026-09-20
**Base:** b4369a5adaf99c58d5c7dcee82041c99b37c2f60 (Split buttons for Run and Open in (#237))

On the Tasks destination, Cmd+J hides the task's bottom terminal and Cmd+J again re-shows it. When
Settings → Main Terminal names an agent, the second press does not re-show the surface that was
hidden: it closes it and opens a fresh one, killing a running agent with no warning. This change
makes re-showing reuse the hidden surface, so the agent survives and nothing is destroyed. The
confirmation dialog the task brief asks for becomes unnecessary on that path and is not added; the
decision Cmd+J routes on becomes a pure function with a unit test beside `planNeedsConfirmation`.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | Fix the cause (reuse the hidden surface) or only add a confirmation dialog? | Fix the cause. | The brief states the preference outright: "Preferably fix the cause rather than only adding the dialog … so the running agent survives and no confirmation is needed on that path." The cause is fixable (see A1–A3), so the dialog is the fallback that is no longer required. |
| D2 | Does Cmd+J also get a Replace/Cancel confirmation dialog? | No. | After D1 there is no Cmd+J path that replaces a live surface, so a dialog would be unreachable UI. The brief's dialog requirement is conditional on the cause not being fixed ("only adding the dialog"), and its own closing line says no confirmation is needed once re-show reuses the surface. The task's existing destructive doors — Start Now's agent commands and Delete — keep their dialogs untouched. |
| D3 | The brief asks to "keep the needs-confirmation rule as a pure function with a unit test, alongside the one the dropdown already uses". What is that function, given D2? | The *whole* Cmd+J decision becomes one pure static function on `WorkTaskCoordinator`, tested in `Tests/TaskTerminalLaunchCommandTests.swift` beside `planNeedsConfirmation`. | The rule worth pinning is the one that makes confirmation unnecessary: given a hidden surface, never launch. A separate `revealNeedsConfirmation(hasActiveProcess:)` that can only ever return `false` is dead code, which the project's engineering bar refuses. |
| D4 | Shape of that function. | `static func taskTerminalToggle(isVisible: Bool, hasSurface: Bool, hasLaunchCommand: Bool) -> TaskTerminalToggle`, with `TaskTerminalToggle` = `.hide` \| `.reveal` \| `.launch`. `.reveal` means "flip visibility, creating a plain-shell surface only if there is none" — exactly what `TerminalManager.toggleTaskTerminal(for:app:projectPath:)` already does, because it get-or-creates (`TerminalManager+TaskTerminals.swift:47-51`). | Three inputs, three outcomes, no `ghostty_app_t` needed, so the truth table is testable — the same split `firstTabSource` and `bottomPanelAction` make. |
| D5 | Truth table. | `isVisible` → `.hide`. Otherwise `hasSurface` → `.reveal`. Otherwise `hasLaunchCommand` → `.launch`, else `.reveal`. | `hasSurface` dominating `hasLaunchCommand` is the fix. The final `.reveal` is today's plain-shell branch (`WorkTaskCoordinator+TaskTerminal.swift:31-34`) unchanged. |
| D6 | Should a hidden surface be relaunched when the Main Terminal setting changed while it was hidden? | No. | Cmd+J is a show/hide toggle, not a launcher. Relaunching on a setting change would reintroduce the exact data loss this fixes. |
| D7 | Does the reveal path still take focus, and still post `taskTerminalOpened`? | Yes to both, unchanged. | `focusOnReveal` is Cmd+J's contract (`WorkTaskCoordinator+TaskTerminal.swift:9-12`); reveal awaits nothing, so focus lands synchronously the way the plain-shell branch already does. The notification posts once per toggle today, including on hide, and that stays. |
| D8 | Does the reveal path take the `beginTaskLaunch` in-flight claim? | No. | The claim exists because `await ShellEnvironment.awaitPath()` leaves the panel with no surface for a frame (`TerminalManager+TaskTerminals.swift:61-70`). A reveal awaits nothing and has a surface already, so there is nothing to claim and no frame to cover — the same reason a ⌘T login-shell tab takes no claim. |
| D9 | Is a new `TerminalManager` accessor needed for `hasSurface`? | No. | `existingTaskSurface(for:)` already answers it (`TerminalManager+TaskTerminals.swift:6-8`) and is already the read `TaskDetailView` uses. |

## Assumptions

Each verified against the codebase at the base commit. No probe scripts were written; the two
empirical checks below are reads of source, not runs.

**A1 — A hidden task terminal's surface stays alive.** `TerminalManager.toggleTaskTerminal(for:app:projectPath:)`
only flips `taskTerminalVisible[taskId]`; it never removes the entry from `taskSurfaces`
(`Sources/App/TerminalManager+TaskTerminals.swift:47-51`). `taskSurfaces` is a strong dictionary on
the manager (`Sources/App/TerminalManager.swift:44`), so the `NSView` outlives its removal from the
view tree.

**A2 — Removing the surface from the SwiftUI tree does not tear down the shell.**
`TerminalSurface` (`Sources/Ghostty/TerminalSurface.swift`) implements no `dismantleNSView` and never
calls `closeSurface()`; `TaskDetailView` renders it only under `if terminalVisible, let surface = …`
(`Sources/App/TaskDetailView.swift:93,117`). The only `closeSurface()` calls on a task surface are
`closeTaskTerminal` and `openTaskTerminal`'s replacement
(`Sources/App/TerminalManager+TaskTerminals.swift:59,85`). The secondary bottom panel is the shipped
precedent for the same hide/show-a-persistent-surface shape
(`Sources/App/TerminalManager+Panels.swift:49-52`, whose surface is documented as "never discarded or
respawned" at `TerminalManager+Panels.swift:10`).

**A3 — The destructive path is exactly the configured-command branch.** With Main Terminal set,
`taskTerminalLaunchCommand()` returns non-nil (`Sources/App/WorkTaskCoordinator+TaskTerminal.swift:47`)
and the re-show goes to `openTaskTerminal`, which does `taskSurfaces.removeValue(…)` then
`old.closeSurface()` (`Sources/App/TerminalManager+TaskTerminals.swift:83-86`). With Main Terminal
unset the `else` branch (`WorkTaskCoordinator+TaskTerminal.swift:31-34`) calls the get-or-create
toggle and already reuses correctly — which is why the bug only reproduces with an agent configured,
as the brief reports.

**A4 — "Closed" means no entry, so Cmd+J after an agent exits correctly launches fresh.** When a task
surface's process dies, the `.ghosttyCloseSurface` observer routes to `replaceSurface`, which removes
the task from `taskSurfaces`, `openTaskIds`, `taskTerminalVisible` and `taskTerminalHeights` rather
than respawning (`Sources/App/TerminalManager.swift:78-90, 389-399`). So `hasSurface == false` after
an exit and `.launch` is reached, with or without the panel having been hidden first.

**A5 — Both doors onto the task terminal share this decision.** Cmd+J routes through
`ContentView.bottomPanel` → `workTaskCoordinator.toggleTaskTerminal(…, focusOnReveal: true)`
(`Sources/App/ContentView.swift:112-116`); the toolbar button routes through
`WorkTaskListView.toggleTaskTerminal()` with `focusOnReveal` defaulted false
(`Sources/App/WorkTaskListView.swift:309-312`). Fixing the coordinator fixes both, and there is no
third caller (`grep` for `toggleTaskTerminal` finds only these two plus the manager method).

**A6 — Cmd+J is already claimed and declared; no keyboard work is in scope.** `AppKeyboardShortcuts.claims`
already covers `"j"` (`Sources/App/AppKeyboardShortcuts.swift:47`) and the key is declared once, on
`PanelCommands`' bottom-panel menu item. This change adds and retires no shortcut.

**A7 — `planNeedsConfirmation` and its dialog are unaffected.** The Start Now dropdown's
Replace/Cancel dialog is driven by `planToConfirm` in `WorkTaskListView`
(`Sources/App/WorkTaskListView.swift:21,190-207,278-285`) over `planTask`, which genuinely does open
a fresh surface over the old one (`TerminalManager+Commands.swift:66,80`). That door stays exactly as
it is.

## Objective

Pressing Cmd+J twice on a Tasks-destination task returns the operator to the same terminal session
they hid, with its agent still running, whatever Settings → Main Terminal is set to.

### Success criteria

1. Main Terminal names an agent; a task terminal is open with that agent running. Cmd+J hides it,
   Cmd+J re-shows it: the same surface reappears, the agent is still running, its scrollback is
   intact, and no dialog appears.
2. The re-shown surface takes first responder, as it does today.
3. Main Terminal is "None": behavior is unchanged — hide, then re-show the same plain shell.
4. No surface exists (never opened, or the previous one exited): Cmd+J opens one, running the
   configured Main Terminal command when there is one and a login shell otherwise. Unchanged.
5. The toolbar toggle in `WorkTaskListView` behaves identically except that it does not take focus.
6. `WorkTaskCoordinator.taskTerminalToggle(isVisible:hasSurface:hasLaunchCommand:)` is a pure static
   function whose full truth table (D5) is pinned by unit tests in
   `Tests/TaskTerminalLaunchCommandTests.swift`, beside `testPlanNeedsConfirmationOnlyWhenAProcessIsRunning`.
7. The Start Now dropdown's Replace/Cancel confirmation and the Delete confirmations are unchanged.
8. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports no new warnings.

## Verification

Per the project's `## Pipeline` section, one command serves as both regression check and full gate:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project, lints, builds and runs the test suite. Do not hand-write an
`xcodebuild` line. Before any CI stamp or sign-off, also run:

```bash
git status --porcelain
```

and report untracked or ignored files; expect `default.profraw` if the Debug app was launched.

Per memory, build agents do not launch the app or take screenshots — success criteria 1–5 are
checked by the operator by hand.

## Files this change touches

| File | Change |
| --- | --- |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | Add `TaskTerminalToggle` and the pure `taskTerminalToggle(isVisible:hasSurface:hasLaunchCommand:)`; rewrite `toggleTaskTerminal(taskId:app:focusOnReveal:)` to switch on it. Update the doc comment to state the reuse rule and why it exists. |
| `Tests/TaskTerminalLaunchCommandTests.swift` | Add the truth-table tests for the new function, in a `// MARK: -` section beside the existing plan-confirmation test. |

No new file is added, so the `xcodegen generate` that `ci.sh` runs changes nothing — but `ci.sh` is
still the only runner.

## Out of scope

- Any confirmation dialog on Cmd+J (D2).
- `planNeedsConfirmation`, the Start Now dropdown, and its Replace/Cancel dialog (A7).
- The delete confirmations in `WorkTaskListView`.
- The secondary terminal panel and the aside panel; only the Tasks bottom panel changes.
- Keyboard shortcut claims and declarations (A6).
- Persisting a task terminal across app launches, and restarting a surface whose process exited
  (A4's behavior is kept as is).
- The `taskTerminalOpened` notification's semantics, including that it posts on hide as well as on
  show (D7). Changing that is a separate, visible behavior change.
