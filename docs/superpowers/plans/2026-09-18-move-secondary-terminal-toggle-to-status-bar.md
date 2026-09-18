# Plan: Move the Secondary Terminal Toggle to the Status Bar

**Date:** 2026-09-18
**Base:** 7ae81c1fca4c52beaf290a2035746c975ff95c69
**PR:** #221

Breaks down `docs/superpowers/specs/2026-09-18-move-secondary-terminal-toggle-to-status-bar.md`.

## Architecture decisions carried from the spec

1. Exactly one control moves: the `.primaryAction` `ToolbarItem` holding
   `Button(action: toggleSecondaryTerminal)` with the `rectangle.bottomhalf.inset.filled` icon
   (`ContentView.swift:218-224`). The aside toggle beside it and every other toolbar item stay.
2. Its new home is the trailing end of `WorktreeStatusBar`'s `HStack`, **after** `prStatusView`, so
   the right-hand order is PR status then toggle.
3. The toggle is unconditional inside the bar. The `!wt.isMain` gate stays on `prStatusView` alone,
   so on the primary worktree the toggle sits alone against the trailing edge.
4. One of the two bracketing `ToolbarGroupBreak()`s survives, leaving `Run │ [Open in] │ Remove │
   Aside` with one separator between each pair.
5. The action stays `toggleSecondaryTerminal` — the non-focusing one. ⌘J keeps
   `toggleAndFocusSecondary`. This is a move, not a behavior change.
6. State reaches the bar as two plain parameters, `secondaryVisible: Bool` and
   `onToggleSecondary: () -> Void` — **not** a `PanelToggle`, which carries the focusing action and
   would invite the wrong one to be passed.
7. The button's visual idiom is the bar's, not the toolbar's: `.font(.system(size: 11))` and
   `.foregroundStyle(secondaryVisible ? .primary : .secondary)`, inside `.buttonStyle(.plain)`. The
   toolbar's `.opacity(… ? 1 : 0.5)` does not come along.
8. It keeps its tooltip verbatim and gains `.pointerCursorOnHover()`, matching the bar's other
   clickable items. No text label.
9. No change to ⌘J, `PanelToggle`, `PanelToggleMenuItem` or `AppKeyboardShortcuts`.
10. No new test and no new file. The change is view-only and introduces no decision rule;
    `./scripts/ci.sh` is the regression check and the operator confirms the control by hand.

## Dependency graph

```
T1 (the only task)
```

Both halves of the move — adding the parameters and button, removing the toolbar item — must land
together: the two new parameters are required, so the one call site changes in the same edit, and
landing only the first half would show the control twice. Nothing unblocks anything else.

## Task list

### T1: Move the secondary terminal toggle from the worktree toolbar into `WorktreeStatusBar`

**Files touched**

- `Sources/App/ContentViewHelpers.swift`
- `Sources/App/ContentView.swift`

**What it does**

*In `ContentViewHelpers.swift`, on `WorktreeStatusBar` (declared at line 80):*

Add two stored properties after `showCopiedFeedback` and before the `@EnvironmentObject`, so the
memberwise initializer takes them last:

```swift
let secondaryVisible: Bool
let onToggleSecondary: () -> Void
```

In `body`, replace the trailing

```swift
if let wt = worktree, !wt.isMain {
    prStatusView(for: wt.id)
}
```

with an `HStack(spacing: 12)` wrapping that same conditional plus the new button. The outer
`HStack(spacing: 0)`, the `Spacer()` before it, and every padding/background/overlay modifier are
unchanged:

```swift
HStack(spacing: 12) {
    if let wt = worktree, !wt.isMain {
        prStatusView(for: wt.id)
    }
    Button(action: onToggleSecondary) {
        Image(systemName: "rectangle.bottomhalf.inset.filled")
            .font(.system(size: 11))
            .foregroundStyle(secondaryVisible ? .primary : .secondary)
    }
    .buttonStyle(.plain)
    .help(secondaryVisible ? "Hide secondary terminal" : "Show secondary terminal")
    .pointerCursorOnHover()
}
```

Update the type's doc comment (currently "Status bar showing the worktree path and PR status at the
bottom of the detail pane.") so it names the toggle too. Add no other comment — CLAUDE.md treats one
here as a smell.

*In `ContentView.swift`:*

Delete the secondary-terminal `ToolbarItem` and the `ToolbarGroupBreak()` that follows it — lines
218-225 inclusive, i.e. from `ToolbarItem(placement: .primaryAction) {` wrapping
`Button(action: toggleSecondaryTerminal)` through the `ToolbarGroupBreak()` at line 225. Keep the
`ToolbarGroupBreak()` at line 217; it then separates Remove worktree from the aside toggle.

Pass the two new arguments at the sole `WorktreeStatusBar` call site (lines 932-938):

