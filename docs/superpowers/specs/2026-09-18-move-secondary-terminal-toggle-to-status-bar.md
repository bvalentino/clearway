# Move the Secondary Terminal Toggle to the Status Bar

**Date:** 2026-09-18
**Base:** 7ae81c1fca4c52beaf290a2035746c975ff95c69
**PR:** #221

The show/hide control for the secondary terminal is an icon button in the worktree toolbar, sitting
between Remove worktree and the aside toggle. That row is where the worktree's *actions* live — run
a command, open in an editor, remove the worktree — while the secondary terminal is a panel of the
detail pane the status bar already sits under. This change moves the control out of the toolbar and
into the trailing edge of `WorktreeStatusBar`, after the PR status, and removes the toolbar item and
the separator it no longer needs. Nothing about what the control does changes.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Which control moves? | The `.primaryAction` `ToolbarItem` wrapping `Button(action: toggleSecondaryTerminal)` with the `rectangle.bottomhalf.inset.filled` icon (`ContentView.swift:218-224`). The aside toggle beside it (`ContentView.swift:226-232`) and every other toolbar item stay. | Operator |
| 2 | Where exactly does it land? | The trailing end of `WorktreeStatusBar`'s `HStack`, **after** `prStatusView` (`ContentViewHelpers.swift:101-104`), so the order on the right is PR status then toggle. | Operator |
| 3 | Does it still appear on the primary worktree, where no PR status renders? | Yes. The `!wt.isMain` gate applies to `prStatusView` alone; the toggle is unconditional within the bar. On the primary worktree it sits alone against the trailing edge. | Operator |
| 4 | What happens to the two `ToolbarGroupBreak()`s that bracketed it (`ContentView.swift:217`, `ContentView.swift:225`)? | Exactly one survives, so Remove worktree and the aside toggle stay in separate capsules and no double separator is left. The final toolbar is `Run │ [Open in] │ Remove │ Aside`. | Operator |
| 5 | Does the View menu's ⌘J item change? | No. `bottomPanel`'s `PanelToggle` (`ContentView.swift:108-110`) and `PanelToggleMenuItem` are untouched, and the shortcut stays declared only on the menu item, per CLAUDE.md's rule that a panel key is declared once. | Operator |
| 6 | Does the status-bar button focus the secondary terminal when it reveals it? | No. It calls `toggleSecondaryTerminal` (`ContentView.swift:604-606`), the same non-focusing action the toolbar button calls today. ⌘J's `toggleAndFocusSecondary` (`ContentView.swift:598-602`) deliberately focuses on reveal because a keyboard user has no other way to land there; a mouse user clicking the bar has. This is a move, not a behavior change — but see Follow-ups: if the operator wants the click to focus too, it is a one-identifier edit. | Spec author |
| 7 | How is the state passed into `WorktreeStatusBar`? | Two new plain parameters, `secondaryVisible: Bool` and `onToggleSecondary: () -> Void`, alongside the existing `path` / `worktree` / `showCopiedFeedback`. **Not** the existing `PanelToggle` struct: `ContentView` already builds one for the bottom panel and it carries the *focusing* action (decision 6), so a `PanelToggle`-typed parameter would read as "pass the bottom panel's toggle" and invite the wrong one. Two parameters say what they are. | Spec author |
| 8 | What does the button look like in an 11pt text bar? | `Image(systemName: "rectangle.bottomhalf.inset.filled")` at `.font(.system(size: 11))` in a `Button` with `.buttonStyle(.plain)`, tinted `.foregroundStyle(secondaryVisible ? .primary : .secondary)`. The bar's own idiom for a state change is a `.primary`/`.secondary` swap (`ContentViewHelpers.swift:90`); the toolbar's `.opacity(… ? 1 : 0.5)` was for a full-contrast toolbar glyph and stacked on the bar's already-secondary text would read as nearly invisible. | Spec author |
| 9 | Does it keep its tooltip? | Yes, verbatim: `.help(secondaryVisible ? "Hide secondary terminal" : "Show secondary terminal")`. CLAUDE.md's no-helper-text rule bans copy that restates a visible label; this is an icon-only control with no label, which is the case tooltips exist for. No text label is added — the bar is a dense 11pt strip and every other item in it is either the path or the PR. | Spec author |
| 10 | Pointing-hand cursor on hover? | Yes, `.pointerCursorOnHover()` (`ContentViewHelpers.swift:184-186`). Both clickable PR states in the same bar already use it (`ContentViewHelpers.swift:131,138`), and a plain-styled `Button` on macOS otherwise shows the arrow, leaving the control looking inert. The overlay's `hitTest` returns `nil` (`ContentViewHelpers.swift:176`), so the click still reaches the button. | Spec author |
| 11 | Spacing between the PR status and the toggle? | The two trailing items go in an `HStack(spacing: 12)` placed after the existing `Spacer()`; the outer `HStack(spacing: 0)` is unchanged. 12pt matches the bar's vertical rhythm and keeps the PR title's tail from touching the glyph. | Spec author |
| 12 | Which file does the button live in? | `Sources/App/ContentViewHelpers.swift`, inside `WorktreeStatusBar`. It is 188 lines against SwiftLint's 700-line warning, and `ContentView.swift` is at 1028 lines and only builds because of its file-wide `// swiftlint:disable file_length` (`ContentView.swift:1`). This change *removes* lines from `ContentView.swift`. No new file, so nothing new depends on `xcodegen generate` — `./scripts/ci.sh` runs it regardless. | Spec author |
| 13 | Does `AppKeyboardShortcuts` change? | No. The button declared no key equivalent in the toolbar and declares none in the bar. The `claims` table and its pins are untouched. | Spec author |
| 14 | Does this add a test? | No. The change is view-only and introduces no decision rule: the visibility read (`terminalManager.isSecondaryVisible`) and the mutation (`toggleSecondary`) are already pinned in `Tests/TerminalManagerTests.swift:11,26,74-84`, and `WorktreeStatusBar` is a SwiftUI `View` with no output XCTest can inspect. There is no pure helper worth lifting out — unlike `TerminalManager.revealSecondaryForHook`, which encodes a rule. `./scripts/ci.sh` stays the regression check and the moved control is confirmed by hand in the running app. | Spec author |

