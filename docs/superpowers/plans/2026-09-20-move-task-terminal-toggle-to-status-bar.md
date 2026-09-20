# Plan: Move the Task Terminal Toggle to the Status Bar

**Date:** 2026-09-20
**Base:** b4369a5adaf99c58d5c7dcee82041c99b37c2f60

Breaks down `docs/superpowers/specs/2026-09-20-move-task-terminal-toggle-to-status-bar.md`.

## Architecture decisions carried from the spec

1. Exactly one control moves: the `.primaryAction` `ToolbarItem` holding
   `Button(action: toggleTaskTerminal)` with the `rectangle.bottomhalf.inset.filled` icon
   (`WorkTaskListView.swift:119-126`). Every other item in that toolbar — `+`, Start Now, Copy task,
   `…`, the edit/preview `Picker` — stays exactly where it is.
2. Its new home is the trailing end of `TaskDetailView.pathBar(for:)`'s existing `HStack(spacing: 0)`,
   directly after the `Spacer()`. The path text keeps the leading edge.
3. The action lives on `TaskDetailView`, not in a parameter. The view gains one
   `@EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator` and calls
   `workTaskCoordinator.toggleTaskTerminal(taskId: taskId, app: app)` behind a
   `guard let app = ghosttyApp.app`. It already holds `taskId`, `terminalVisible` and `ghosttyApp`,
   so nothing has to be handed in — unlike `WorktreeStatusBar`, which does not know which worktree
   it draws. `ContentView` gains nothing; it is at 1014 lines against SwiftLint's 1000-line
   `file_length` error and only builds on its file-wide disable.
4. The toolbar item's `.disabled(selectedTask == nil || ghosttyApp.readiness != .ready)` does not
   come along: **both** halves become structural at the new site, so the button carries no
   `.disabled`. `pathBar` renders only inside `body`'s `if let task`, and `TaskDetailView` is
   constructed only inside `readinessDetailView`'s `.ready` branch (`ContentView.swift:810-811`,
   `934`) while `Ghostty.App.readiness` is written only in `init()`. The old toolbar site needed the
   modifier because `WorkTaskListView` renders outside that readiness switch; the new one does not.
5. No `readiness` gate on the button, because item 4 makes one unreachable. The
   `guard let app = ghosttyApp.app` stays inside the action, where the launch needs the pointer. Had
   a view gate been needed it would have read `readiness`, not `ghosttyApp.app`: `readiness` is
   `@Published`, `app` is a plain computed property with no change to publish — the reason
   `WorkTaskListView`'s own controls, which do render outside the readiness switch, keep using it.
6. The disabled-versus-omitted question does not arise at the new site: the not-ready state is
   unreachable there. It still governs the controls that stayed in the Tasks toolbar.
7. The action is the non-focusing one: `focusOnReveal` is left at its `false` default, the same call
   the toolbar button makes today. ⌘J keeps `true`.
8. The button's idiom is the bar's, not the toolbar's: `.font(.system(size: 11))`,
   `.foregroundStyle(terminalVisible ? .primary : .secondary)`, inside `.buttonStyle(.plain)`. The
   toolbar's `.opacity(… ? 1 : 0.5)` does not come along, and there is no enlarged hit frame.
9. The tooltip comes over verbatim and is hoisted into a `terminalToggleLabel` computed property so
   `.help()` and a new `.accessibilityLabel()` cannot drift. It gains `.pointerCursorOnHover()`.
10. No nested `HStack`: the toggle is the only trailing item, so it goes straight after the
    `Spacer()` in the existing `HStack(spacing: 0)`.
11. No `ToolbarGroupBreak()` changes. The toggle sits mid-capsule between Copy task and the `…`
    menu, so removing it leaves no dangling or doubled separator.
12. `taskTerminalOpen` and `toggleTaskTerminal()` on `WorkTaskListView` are deleted — the removed
    toolbar item is their only reader. `ghosttyApp` and `workTaskCoordinator` stay declared on that
    view; `startNowItems` and `runPlan` still read them.
13. No change to ⌘J, `PanelToggle`, `PanelCommands` or `AppKeyboardShortcuts`, and none to
    `WorkTaskWindow`'s own path bar.
14. No new test and no new file. The change is view-only and introduces no decision rule;
    `./scripts/ci.sh` is the regression check and the operator confirms the control by hand.
15. Two stale doc lines are corrected in the same change: `CLAUDE.md:235` and the doc comment at
    `WorkTaskCoordinator+TaskTerminal.swift:9-10`.

## Dependency graph

```
T1 (the only task)
```

Both halves of the move — adding the button and removing the toolbar item — must land together, or
the control renders twice. The two doc lines describe the shape this task creates, so they land with
it. Nothing unblocks anything else.