```swift
WorktreeStatusBar(
    path: path,
    worktree: currentWorktree,
    showCopiedFeedback: $showCopiedFeedback,
    secondaryVisible: secondaryVisible,
    onToggleSecondary: toggleSecondaryTerminal
)
```

Leave `toggleSecondaryTerminal` (line 604), `toggleAndFocusSecondary` (line 598), the
`secondaryVisible` computed property (line 504) and the `bottomPanel` `PanelToggle` (line 108)
exactly as they are — all four are still used.

**Acceptance criteria**

1. `WorktreeStatusBar` renders the `rectangle.bottomhalf.inset.filled` button at its trailing edge,
   to the right of the PR status on a non-primary worktree and alone on the primary worktree.
2. Clicking it runs `toggleSecondaryTerminal`, so the panel animates with the existing 0.2s
   ease-in-out and keyboard focus does not move.
3. The glyph is `.primary` while the secondary terminal is visible and `.secondary` while it is
   hidden; the tooltip reads "Hide secondary terminal" or "Show secondary terminal" to match;
   hovering shows the pointing-hand cursor.
4. The worktree toolbar contains exactly `Run │ [Open in] │ Remove │ Aside` — no secondary-terminal
   button and no doubled or orphaned separator where it was.
5. View → Show/Hide Bottom Panel still carries ⌘J, still focuses the secondary terminal on reveal,
   and still greys out on a standalone Task/Prompt/Settings window.
6. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports zero errors for the change.

**How the criteria are verified**

- Criteria 1-5 are confirmed by the operator in the running app (`./scripts/run.sh`), on a project
  with a primary worktree and at least one non-primary worktree that has a PR. Per memory, the build
  agent does not launch the app or take screenshots.
- Criterion 2 is additionally checkable from the diff: the argument passed as `onToggleSecondary:`
  is `toggleSecondaryTerminal`, not `toggleAndFocusSecondary`, and `toggleSecondaryTerminal`'s body
  is untouched, so the animation comes along unchanged.
- Criterion 5 is additionally checkable from the diff: `PanelCommands.swift`,
  `AppKeyboardShortcuts.swift` and `ContentView.swift`'s `bottomPanel` property do not appear in it.
- Criterion 6: `./scripts/ci.sh`, the regression check named in CLAUDE.md's `## Pipeline` section.
  Do not hand-write an `xcodebuild` line. SwiftLint runs inside it; `ContentViewHelpers.swift` is
  linted (only `Sources/Ghostty` and `BuildInfo.generated.swift` are excluded) and at 188 lines
  stays far under the 700-line `file_length` warning after roughly 12 added lines.
  `ContentView.swift` loses roughly 8 lines from 1028, so its file-wide
  `// swiftlint:disable file_length` is still needed and stays.

**Notes for the build agent**

- `WorktreeStatusBar` has exactly one construction site (`ContentView.swift:932-938`), so the two
  required parameters need no other caller updated. `grep -rn WorktreeStatusBar Sources Tests` to
  confirm before and after.
- `pointerCursorOnHover()` is the `View` extension at `ContentViewHelpers.swift:184-186`; its
  overlay's `hitTest` returns `nil`, so the click still reaches the button.
- Line numbers above are against base `7ae81c1`. Edit by matching the surrounding code, not by line
  number, and make the two files' edits in one pass — the project does not build between them.
- A Debug launch drops an un-gitignored `default.profraw` in the repo root. Never `git add -A`;
  report the file rather than committing it.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Removing the wrong `ToolbarGroupBreak()` leaves Remove worktree and the aside toggle in one capsule | Low | The break at line 217 is the survivor; criterion 4 checks the four capsules in the running app. On macOS 13-25 `ToolbarGroupBreak` emits nothing, so only macOS 26 shows the difference. |
| The 11pt `.secondary` glyph reads as too faint in the hidden state | Low | It matches the bar's own idiom for a state change (the path `Text` at `ContentViewHelpers.swift:90`); the operator's visual check under criterion 3 is where this is settled. |
| The control disappears while `ghosttyApp.readiness` is `.loading` or `.error`, where the toolbar showed it | None — intended | The spec records this as a fix: in those states `toggleSecondary` had no pane to reveal, so the toolbar button rendered enabled and did nothing. |

## Out of scope

Everything the spec's "Out of scope" section lists: the aside toggle, ⌘J / `PanelToggle` /
`PanelToggleMenuItem` / `AppKeyboardShortcuts`, making the status-bar click focus the secondary
terminal, any other status-bar content, splitting `ContentView.swift` below SwiftLint's 1000-line
error, and the `WorktreeGroupStore.openFileWatcher` fd leak.

## Build log

Appended by the build stage.

### T1: Move the secondary terminal toggle from the worktree toolbar into `WorktreeStatusBar`

**What landed**