## Assumptions

Each verified by reading the codebase at base `7ae81c1`. No probe scripts or temporary files were
written, into the repo or the scratchpad.

1. **`WorktreeStatusBar` has exactly one construction site.** `ContentView.swift:932-938`, inside
   `readinessDetailView`'s `.ready` branch. The type is declared at `ContentViewHelpers.swift:80`
   and appears nowhere else in `Sources/` or `Tests/` (`grep -rn WorktreeStatusBar Sources Tests`
   returns those two lines only). So adding two required parameters has one caller to update.
2. **The status bar already renders on the primary worktree.** Its only gate is
   `if let path = selectedWorktree?.path` (`ContentView.swift:932`); `isMain` is consulted solely
   inside the bar, to gate `prStatusView` (`ContentViewHelpers.swift:102`). Decision 3 therefore
   needs no new plumbing.
3. **The new home is reached under a stricter condition than the toolbar's, and the difference is
   an improvement, not a regression.** The toolbar hangs off `detailView` and renders whenever
   `selectedWorktree != nil` (`ContentView.swift:195`), including while `ghosttyApp.readiness` is
   `.loading` or `.error`. The status bar renders only under `.ready` with a live
   `terminalManager.activePane` (`ContentView.swift:801-816`). In the loading and error states the
   toolbar button is present but `toggleSecondary` has no pane to reveal, so the control was
   rendering enabled and doing nothing visible — the same defect CLAUDE.md records for a
   `PanelToggle` whose `nil` gate misses a precondition. Moving it fixes that incidentally.
4. **`Worktree.path` is `String?` (`Worktree.swift:22`), so the status bar's `if let` is in
   principle narrower than the toolbar's `selectedWorktree != nil`.** In practice it is not:
   `Worktree.id` is `path ?? branch ?? ""` (`Worktree.swift:19`) and every worktree is parsed from
   `git worktree list --porcelain`, which emits a `worktree <path>` line for each record
   (`Worktree.swift:255`). A path-less worktree would already have no status bar today.
5. **`toggleSecondaryTerminal` is callable from the new site unchanged.** It is a private method on
   `ContentView` (`ContentView.swift:604-606`) that closes over `selectedWorktree?.id`; passing it
   as `onToggleSecondary:` captures `self` the way the toolbar `Button(action:)` already does. No
   isolation change — everything here is `@MainActor` SwiftUI view code, and no C or block callback
   is formed, so CLAUDE.md's `@convention(block)` trap does not apply.
