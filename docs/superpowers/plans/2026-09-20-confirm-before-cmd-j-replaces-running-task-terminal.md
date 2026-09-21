# Confirm before Cmd+J replaces a running task terminal

**Date:** 2026-09-20
**Base:** b4369a5adaf99c58d5c7dcee82041c99b37c2f60 (Split buttons for Run and Open in (#237))

Breaks down `docs/superpowers/specs/2026-09-20-confirm-before-cmd-j-replaces-running-task-terminal.md`.

## Architecture decisions carried from the spec

- D1: Fix the cause. Re-showing a hidden task terminal reuses the hidden surface, so the running
  agent survives.
- D2: No confirmation dialog is added anywhere. After D1 no Cmd+J path replaces a live surface, so a
  dialog would be unreachable UI. (Operator confirmed this scope after the spec.)
- D3: The rule pinned by unit tests is the whole Cmd+J decision, not a `revealNeedsConfirmation` that
  could only ever return `false`.
- D4: The decision is `static func taskTerminalToggle(isVisible: Bool, hasSurface: Bool, hasLaunchCommand: Bool) -> TaskTerminalToggle`
  on `WorkTaskCoordinator`, with `TaskTerminalToggle` = `.hide` | `.reveal` | `.launch`. No
  `ghostty_app_t` is involved, so the truth table is testable.
- D5: Truth table — `isVisible` → `.hide`; else `hasSurface` → `.reveal`; else `hasLaunchCommand` →
  `.launch`; else `.reveal`. `hasSurface` dominating `hasLaunchCommand` is the fix.
- D6: A hidden surface is never relaunched because the Main Terminal setting changed while it was
  hidden. Cmd+J is a show/hide toggle, not a launcher.
- D7: The reveal path still takes focus when `focusOnReveal` is true, synchronously (it awaits
  nothing). Notification behavior is unchanged — see "Behavior to preserve exactly" below.
- D8: The reveal path takes no `beginTaskLaunch` claim: it awaits nothing and already has a surface.
- D9: No new `TerminalManager` accessor. `existingTaskSurface(for:)` answers `hasSurface` and
  `isTaskTerminalVisible(for:)` answers `isVisible`.

`.reveal` means "call `terminalManager.toggleTaskTerminal(for:app:projectPath:)`", which get-or-creates
the surface and flips visibility (`Sources/App/TerminalManager+TaskTerminals.swift:46-51`). That is
why one case serves both "a hidden surface exists" and "nothing configured to launch".

## Behavior to preserve exactly

The `taskTerminalOpened` notification posts on show only: the hide branch of
`toggleTaskTerminal(taskId:app:focusOnReveal:)` returns before the
`NotificationCenter.default.post(...)` at the end of the method
(`Sources/App/WorkTaskCoordinator+TaskTerminal.swift:18-21, 37`). That is the only post on this
toggle's path — `planTask`, further down the same file, posts the notification for its own launch.
The spec's D7 first read this the other way round and has been corrected; the intent was always
"notification semantics are out of scope and unchanged", so **keep the shipped behavior: `.hide`
returns without posting; `.reveal` and `.launch` post.** Do not add a post to the hide path and do
not remove one from the others.

Everything else the method does today stays: the `workTaskManager.tasks.contains` guard up front,
`projectPath` from `worktreeManager.projectPath`, `focusOnReveal` defaulting to `false`, and the
`.launch` path keeping its `beginTaskLaunch`/`endTaskLaunch` claim, its
`await ShellEnvironment.awaitPath()`, and focusing after the await.

## Dependency graph

```
T1 (pure decision + truth-table tests)
    │
    └── T2 (route toggleTaskTerminal through the decision)
```

T2 depends on T1 because it switches on the type and function T1 introduces. There is no third task
and nothing to parallelize.

## Verification command

Both tasks verify with the project's one runner, from the worktree root:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project, lints, builds and runs the test suite. Do not hand-write an
`xcodebuild` line. Per memory, build agents do not launch the app or take screenshots; the spec's
success criteria 1–5 are checked by the operator by hand after the branch is built.

### T1: Pure Cmd+J toggle decision, with its truth table pinned

**Files**

- `Sources/App/WorkTaskCoordinator+TaskTerminal.swift`
- `Tests/TaskTerminalLaunchCommandTests.swift`

**What it does**

In `extension WorkTaskCoordinator` in `WorkTaskCoordinator+TaskTerminal.swift`, add a nested
`enum TaskTerminalToggle: Equatable { case hide, reveal, launch }` and the pure

```swift
static func taskTerminalToggle(isVisible: Bool, hasSurface: Bool, hasLaunchCommand: Bool) -> TaskTerminalToggle
```

implementing D5: `isVisible` → `.hide`; else `hasSurface` → `.reveal`; else `hasLaunchCommand` →
`.launch`; else `.reveal`. Follow `TerminalManager.FirstTabSource` /
`TerminalManager.firstTabSource(afterCreateCommand:mainCommand:)`
(`Sources/App/TerminalManager.swift:174, 211`) for shape and placement.

Give the function a doc comment that states the load-bearing rule and why it exists: a hidden
surface is revealed, never relaunched, because `openTaskTerminal` closes the surface it replaces
(`Sources/App/TerminalManager+TaskTerminals.swift:83-86`), which killed a running agent with no
warning. Say that this is why confirmation is unnecessary on this path. No other comments.

In `Tests/TaskTerminalLaunchCommandTests.swift`, add a `// MARK: -` section beside the existing
`testPlanNeedsConfirmationOnlyWhenAProcessIsRunning` covering **all eight** input combinations of the
three booleans. The test needs no coordinator instance and no `ghostty_app_t` — the function is
static and pure.

Nothing calls the new function yet; T2 wires it in. It is `internal static` and referenced by the
tests, so it is not an unused declaration.

**Acceptance criteria**

- `WorkTaskCoordinator.taskTerminalToggle(isVisible:hasSurface:hasLaunchCommand:)` exists, is
  `static`, reads no instance state, and returns `.hide` / `.reveal` / `.launch` per D5.
- All eight input combinations are asserted in `Tests/TaskTerminalLaunchCommandTests.swift`,
  including both `isVisible == true` rows (which are `.hide` regardless of the other two) and the
  `hasSurface == true, hasLaunchCommand == true` row that encodes the fix.
- `toggleTaskTerminal(taskId:app:focusOnReveal:)` is left untouched by this task.

**How the criteria are verified**

- `./scripts/ci.sh` is green, and its test output includes the new test(s).
- `swiftlint lint --quiet` introduces no new warning.

### T2: Route the task terminal toggle through the decision

**Files**

- `Sources/App/WorkTaskCoordinator+TaskTerminal.swift`

**What it does**

Rewrite the body of `toggleTaskTerminal(taskId: UUID, app: ghostty_app_t, focusOnReveal: Bool = false)`
to compute the inputs and `switch` on `Self.taskTerminalToggle(...)`:

- `isVisible` = `terminalManager.isTaskTerminalVisible(for: taskId)`
- `hasSurface` = `terminalManager.existingTaskSurface(for: taskId) != nil`
- `hasLaunchCommand` — resolve `taskTerminalLaunchCommand()` once, before the switch, and use its
  non-nil-ness as the input so the `.launch` case has the closure in hand without asking twice.
  `mainCommandProvider()` is read once per press today and must stay read once.

Case bodies:

- `.hide` — `terminalManager.toggleTaskTerminal(for: taskId, app: app, projectPath: projectPath)`
  and return without posting `taskTerminalOpened` (see "Behavior to preserve exactly").
- `.reveal` — the same `terminalManager.toggleTaskTerminal(...)` call, then
  `if focusOnReveal { focusTaskTerminal(taskId) }`, then post. No `beginTaskLaunch` claim and no
  `Task {}` (D8): the reveal is synchronous. Reaching `.reveal` with a surface already present makes
  the manager's get-or-create a plain visibility flip, so the hidden surface and its running agent
  are reused untouched.
- `.launch` — today's configured-command branch verbatim: `beginTaskLaunch` guard,
  `Task { @MainActor in }` with `defer { endTaskLaunch }`, build the command from
  `await ShellEnvironment.awaitPath()`, `terminalManager.openTaskTerminal(...)`, then
  `if focusOnReveal { focusTaskTerminal(taskId) }`. Then post.

Update the method's doc comment so it states the toggle's three outcomes and that a hidden surface is
revealed rather than relaunched. Keep the existing explanation of `focusOnReveal`'s two callers
(Cmd+J passes `true`, the toolbar button `false`) and correct its claim that focus always lands after
an `await` — that is true only on `.launch` now.

Both callers keep their current call sites unchanged: `ContentView.swift:115` (Cmd+J, via
`bottomPanel`) and `WorkTaskListView.swift:311` (toolbar button). No signature changes, no new
`TerminalManager` API, no change to `taskTerminalLaunchCommand`, `planNeedsConfirmation`, `planTask`,
or any dialog.

**Acceptance criteria**

- The method's only decision is the `switch` over `Self.taskTerminalToggle(...)`; no `isVisible` /
  `hasSurface` / command branching is duplicated in the body.
- With a hidden surface present and a Main Terminal command configured, the code path taken calls
  `terminalManager.toggleTaskTerminal(...)` and never `openTaskTerminal(...)` or `beginTaskLaunch(...)`
  — read off the `switch`, since the method is unreachable from XCTest.
- The `.launch` path still claims and releases the in-flight marker and still resolves the shell PATH
  before building its command.
- `.hide` posts no notification; `.reveal` and `.launch` each post exactly one.
- No confirmation dialog, alert, or `@State` flag is added.

**How the criteria are verified**

- `./scripts/ci.sh` is green; the existing `TaskTerminalLaunchCommandTests` and T1's truth-table
  tests still pass.
- `swiftlint lint --quiet` introduces no new warning.
- Operator hand-check of spec success criteria 1–5 (hide/re-show with an agent configured, focus on
  reveal, the "None" setting, the no-surface case, and the toolbar toggle not taking focus).

## Build log

### T1: Pure Cmd+J toggle decision, with its truth table pinned

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | Added `TaskTerminalToggle` (`.hide`/`.reveal`/`.launch`) and `static func taskTerminalToggle(isVisible:hasSurface:hasLaunchCommand:)` implementing D5, placed above `taskTerminalLaunchCommand` and shaped after `TerminalManager.FirstTabSource` / `firstTabSource`. `toggleTaskTerminal(taskId:app:focusOnReveal:)` untouched. |
| `Tests/TaskTerminalLaunchCommandTests.swift` | Added a `// MARK: - Toggling the task terminal` section with three tests covering all eight combinations: `testVisiblePanelAlwaysHides` (the four `isVisible == true` rows, via nested loops), `testHiddenSurfaceIsRevealedEvenWithALaunchCommand` (both `hasSurface == true` rows, the fix), `testNoSurfaceLaunchesOnlyWhenACommandIsConfigured` (the two pre-existing branches). |

**Watched failure.** The tests were written first and `./scripts/ci.sh` run against the unimplemented
function. It failed to build:

```
❌ Tests/TaskTerminalLaunchCommandTests.swift:84:33: type 'WorkTaskCoordinator' has no member 'taskTerminalToggle'
❌ Tests/TaskTerminalLaunchCommandTests.swift:86:14: type 'Equatable' has no member 'launch'
```

A behavioral red is not available for this task: the function is new and pure, and the bug it encodes
lives in `toggleTaskTerminal`, which T2 rewrites and which is unreachable from XCTest (non-optional
`ghostty_app_t`). The `.reveal` assertion for `hasSurface == true, hasLaunchCommand == true` is the
row that fails against the shipped decision, which returns the launch branch there.

**Deviations from the plan.** None. The plan asked for all eight combinations; they are asserted
across three named tests rather than one, so a failure names which rule broke. The four
`isVisible == true` rows are asserted in a loop with a message identifying the combination.

**Gate.** `./scripts/ci.sh` — green: `Executed 679 tests, with 0 failures`, `==> CI passed.`
`swiftlint lint --quiet` runs inside it and printed nothing new.

One flake was seen on the first green-code run and did not reproduce:
`WorktreeGroupManagerNameTests.testReconcilePopulatesNamesFromConfigAndDropsAClearedOne` failed with
`could not lock config file …/config.worktree: File exists` — a git config lock in its own temp repo,
unrelated to this change. The immediately following run of the same commit was fully green.

### T2: Route the task terminal toggle through the decision

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | `toggleTaskTerminal(taskId:app:focusOnReveal:)` rewritten: keeps the `workTaskManager.tasks.contains` guard and `projectPath`, resolves `taskTerminalLaunchCommand()` once into `makeCommand`, then `switch Self.taskTerminalToggle(isVisible: terminalManager.isTaskTerminalVisible(for:), hasSurface: terminalManager.existingTaskSurface(for:) != nil, hasLaunchCommand: makeCommand != nil)`. `.hide` flips the manager's toggle and returns before the post; `.reveal` flips it, focuses when `focusOnReveal`, falls through to the post; `.launch` is the old configured-command branch verbatim (`beginTaskLaunch` guard, `Task { @MainActor in }` with `defer { endTaskLaunch }`, `await ShellEnvironment.awaitPath()`, `openTaskTerminal`, focus after the await) and falls through to the post. Doc comment restated: three outcomes, a hidden surface revealed rather than relaunched, and `focusOnReveal` landing after the `await` only on `.launch`. |

**Acceptance criteria, read off the switch** (the method takes a non-optional `ghostty_app_t`, so it is
unreachable from XCTest — the plan says to read these off the code):

- The only decision left in the body is the `switch`. No `isVisible`, `hasSurface` or
  command-presence branching is repeated: the three inputs are computed inline in the
  `taskTerminalToggle(...)` call and nowhere else.
- Hidden surface + configured Main Terminal command → `isVisible == false`, `hasSurface == true`, so
  the decision is `.reveal`, whose body calls only
  `terminalManager.toggleTaskTerminal(for:app:projectPath:)`. `openTaskTerminal` and
  `beginTaskLaunch` appear only inside `case .launch`.
- `.launch` still guards on `beginTaskLaunch`, still `defer`s `endTaskLaunch`, and still builds its
  command from `await ShellEnvironment.awaitPath()`.
- `.hide` returns before `NotificationCenter.default.post`; `.reveal` and `.launch` each reach it
  exactly once. A `.launch` whose `beginTaskLaunch` claim is refused returns without posting, as it
  does today.
- No alert, dialog or `@State` flag was added; no signature changed; the two call sites
  (`ContentView.swift:115`, `WorkTaskListView.swift:311`) are untouched.

**Evidence.** T2 adds no test, and no new watched failure is available for it: the behavior it
changes lives in a method XCTest cannot call, and the rule it now routes through is the one T1 pinned
— the red quoted in T1's build log is the red for this fix. `.reveal` for
`hasSurface == true, hasLaunchCommand == true` is asserted by
`testHiddenSurfaceIsRevealedEvenWithALaunchCommand`, and the shipped code reached
`openTaskTerminal` on exactly that row.

**Deviations from the plan.** One, in the plan's own direction: `taskTerminalLaunchCommand()` is now
resolved before the switch, so it is also evaluated on the `.hide` path, where the old code returned
first. It reads `terminalManager.mainCommandProvider()` — which `ContentView.swift:400` wires to
`settings.configuredMainTerminalCommand` — and builds a closure; there is no side effect, and it is
still read exactly once per press. The `.launch` case unwraps `makeCommand` in the same `guard` as
the `beginTaskLaunch` claim; the nil arm is unreachable, since `hasLaunchCommand` is what selected
the case.

**Gate.** `./scripts/ci.sh` — green after the last edit: `Executed 679 tests, with 0 failures`,
`Test Succeeded`, `==> CI passed.` `swiftlint lint --quiet` printed nothing. `git status --porcelain`
showed only ` M Sources/App/WorkTaskCoordinator+TaskTerminal.swift` before this build log was
appended; no `default.profraw`, since the app was not launched.

### Simplify

`/simplify` over `main...HEAD`: reuse, efficiency and altitude came back clean — the altitude pass
confirmed the rule belongs on the coordinator, since `openTaskTerminal`'s replace contract is what
the plan path (`TerminalManager+Commands.swift`) needs and already confirms through
`planNeedsConfirmation`. Applied, behavior untouched: cut the `toggleTaskTerminal` doc's first
paragraph, which re-enumerated the three cases and repeated the regression rationale the
`taskTerminalToggle` doc owns; dropped the hardcoded `TerminalManager+TaskTerminals.swift:84-86`
line reference, keeping the `openTaskTerminal` symbol name as the durable one; reworded `.reveal`'s
case doc so it no longer reads as requiring an existing surface; flattened
`testVisiblePanelAlwaysHides`'s nested `for` loop into its four literal rows, matching its two
siblings. Skipped: dropping `: Equatable` from `TaskTerminalToggle` — payload-free decision enums
declare it explicitly here (`BottomPanelAction`, `ContentView.swift:41`), so it is convention, not a
no-op to remove. Also skipped collapsing the enum to a `needsLaunch` Bool: it would move the
hide-vs-reveal branch back into the method XCTest cannot reach, against T2's acceptance criterion
that the switch is the body's only decision, and `FirstTabSource` is the precedent for a named
three-outcome rule.