| File | State |
| --- | --- |
| `Sources/App/ContentViewHelpers.swift` | `WorktreeStatusBar` gained `secondaryVisible: Bool` and `onToggleSecondary: () -> Void`, declared after `showCopiedFeedback` so the memberwise initializer takes them last. The trailing `prStatusView` conditional moved into an `HStack(spacing: 12)` that also holds the new `rectangle.bottomhalf.inset.filled` button — `.font(.system(size: 11))`, `.foregroundStyle(secondaryVisible ? .primary : .secondary)`, `.buttonStyle(.plain)`, the verbatim tooltip and `.pointerCursorOnHover()`. The doc comment now names the toggle. +19 / -3. |
| `Sources/App/ContentView.swift` | Deleted the secondary-terminal `ToolbarItem` and the `ToolbarGroupBreak()` that followed it, keeping the one before it; the toolbar is now `Run │ [Open in] │ Remove │ Aside`. Added `secondaryVisible:` and `onToggleSecondary: toggleSecondaryTerminal` at the sole `WorktreeStatusBar` call site. +3 / -9, leaving the file at 1022 lines, so its file-wide `// swiftlint:disable file_length` stays. |

`toggleSecondaryTerminal`, `toggleAndFocusSecondary`, the `secondaryVisible` computed property and the
`bottomPanel` `PanelToggle` are untouched, as are `PanelCommands.swift` and
`AppKeyboardShortcuts.swift` — none appears in the diff, which is criteria 2 and 5's static check.

**Deviations from the plan**

None to the shipped code. One intermediate step was discarded: the button's `foregroundStyle` was
first written as `secondaryVisible ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)`, then
reduced to the plan's plain ternary once the existing path `Text` three lines above
(`.foregroundStyle(showCopiedFeedback ? .primary : .secondary)`) confirmed both branches resolve to
`HierarchicalShapeStyle` and the erasure was unnecessary.

No test was added, per the spec's decision 14 and the plan's architecture decision 10: the change is
view-only, introduces no decision rule, and `WorktreeStatusBar` is a SwiftUI `View` with no output
XCTest can inspect. The visibility read and the mutation stay pinned in
`Tests/TerminalManagerTests.swift`.

**The gate**

`./scripts/ci.sh`, run after the last edit on a settled machine:

```
==> CI passed.
EXIT=0
Executed 457 tests, with 0 failures
```

`xcodegen generate` and `swiftlint lint --quiet` passed on every run — zero lint errors for the
change — and the build succeeded every time. Intermediate runs, taken while the machine was carrying
back-to-back `xcodebuild` invocations, reported 1-3 failures, all of them inside
`ShellPathResolverTests` and all the same shape:

```
✖ testATrailingPathShapedLineIsNotMistakenForThePath, XCTAssertEqual failed:
  ("degraded("/opt/homebrew/bin:/usr/bin:/bin")") is not equal to ("full("/opt/homebrew/bin:/usr/bin:/bin")")
✖ testAHealthyShellGivesFullFromOneInteractiveAttempt, XCTAssertEqual failed:
  ("["-lc"]") is not equal to ("["-lic"]") - A healthy shell must run exactly once
```

A different subset failed on each run, which is the signature of a timing flake rather than a
regression: `ShellPathResolverTests` spawns a real shell under a 0.5s `timeout`
(`Tests/ShellPathResolverTests.swift:10`), and `degraded` plus the `-lc` retry is exactly what
`ShellPathResolver` falls back to when the interactive attempt misses that deadline.

**Evidence that the flake is pre-existing, not caused by this change**

Established by reverting rather than by argument. Both modified files were copied to the scratchpad
and overwritten from `HEAD` via `git show HEAD:<path>`, leaving `git diff --stat` empty, and the
flaky class alone was run three times against that unmodified base code:

```
base run 1 EXIT=65
base run 2 EXIT=0
base run 3 EXIT=0
```

Base run 1 failed three tests with no change applied at all:

```
Failing tests:
	ShellPathResolverTests.testAProfileThatFloodsStderrStillResolves()
	ShellPathResolverTests.testExtraLinesAroundThePathDoNotBreakResolution()
	ShellPathResolverTests.testTheResolvedValueIsTheSanitizedOne()
** TEST FAILED **
```

The two files were then restored from the scratchpad copies and `git diff` re-checked against the
intended diff. Neither of the two git commands CLAUDE.md's hygiene rule forbids was used. The flake
is load-sensitive — it appeared once the machine was carrying back-to-back `xcodebuild` runs — and
is unrelated to this diff, which touches only SwiftUI view code in two files and nothing
`ShellPathResolver` reaches. It is recorded as a follow-up, not fixed here.

### Simplify

`/simplify` over the branch diff found nothing to apply — no code changed. Every candidate it
raised is already settled in the spec: `PanelToggle` instead of the two parameters (decision 7),
`.opacity` instead of the `.primary`/`.secondary` swap (decision 8), and dropping
`.pointerCursorOnHover()` (decision 10). The toolbar is left with no orphaned or doubled
`ToolbarGroupBreak()`, and `secondaryVisible` / `toggleSecondaryTerminal` remain live at their
other call sites.