6. **Removing one `ToolbarGroupBreak` leaves the intended capsules.** `ToolbarGroupBreak` emits a
   `ToolbarSpacer(.fixed, placement: .primaryAction)` on macOS 26 and nothing below it
   (`ToolbarGroupBreak.swift:9-13`), so on macOS 13-25 the toolbar is visually unchanged by this
   removal and on macOS 26 the four remaining items sit in four capsules.
7. **`ContentViewHelpers.swift` is linted.** Only `Sources/Ghostty` and `BuildInfo.generated.swift`
   are excluded (`.swiftlint.yml`), so the new code must pass `swiftlint lint` with zero errors,
   under a 200-column warning and 300-column error `line_length`.

## Objective

The worktree toolbar carries worktree actions; the detail pane's panel controls belong with the
detail pane. Move the secondary terminal's show/hide control to the status bar's trailing edge so
the toolbar reads as one kind of thing, without changing what the control does or where it is
available on a ready worktree.

### Success criteria

1. On a selected worktree with the terminal ready, the status bar's trailing edge shows the
   `rectangle.bottomhalf.inset.filled` button; on a non-primary worktree it sits to the **right** of
   the PR status.
2. On the primary worktree the button is present and the PR status is not.
3. Clicking it shows or hides the secondary terminal with the same 0.2s ease-in-out animation as
   before, and does not move keyboard focus.
4. The button is full-contrast while the panel is visible and dimmed while it is hidden; its tooltip
   reads "Hide secondary terminal" or "Show secondary terminal" to match.
5. Hovering it shows the pointing-hand cursor.
6. The worktree toolbar no longer contains the button, and shows exactly `Run │ [Open in] │ Remove │
   Aside` with one separator between each pair and no gap where the button was.
7. View → Show/Hide Bottom Panel and its ⌘J still work, still focus the secondary terminal on
   reveal, and still grey out on a standalone Task/Prompt/Settings window.
8. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports zero errors for the change.

## Verification

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds and runs the test suite — the regression check for
every build task and the full gate at sign-off, per CLAUDE.md's `## Pipeline` section. Do not
hand-write an `xcodebuild` line.

The change is view-only and adds no test (decision 14), so criteria 1-7 are confirmed by the
operator in the running app (`./scripts/run.sh`), on a project with both a primary worktree and at
least one non-primary worktree that has a PR. Per memory, build agents do not launch the app or take
screenshots — the operator checks by hand.

Expect the un-gitignored `default.profraw` in the repo root after any Debug launch. Run
`git status --porcelain` and report untracked files before any CI stamp or sign-off; never
`git add -A`.

## Files touched

| File | Change |
| --- | --- |
| `Sources/App/ContentViewHelpers.swift` | `WorktreeStatusBar` gains `secondaryVisible: Bool` and `onToggleSecondary: () -> Void`; its trailing `HStack(spacing: 12)` holds `prStatusView` and the new button. The doc comment gains the control. |
| `Sources/App/ContentView.swift` | Delete the secondary-terminal `ToolbarItem` and one of its two bracketing `ToolbarGroupBreak()`s (lines 217-225); pass `secondaryVisible:` and `onToggleSecondary: toggleSecondaryTerminal` at the `WorktreeStatusBar` call site (lines 932-938). |
| `docs/superpowers/specs/2026-09-18-move-secondary-terminal-toggle-to-status-bar.md` | This document. |
| `docs/superpowers/plans/2026-09-18-move-secondary-terminal-toggle-to-status-bar.md` | The plan, written by the next stage. |

No new Swift file, so nothing new depends on `xcodegen generate` picking up a source — but
`./scripts/ci.sh` runs it regardless.

## Out of scope

- The aside toggle. It stays in the toolbar; the brief names one control.
- ⌘J, `PanelToggle`, `PanelToggleMenuItem` and `AppKeyboardShortcuts` (decisions 5, 13).
- Making the status-bar click focus the secondary terminal (decision 6).
- Any other status-bar content — a branch name, a dirty indicator, a tab count.
- Splitting `ContentView.swift` below SwiftLint's 1000-line error. This change shrinks it; the split
  is owed whenever something is next *added* there.
- The known `WorktreeGroupStore.openFileWatcher` fd leak recorded in CLAUDE.md; unrelated and owed
  its own task.