## Task list

### T1: Move the task terminal toggle from the Tasks toolbar into `TaskDetailView`'s path bar

**Files touched**

- `Sources/App/TaskDetailView.swift`
- `Sources/App/WorkTaskListView.swift`
- `Sources/App/WorkTaskCoordinator+TaskTerminal.swift`
- `CLAUDE.md`

**What it does**

*In `TaskDetailView.swift`:*

Add the coordinator to the `@EnvironmentObject` block at the top of the struct (after `settings`,
line 13):

```swift
@EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator
```

Add a label property beside the existing `terminalVisible` computed property (lines 35-37):

```swift
private var terminalToggleLabel: String {
    terminalVisible ? "Hide terminal" : "Show terminal"
}
```

Add the action as a private method in the file's `// MARK: - Path Bar` section, beside `pathBar`:

```swift
private func toggleTerminal() {
    guard let app = ghosttyApp.app else { return }
    workTaskCoordinator.toggleTaskTerminal(taskId: taskId, app: app)
}
```

In `pathBar(for:)`, insert the button immediately after the existing `Spacer()` and before the
closing brace of the `HStack(spacing: 0)`. Every padding, `.background(.bar)` and `.overlay` modifier
below it is unchanged, and the `Text` above it is untouched:

```swift
Spacer()
Button(action: toggleTerminal) {
    Image(systemName: "rectangle.bottomhalf.inset.filled")
        .font(.system(size: 11))
        .foregroundStyle(terminalVisible ? .primary : .secondary)
}
.buttonStyle(.plain)
.help(terminalToggleLabel)
.accessibilityLabel(terminalToggleLabel)
.pointerCursorOnHover()
```

Add no comment anywhere in this edit — CLAUDE.md treats one here as a smell.

*In `WorkTaskListView.swift`:*

Delete the whole terminal-toggle `ToolbarItem` — lines 119-126 at base, the block beginning
`ToolbarItem(placement: .primaryAction) {` wrapping `Button(action: toggleTaskTerminal)` and ending
with `.disabled(selectedTask == nil || ghosttyApp.readiness != .ready)` and its closing brace. Touch
neither `ToolbarGroupBreak()` (lines 76 and 89) and neither neighbouring item: the Copy task item
above it and the `…` menu below it stay exactly as they are.

Delete the two now-unread private members (lines 304-312 at base):

```swift
private var taskTerminalOpen: Bool { … }
private func toggleTaskTerminal() { … }
```

Leave `@EnvironmentObject ghosttyApp` and `@EnvironmentObject workTaskCoordinator` declared on the
view — `startNowItems` reads `ghosttyApp.readiness`, and `runPlan` reads `ghosttyApp.app` and calls
`workTaskCoordinator.planTask`.

*In `WorkTaskCoordinator+TaskTerminal.swift`:*

In the doc comment above `toggleTaskTerminal(taskId:app:focusOnReveal:)`, change the phrase
"the toolbar button `false`" to "the status bar button `false`". Change nothing else in the file.

*In `CLAUDE.md`:*

At line 235, change "the copy/terminal/`…` group" to "the copy/`…` group". Change nothing else.

**Acceptance criteria**

1. With a task selected, `TaskDetailView`'s path bar renders the
   `rectangle.bottomhalf.inset.filled` button at its trailing edge, with the file path still at the
   leading edge.
2. Clicking it shows or hides that task's bottom terminal, exactly as the toolbar button did, and
   does not move keyboard focus into the revealed terminal.
3. The glyph is `.primary` while the terminal is visible and `.secondary` while it is hidden; the
   tooltip reads "Hide terminal" or "Show terminal" to match; hovering shows the pointing-hand
   cursor.
4. The button carries no readiness gate. The path bar renders only inside `readinessDetailView`'s
   `.ready` branch, so the not-ready state never shows a path bar to gate.
5. Clicking the path text still copies it and still shows "Copied!"; clicking the button does not
   copy the path.
6. The Tasks toolbar reads `+ │ Start Now │ Copy · … · Picker` — no terminal button, and no doubled
   or orphaned separator where it was.
7. View → Show/Hide Bottom Panel still carries ⌘J on the Tasks destination, still focuses the task
   terminal on reveal, and still greys out on a standalone Task/Prompt/Settings window.
8. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports zero errors for the change.

**How the criteria are verified**

- Criteria 1-7 are confirmed by the operator in the running app (`./scripts/run.sh`), on a project
  with at least one backlog task. Per memory, the build agent does not launch the app or take
  screenshots.
- Criterion 2 is additionally checkable from the diff: `toggleTerminal()` passes no `focusOnReveal:`
  argument, so it takes the `false` default, and `WorkTaskCoordinator+TaskTerminal.swift`'s body is
  untouched — only its doc comment changes.
- Criterion 7 is additionally checkable from the diff: `PanelCommands.swift`,
  `AppKeyboardShortcuts.swift` and `ContentView.swift` do not appear in it at all.
- Criterion 8: `./scripts/ci.sh`, the regression check named in CLAUDE.md's `## Pipeline` section.
  Do not hand-write an `xcodebuild` line — `xcodegen generate` runs inside it and `build.sh`'s
  `PRODUCT_NAME` override breaks `TEST_HOST`. SwiftLint runs inside it too; both Swift files are
  linted (only `Sources/Ghostty` and `BuildInfo.generated.swift` are excluded).
  `TaskDetailView.swift` goes from 272 lines to roughly 289 and `WorkTaskListView.swift` from 384 to
  roughly 367, both far under the 700-line `file_length` warning; `pathBar` goes from 28 lines to
  roughly 38 against the 100-line `function_body_length` warning.

**Notes for the build agent**

- `TaskDetailView` has exactly one construction site, `ContentView.swift:934`, inside the
  `detailSelection == .tasks` branch of `detailView`. `ProjectWindow.swift:113` already applies
  `.environmentObject(workTaskCoordinator)` to `ContentView()`, so the new `@EnvironmentObject`
  resolves with no call-site change. `grep -rn "TaskDetailView" Sources Tests` to confirm.
- `pointerCursorOnHover()` is the internal `View` extension at `ContentViewHelpers.swift:228-232`,
  same module and target. Its overlay's `hitTest` returns `nil`, so the click still reaches the
  button.
- `WorktreeStatusBar` (`ContentViewHelpers.swift:80-129`) is the shipped precedent for every line of
  the new button, down to the hoisted `secondaryToggleLabel`. Copy its shape; do not copy any
  comment.
- `WorkTaskListView.toggleTaskTerminal()` is a different symbol from
  `TerminalManager.toggleTaskTerminal(for:app:projectPath:)` and
  `WorkTaskCoordinator.toggleTaskTerminal(taskId:app:focusOnReveal:)`. Only the first is deleted;
  the other two keep their callers. Confirm with
  `grep -rn "taskTerminalOpen\|toggleTaskTerminal" Sources Tests` before and after.
- Line numbers above are against base `b4369a5`. Edit by matching the surrounding code, not by line
  number, and make all four files' edits in one pass — the project does not build between the two
  Swift halves.
- A Debug launch drops an un-gitignored `default.profraw` in the repo root. Never `git add -A`;
  report the file rather than committing it.

## Risks and mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Deleting one line too many or too few from the toolbar takes the Copy task item's closing brace or the `…` menu's opening one with it | Low | The build fails immediately; the deleted block is bounded by `Button(action: toggleTaskTerminal)` above and `Menu {` below, both unique in the file. Criterion 6 checks the resulting capsules in the running app. |
| The 11pt `.secondary` glyph reads as too faint in the hidden state | Low | It matches the bar's own idiom for a state change, and the same glyph already ships at the same size in `WorktreeStatusBar`. Settled by the operator's check under criterion 3. |
| A missing `.environmentObject(workTaskCoordinator)` on some ancestry crashes at runtime rather than at compile time | Low | `ContentView` itself already reads `WorkTaskCoordinator` as an `@EnvironmentObject` (`ContentView.swift:63`) and `TaskDetailView` renders inside its detail column, so the one ancestry is already satisfied. `WorkTaskWindow` is a different type and is not touched. |
| `ShellPathResolverTests` flakes under load during the CI run | Low | Known pre-existing and load-sensitive, established under PR #221; unrelated to view code. Re-run on a settled machine rather than changing anything. |

## Out of scope

Everything the spec's "Out of scope" section lists: ⌘J / `PanelToggle` / `PanelCommands` /
`AppKeyboardShortcuts`, making the status-bar click focus the task terminal, `WorkTaskWindow`'s path
bar and `PromptDetailView`, any other path-bar content, the worktree destination's status bar and
toolbar, and splitting `ContentView.swift` below SwiftLint's 1000-line error.

## Build log

### T1: Move the task terminal toggle from the Tasks toolbar into `TaskDetailView`'s path bar

**What landed**

| File | State |
| --- | --- |
| `Sources/App/TaskDetailView.swift` | +20 lines. Gained `@EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator` after `settings`; `terminalToggleLabel` beside `terminalVisible`; the button after `pathBar`'s `Spacer()` with `.buttonStyle(.plain)`, `.help`, `.accessibilityLabel`, `.pointerCursorOnHover()`, `.disabled(ghosttyApp.readiness != .ready)`; `toggleTerminal()` below `pathBar` guarding `ghosttyApp.app`. No comments added. 272 → 292 lines. |
| `Sources/App/WorkTaskListView.swift` | −19 lines. The terminal-toggle `ToolbarItem` and the `taskTerminalOpen` / `toggleTaskTerminal()` private members deleted. Both `ToolbarGroupBreak()`s, the Copy task item, the `…` menu and both `@EnvironmentObject`s untouched. 384 → 365 lines. |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | Doc comment only: "the toolbar button `false`" → "the status bar button `false`". Body unchanged. |
| `CLAUDE.md` | "the copy/terminal/`…` group" → "the copy/`…` group". |

**Evidence**

No test was added or watched failing: plan item 14 and spec decision 16 settle that this change is
view-only, introduces no decision rule, and has no pure helper worth lifting out. There is therefore
no watched failure to quote. The diff-checkable criteria were confirmed directly:

- Criterion 2 (no focus steal): `toggleTerminal()` calls
  `workTaskCoordinator.toggleTaskTerminal(taskId: taskId, app: app)` with no `focusOnReveal:`
  argument, taking the `false` default. `WorkTaskCoordinator+TaskTerminal.swift`'s body is untouched.
- Criterion 7 (⌘J unchanged): `ContentView.swift`, `PanelCommands.swift` and
  `AppKeyboardShortcuts.swift` do not appear in the diff at all (`git diff --stat` lists four files).
- Symbol removal: `grep -rn "taskTerminalOpen\|toggleTaskTerminal" Sources Tests` now returns only
  `WorkTaskCoordinator.toggleTaskTerminal` (declaration + the new `TaskDetailView` call site + the
  ⌘J call site), `TerminalManager.toggleTaskTerminal(for:app:projectPath:)`, the unrelated
  `taskTerminalOpened` notification, and one test doc comment. Both deleted members are gone and
  neither other symbol lost a caller.

**Deviations from the plan**

None. All four files were edited in one pass, by matching surrounding code rather than line numbers.

**Gate**

`./scripts/ci.sh` — passed. "Executed 676 tests, with 0 failures (0 unexpected) in 107.571 seconds",
`Test Succeeded`, `==> CI passed.` `ShellPathResolverTests` did not flake. `swiftlint lint --quiet`
run separately after the last edit: no output, exit status 0.

`git status --porcelain` before the commit showed the four modified files plus the untracked spec and
plan documents, which are committed with this task. No `default.profraw` — the app was not launched.

### Simplify

Dropped the now-false "the sibling toolbar buttons already use it" cross-reference from
`startNowItems`' doc comment and the matching CLAUDE.md sentence — the moved toggle was the only such
sibling — leaving the `readiness`-over-`app` reason stated on its own. Renamed the caller in
`WorkTaskCoordinator+TaskTerminal.swift`'s doc comment from "status bar button" to "path bar button",
matching `TaskDetailView.pathBar(for:)`. Comments only; no code changed.

## Changelog

### Review follow-up: drop the unreachable readiness gate

Two findings from the review step, applied on top of `9e68df3` and `9f2cf9b`.

| File | State |
| --- | --- |
| `Sources/App/TaskDetailView.swift` | −1 line. `.disabled(ghosttyApp.readiness != .ready)` removed from the path bar button. `toggleTerminal()`'s `guard let app = ghosttyApp.app` unchanged. |
| `Tests/TaskTerminalLaunchCommandTests.swift` | Doc comment only: "the toolbar toggle and Cmd+J" → "the path bar toggle and Cmd+J". |
| `docs/superpowers/specs/2026-09-20-move-task-terminal-toggle-to-status-bar.md` | Decisions 4-6 rewritten and re-sourced to Operator; success criterion 5 and the `TaskDetailView.swift` row of "Files touched" restated. |
| `docs/superpowers/plans/2026-09-20-move-task-terminal-toggle-to-status-bar.md` | Carried decisions 4-6, T1's code snippet and acceptance criterion 4 restated; this section. |

The gate was unreachable, not merely redundant: `TaskDetailView` is constructed only at
`ContentView.swift:934`, inside `readinessDetailView`'s `.ready` branch (`ContentView.swift:810-811`),
and `Ghostty.App.readiness` is assigned only in `init()` (`Ghostty.App.swift:39`, `49`, `84`). So the
view cannot be on screen while readiness is `.loading` or `.error`, and the condition is constant
`false` wherever the button renders. The old toolbar site did need it — `WorkTaskListView` renders
whenever `detailSelection == .tasks`, outside that switch — which is why the modifier came across in
the first place.

The T1 build log above is left as the record of what that commit landed; it is not rewritten.

**Gate**

`./scripts/ci.sh` — see the result recorded with the commit.
