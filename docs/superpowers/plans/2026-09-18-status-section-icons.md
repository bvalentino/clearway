# Plan: Status Section Icons

**Date:** 2026-09-18
**Base:** 7ae81c1fca4c52beaf290a2035746c975ff95c69
**PR:** #222

Breaks down `docs/superpowers/specs/2026-09-18-status-section-icons.md`.

## Architecture decisions carried from the spec

1. One mapping, one home: `WorktreeStatus` gains `var symbol: String` beside the existing
   `displayName` and `color` (`Sources/App/WorktreeStatus.swift:19-37`). Every rendering site reads
   it; no site hardcodes a symbol name.
2. The property is named `symbol`, matching `Todo.Status.symbol` (`Sources/App/Todo.swift:24-29`),
   the app's only existing case-to-SF-Symbol map. Not `systemImage`.
3. The five names are exactly `circle` (todo), `circle.lefthalf.filled` (inProgress),
   `circle.inset.filled` (inReview), `checkmark.circle.fill` (done), `pause.circle` (onHold). All
   predate the macOS 13.0 deployment target. Do not substitute: `circle.dotted.circle`,
   `circle.lefthalf.striped.horizontal` and `progress.indicator` are macOS 14+/15 and render blank.
4. In review is **not** a three-quarter circle — SF Symbols ships none at this target.
   `circle.inset.filled` is the deliberate one-step-past-half mark. On hold is the **outlined**
   `pause.circle`, not `pause.circle.fill`; the solid disc is reserved for Done.
5. The icon appears in exactly three places: the by-status section header, the context-menu Status
   picker's five rows, and the row's `StatusBadge`. Tinted with `status.color` in all three.
6. The picker's "None" row and the Worktrees section header get **no** icon — both are the absence
   of a status. "None" stays a plain `Text`.
7. The badge keeps its shape: the same `rowBadge` capsule, the same lowercased `displayName`, with
   the symbol added ahead of it. `rowBadge` already applies `.caption2` to the whole subtree, so the
   symbol scales for free — no explicit `imageScale`.
8. A wrong symbol name is silent at compile time and at runtime, so the test suite pins the five
   names in case order and asserts each resolves through
   `NSImage(systemSymbolName:accessibilityDescription:)`.
9. Nothing else changes: cases, slugs, order, display names, colours, persistence, grouping, drag
   targets and the `.status`-mode badge suppression (`SidebarView.swift:504`) are untouched.
10. No file split, no new file, no new `swiftlint:disable`. The three touched sources sit well under
    SwiftLint's 700-line `file_length` warning after this change.

## Dependency graph

```
T1 (symbol + tests)
 ├── T2 (SidebarView: section header + picker rows)
 └── T3 (WorktreeRow: StatusBadge)
```

T2 and T3 both read `WorktreeStatus.symbol`, so T1 lands first. T2 and T3 touch different files and
are independent of each other.

## Task list

### T1: Give `WorktreeStatus` a `symbol` and pin it

**Files**

- `Sources/App/WorktreeStatus.swift`
- `Tests/WorktreeStatusTests.swift`

**What it does**

Add `var symbol: String` to `WorktreeStatus`, directly after `color` (`WorktreeStatus.swift:29-37`),
in the same `switch self` shape as its neighbours:

| Case | Symbol |
| --- | --- |
| `.todo` | `circle` |
| `.inProgress` | `circle.lefthalf.filled` |
| `.inReview` | `circle.inset.filled` |
| `.done` | `checkmark.circle.fill` |
| `.onHold` | `pause.circle` |

No doc comment restating the table. Leave `displayName`, `color` and the type's existing comments
alone.

In `Tests/WorktreeStatusTests.swift`, add `import AppKit` (the file already imports `SwiftUI`,
`XCTest` and `@testable import Clearway`) and two methods in the `// MARK: - WorktreeStatus`
section, beside `testColorsAreSystemColors`:

- one asserting `WorktreeStatus.allCases.map(\.symbol)` equals the five names above, in case order;
- one asserting each `symbol` resolves — `XCTAssertNotNil(NSImage(systemSymbolName: status.symbol,
  accessibilityDescription: nil), status.symbol)` over `allCases`, so a failure names the symbol.

Do not touch the existing assertions.

**Acceptance criteria**

- `WorktreeStatus.symbol` returns the five names above and nothing in the enum otherwise changes.
- Both new tests exist and pass; every pre-existing test in the file still passes unmodified.
- A deliberately misspelled name would fail the resolution test (the point of decision 12).

**Verification**

`./scripts/ci.sh` — green, including `WorktreeStatusTests`. `swiftlint lint --quiet` reports no new
warnings.

### T2: Show the symbol in the section header and the Status picker

**Files**

- `Sources/App/SidebarView.swift`

**What it does**

Two edits, both inside `SidebarView.swift`.

1. `statusSection`'s header (`SidebarView.swift:379`): replace `Text(status.displayName)` with a
   `Label(status.displayName, systemImage: status.symbol)` and tint the symbol with `status.color`
   (`.foregroundStyle` on the icon, not on the title — the title keeps the header's default style).
   Every modifier after it — `.frame(maxWidth: .infinity, alignment: .leading)`, the conditional
   `.background`, and the `.dropDestination`/`isTargeted` pair (`SidebarView.swift:380-385`) —
   stays exactly as it is and keeps applying to the header view, so the full-width drop target and
   its targeting highlight are unchanged.
2. The Status picker (`SidebarView.swift:411-423`): the `ForEach(WorktreeStatus.allCases)` row
   becomes a `Label(status.displayName, systemImage: status.symbol)` carrying the same
   `status.color` tint, keeping its existing `.tag(Optional(status))`. `Text("None")
   .tag(WorktreeStatus?.none)` (`SidebarView.swift:416`) is left untouched — no icon. The `Picker`,
   its `Binding`, `.pickerStyle(.inline)` and `.labelsHidden()` are unchanged.

The `worktreesSection` header (`SidebarView.swift:226`, drop target at `:530`) gets no icon.

AppKit renders `NSMenuItem` images as templates, so the picker rows may come out monochrome. That is
accepted (spec decision 9) — apply the tint the same way in both places and do not add a workaround.

**Acceptance criteria**

- In the by-status view each of the five section headers shows its tinted symbol before the title;
  the Worktrees header shows none.
- Dragging a worktree onto a status header still sets that status and still highlights the full-width
  header while targeted.
- The context menu's Status submenu shows the five entries each with its symbol, "None" without one,
  the checkmark still on the current value, and choosing an entry still sets the status.
- The main worktree's row still has no Status submenu.

**Verification**

`./scripts/ci.sh` — green. Then `./scripts/run.sh` and confirm by hand in the running app, in the
by-status view with at least one worktree in each status: the five headers, a drag onto a header,
and the Status submenu on a non-main row (all five entries, "None", the checkmark, and that choosing
one applies). Expect the un-gitignored `default.profraw` in the repo root after the launch; never
`git add -A`.

### T3: Put the symbol inside the status badge

**Files**

- `Sources/App/WorktreeRow.swift`

**What it does**

In `StatusBadge` (`WorktreeRow.swift:93-101`), replace the single
`Text(status.displayName.lowercased())` with an `HStack(spacing: 3)` of
`Image(systemName: status.symbol)` and that same `Text`. The existing
`.foregroundStyle(status.color)` and `.rowBadge(status.color.opacity(0.15))` stay on the `HStack`,
so both parts are tinted and the capsule is unchanged.

Add no `imageScale` and no explicit font: `rowBadge` (`WorktreeRow.swift:103-110`) applies
`.font(.caption2)` to the whole subtree before padding, background and `fixedSize()`, so the symbol
scales with the label already. `PrimaryBadge`, `ShortcutBadge`, `rowBadge` and the rest of
`WorktreeRow` are untouched.

**Acceptance criteria**

- In the by-group and none views a row with a status shows the symbol and the lowercased name
  together inside the existing capsule, both in the status colour.
- The pill is still sized to its content: no truncation, no wrapping, and the worktree name still
  truncates before the badge does.
- In the by-status view no row shows a status badge (unchanged — `SidebarView.swift:504`).
- The main worktree's row still shows the primary badge and no status badge.

**Verification**

`./scripts/ci.sh` — green. Then `./scripts/run.sh` and check by hand in all three Group by modes
with at least one worktree in each status, including a long worktree name so the truncation order is
visible, and the main worktree's row.

## Build log

### T1: Give `WorktreeStatus` a `symbol` and pin it

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeStatus.swift` | `var symbol: String` added after `color`, same `switch self` shape. The five names are exactly those of plan decision 3. `displayName`, `color`, the cases and the type's comments are untouched. |
| `Tests/WorktreeStatusTests.swift` | `import AppKit` added; `testSymbols` pins the five names in case order and `testSymbolsResolve` asserts each resolves through `NSImage(systemSymbolName:accessibilityDescription:)`, both beside `testColorsAreSystemColors`. The nine pre-existing assertions are unmodified. |

**Evidence**

The tests were written first, against an enum with no `symbol`, and watched fail to compile:

```
❌ Tests/WorktreeStatusTests.swift:40:52: value of type 'WorktreeStatus' has no member 'symbol'
❌ Tests/WorktreeStatusTests.swift:47:62: value of type 'WorktreeStatus' has no member 'symbol'
```

A compile error proves the property is absent, not that the pins bite. So `symbol` was then
implemented with `.inReview` deliberately misspelled `circle.insert.filled` and the gate run again.
Both new tests failed, which is acceptance criterion 3:

```
✖ testSymbols, XCTAssertEqual failed:
  ("[..., "circle.insert.filled", ...]") is not equal to ("[..., "circle.inset.filled", ...]")
✖ testSymbolsResolve, XCTAssertNotNil failed - circle.insert.filled
```

Correcting the spelling turns both green. `xcodebuild ... -only-testing:ClearwayTests/WorktreeStatusTests test`
exits 0.

**Deviations from the plan**

None.

**The gate**

`./scripts/ci.sh`, run three times after the final edit, exits 65 each time. `xcodegen generate` and
`swiftlint lint --quiet` pass; the build passes; every suite passes **except** `ShellPathResolverTests`,
which fails a different method on each run:

| Run | Failing method |
| --- | --- |
| 1 | `testAHealthyShellGivesFullFromOneInteractiveAttempt` |
| 2 | `testAProfileThatFloodsStderrStillResolves` |
| 3 | `testAHealthyShellGivesFullFromOneInteractiveAttempt` |

Every failure has the same shape — `.degraded(...)` where `.full(...)` was expected, i.e. the
interactive attempt exceeded the suite's `timeout` of 0.5 s and the resolver fell through to the
login attempt. One earlier run recorded an attempt taking 247 s against that 2.5 s bound. The suite
spawns real shell processes, so it is load-dependent; the machine was at load average 8.8 while
another repository's CI held the cores.

Proof it is a flake and not this change: the same two suites were run in isolation three times, same
code, same command — run 1 passed, runs 2 and 3 printed `** TEST FAILED **`. `WorktreeStatus` gains
one computed property and cannot reach `ShellPathResolver`.

`git status --porcelain` before the commit listed only the spec, the plan and the two changed sources.
No `default.profraw`: the app was not launched, since T1 changes nothing visible.

### T2: Show the symbol in the section header and the Status picker

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SidebarView.swift` | `statusSection`'s header is now a `Label` whose title is `Text(status.displayName)` and whose icon is `Image(systemName: status.symbol).foregroundStyle(status.color)`. The `.frame(maxWidth: .infinity, alignment: .leading)`, the conditional `.background` and the `.dropDestination`/`isTargeted` pair follow it unchanged, so the full-width drop target and its targeting highlight are untouched. The Status picker's `ForEach(WorktreeStatus.allCases)` row is the same `Label` shape carrying the same `.tag(Optional(status))`; `Text("None").tag(WorktreeStatus?.none)`, the `Picker`, its `Binding`, `.pickerStyle(.inline)` and `.labelsHidden()` are unchanged. `worktreesSection`'s header gets no icon. |

The two-closure `Label { } icon: { }` form is used in both places rather than
`Label(_:systemImage:)` plus a `.foregroundStyle`, because the plan requires the tint on the icon
only — a modifier on the whole `Label` would recolour the title too, and the header's title must
keep the section header's default style.

**Evidence**

T2 adds no test. The plan assigns T2 none, and the spec's `### Test coverage this requires` puts its
acceptance criteria (1, 2 and the drop-target and main-worktree pins) under "confirmed by hand in the
running app": all four are SwiftUI view state reached only through a rendered `SidebarView`, which
needs a live `WorktreeGroupManager` and `TerminalManager`. There is no failure to watch, so none is
quoted here rather than a test written after the fact and never run against the bug. The symbol
vocabulary these two sites read is already pinned by T1's `testSymbols` and `testSymbolsResolve`,
which is what makes a blank icon slot a test failure rather than a visual one.

**Deviations from the plan**

None.

**The gate**

`./scripts/ci.sh` after the last edit: **`Test Succeeded` / `==> CI passed.`, exit 0, 459 tests, 0
failures.** `swiftlint lint --quiet` was also run directly and exits 0 with no output.

It took two runs, and the pair is what finally settles the `ShellPathResolverTests` flake rather
than merely asserting it. The first run — the two `Label` edits, before a whitespace-only reindent
of the header's modifier chain — exited 65 on three failures, all in that one suite:

```
✖ testAHealthyShellGivesFullFromOneInteractiveAttempt, XCTAssertEqual failed: ("degraded("/opt/homebrew/bin:/usr/bin:/bin")") is not equal to ("full("/opt/homebrew/bin:/usr/bin:/bin")")
✖ testAHealthyShellGivesFullFromOneInteractiveAttempt, XCTAssertEqual failed: ("["-lc"]") is not equal to ("["-lic"]") - A healthy shell must run exactly once
✖ testExtraLinesAroundThePathDoNotBreakResolution, XCTAssertEqual failed: ("degraded("/opt/homebrew/bin:/usr/bin:/bin")") is not equal to ("full("/opt/homebrew/bin:/usr/bin:/bin")")
```

The second run was required anyway, because the reindent edited the file after the first gate and a
suite is not green unless the command ran after the *last* edit. It passed with the same test code
and the same two `Label` edits in place, and the elapsed times are the mechanism: 768 s of test time
on the red run against **58.8 s** on the green one, a 13× spread with no code change between them
that `ShellPathResolver` can see. `ShellPathResolverTests` spawns real shell processes and asserts
against a 0.5 s timeout, so under load the interactive attempt overruns it and the resolver falls
through to the login attempt — `.degraded` where `.full` was expected. The failing methods also
differ from T1's runs, which is the flake's signature; a real regression would fail the same method
every time. This change edits two SwiftUI view builders and cannot reach `ShellPathResolver`.

`git status --porcelain` before the commit listed only `Sources/App/SidebarView.swift` and this plan.
No `default.profraw`: the hand-verification pass is the operator's, so the app was not launched here.

### T3: Put the symbol inside the status badge

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | `StatusBadge`'s body is now an `HStack(spacing: 3)` of `Image(systemName: status.symbol)` and the same `Text(status.displayName.lowercased())`. `.foregroundStyle(status.color)` and `.rowBadge(status.color.opacity(0.15))` moved onto the `HStack`, so both parts are tinted inside the unchanged capsule. No `imageScale` and no explicit font: `rowBadge` applies `.font(.caption2)` to the whole subtree before padding, background and `fixedSize()`. `PrimaryBadge`, `ShortcutBadge`, `rowBadge` and the rest of `WorktreeRow` are untouched. |

**Evidence**

T3 adds no test, for the same reason T2 did not. The plan assigns it none, and the spec's
`### Test coverage this requires` puts acceptance criteria 3, 4 and 5 under "confirmed by hand in
the running app": all three are SwiftUI view state — the capsule's layout, `fixedSize()`'s
no-truncation guarantee, the `.status`-mode badge suppression at `SidebarView.swift:504` and the
main worktree's `PrimaryBadge` branch — reachable only through a rendered `WorktreeRow` inside a
`SidebarView` with a live `WorktreeGroupManager` and `TerminalManager`. `StatusBadge` is `private`,
so it is not reachable from the test target at all. There is no failure to watch, so none is quoted
here rather than a test written after the fact and never run against the bug. The symbol vocabulary
this site reads is pinned by T1's `testSymbols` and `testSymbolsResolve`, which is what makes a
blank icon slot in the badge a test failure rather than a visual one.

**Deviations from the plan**

None.

**The gate**

`./scripts/ci.sh` after the last edit: `Test Succeeded` / `==> CI passed.`, exit 0, **459 tests, 0
failures**. `xcodegen generate` and `swiftlint lint --quiet` pass (the script runs under
`set -euo pipefail`, so `==> CI passed.` prints only when every step did).

One run was enough. `ShellPathResolverTests` passed this time, and the elapsed time is the
confirmation of T2's flake diagnosis rather than a new data point: 59.1 s of test time, within a
second of T2's green run at 58.8 s and 13× below the 768 s of its red one. The machine was not
under the competing load that produced the earlier `.degraded`-where-`.full` failures.

`git status --porcelain` before the commit listed only `Sources/App/WorktreeRow.swift` and this
plan. No `default.profraw`: the hand-verification pass is the operator's, so the app was not
launched here.

## Changelog

### 2026-09-18 — Operator change from the hands-on check: header colour and palette

Requested by the operator after trying T1–T3 by hand. Recorded here so no later stage reverts it as
unintentional. Spec decisions 14 and 15 carry the same two rulings.

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeStatus.swift` | `color` repainted: todo gray (unchanged), inProgress `.yellow`, inReview `.green`, done `.indigo`, onHold `.gray`. |
| `Sources/App/SidebarView.swift` | `statusSection`'s header title gets `.foregroundStyle(.primary)`, matching `destinationRow`'s Tasks / Prompts / Commands labels. The icon keeps `status.color`. |
| `Tests/WorktreeStatusTests.swift` | `testColorsAreSystemColors` repinned to `[.gray, .yellow, .green, .indigo, .gray]`. |

Two call sites consume `color` and both follow without change: the section header icon and
`StatusBadge` (`WorktreeRow.swift:101-102`, tint plus a 0.15-opacity capsule). Todo and On hold now
render identically in the badge; they are told apart by the symbol and the name, which is the
distinction the badge already leans on elsewhere.

`destinationRow` sets no font or weight of its own — it is a plain `Label` in a `List` row — so
colour is the whole of the difference, and `.foregroundStyle(.primary)` on the title is the whole of
the change. Applying it to the `Label` rather than the `Text` would have overridden the icon's tint.

**Deviations from the plan**

This is not a plan task; it postdates T1–T3. No deviation from T1–T3's shipped behaviour beyond the
two rulings above.

**The gate**

`./scripts/ci.sh` after the last edit: `Test Succeeded` / `==> CI passed.`, exit 0, **459 tests, 0
failures** in 58.1 s. `xcodegen generate` and `swiftlint lint --quiet` pass. One run was enough;
`ShellPathResolverTests` was green, matching T1–T3's unloaded-machine timings.

`git status --porcelain` before the commit listed only the three sources above, the spec and this
plan. No `default.profraw` — the app was not launched here.

### 2026-09-18 — Operator change from the hands-on check: put the status headers on the row grid

Requested by the operator after trying the repainted headers by hand: in Group by → Status the
section headers' icon and title rendered a few points left of the worktree rows' beneath them and of
the Tasks / Prompts / Commands rows above. Recorded here so no later stage reverts it as
unintentional. Spec decision 16 carries the ruling.

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | New `SidebarRowMetrics` — `iconWidth` 18 and `headerLeadingInset` 4 — sits above `WorktreeRow`, beside the already-shared `ShortcutBadge`. `WorktreeRow`'s `icon:` closure wraps its two branches (the `⌘N` badge and the worktree symbol) in a `Group` carrying `.frame(width: SidebarRowMetrics.iconWidth)`. `StatusBadge`, `PrimaryBadge`, `rowBadge` and the row's title column are untouched. |
| `Sources/App/SidebarView.swift` | `destinationRow`'s `icon:` closure gets the same `Group` + `.frame(width:)` treatment, so Tasks / Prompts / Commands and the worktree rows share one icon column whichever of the four glyphs or the `⌃N` badge is showing. `statusSection`'s header icon takes the same frame, and the `Label` takes `.padding(.leading, SidebarRowMetrics.headerLeadingInset)` **before** its existing `.frame(maxWidth: .infinity, alignment: .leading)`. |

Two causes, two numbers. The leading inset: a `Section` header is inset less than a list row, which
is what shifted the whole header — icon and title together — to the left. The icon column: a header
`Label` sizes its icon slot to the glyph, and the five status circles are narrower than
`square.on.square.intersection.dashed`, so even once the header started at the row's leading edge
its title would still have sat left of the rows' titles. One shared constant per cause, read by all
three sites, is what makes them agree by construction rather than by three matching literals.

The padding precedes the `.frame(maxWidth: .infinity)`, so the frame still expands the padded label
to the full width and the conditional `.background` and the `.dropDestination`/`isTargeted` pair
below it are unchanged: the drop target and its targeting highlight still cover the whole header.

No extra top spacing was added. The operator asked for it "only if needed"; the section's own header
spacing is untouched by a horizontal change, so the header reads as the divider it already did.

**Deviations from the plan**

This is not a plan task; it postdates T1–T3 and the palette change. Nothing T1–T3 shipped changes
behaviour here — the picker rows and `StatusBadge` were deliberately left alone.

**Evidence**

No test. Both numbers are SwiftUI view geometry inside a rendered `SidebarView`, reachable only with
a live `WorktreeGroupManager` and `TerminalManager`; there is no failure to watch, so none is quoted
rather than a test written after the fact. `18` and `4` are the operator's hand check to confirm:
they are named constants in one place precisely so a nudge is a one-line edit, not a hunt through
three call sites.

**The gate**

`./scripts/ci.sh` after the last source edit: `Test Succeeded` / `==> CI passed.`, **459 tests, 0
failures** in 59.9 s, then a second confirming run with the exit status captured — `EXIT:0`, 459
tests, 0 failures in 59.0 s. `xcodegen generate` and `swiftlint lint --quiet` pass in both.
`ShellPathResolverTests` was green both times, matching the unloaded-machine timings of T2's and
T3's green runs.

`git status --porcelain` before the commit listed only the two sources above, the spec and this
plan. No `default.profraw` — the app was not launched here; the operator owns the visual check.

### 2026-09-18 — Operator change from the hands-on check: indent the rows inside a status section

Requested by the operator after trying the row-grid alignment by hand: "It looks better but I think
the worktrees within a status should be a tiny bit indented." After 45416d1 the header's icon and
title and the rows beneath it share one leading edge, so the rows read as the header's siblings.
Recorded here so no later stage reverts it as unintentional. Spec decision 17 carries the ruling.

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | `SidebarRowMetrics` gains `statusRowIndent` (8), beside `iconWidth` and `headerLeadingInset`; the type's comment names what it is for. Nothing else in the file changes. |
| `Sources/App/SidebarView.swift` | `worktreeRowView` gains `leadingIndent: CGFloat = 0`, applied as `.padding(.leading, leadingIndent)` on the `WorktreeRow` **before** `.tag`, so every interaction modifier below it — `.tag`, `.opacity`, `.contextMenu`, `.draggableIf`, `.moveDisabled` — wraps the padded content. `statusSection` is the one call site that passes it, as `SidebarRowMetrics.statusRowIndent`. |

The indent is on the row's content, not its `listRowInsets`: the list row keeps its own width, so the
selection highlight, the hover highlight and the row's hit area still span the full sidebar and only
the label moves. Changing the insets would have pulled the highlight in with it.

`worktreeRowView` is shared by all three groupings, so the parameter is what scopes the indent:
`worktreesSection` (the ungrouped rows in every mode, including the status mode's "no status" rows)
and `groupSection` call it without one and default to 0, leaving the group and none groupings
pixel-identical. `WorktreeRow` itself is untouched, so the ⌘N shortcut badge, the status badge and
the drag chip are unchanged.

**Deviations from the plan**

This is not a plan task; it postdates T1–T3, the palette change and the row-grid alignment.

**Evidence**

No test. The indent is SwiftUI view geometry inside a rendered `SidebarView`, reachable only with a
live `WorktreeGroupManager` and `TerminalManager`; there is no failure to watch, so none is quoted
rather than a test written after the fact. `8` is the operator's hand check to confirm, and it is a
named constant in one place so a nudge is a one-line edit.

**The gate**

`./scripts/ci.sh` after the last source edit: `Test Succeeded` / `==> CI passed.`, `EXIT:0`, **459
tests, 0 failures** in 58.5 s, then a second confirming run after this log was written — `EXIT:0`,
459 tests, 0 failures. `xcodegen generate` and `swiftlint lint --quiet` pass in both.
`ShellPathResolverTests` was green both times, matching the unloaded-machine timings of the earlier
green runs.

`git status --porcelain` before the commit listed only the two sources above, the spec and this plan.
No `default.profraw` — the app was not launched here; the operator owns the visual check.

### 2026-09-18 — Operator change from the hands-on check: indent the rows to the header's title column

Requested by the operator after trying dfe41ae's 8-point indent by hand: "The indent is not
sufficient. The icon of the worktree should start where the text of the status starts." Recorded
here so no later stage reverts it as unintentional. Spec decision 17 carries the amended ruling.

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | `SidebarRowMetrics` gains `labelIconSpacing` (6) and `statusRowIndent` becomes `iconWidth + labelIconSpacing` (24) instead of the literal 8. The type's comment names what the new constant is for. Nothing else in the file changes. |
| `Sources/App/SidebarView.swift` | `statusSection`'s header is an explicit `HStack(spacing: SidebarRowMetrics.labelIconSpacing)` of the same tinted `Image(systemName: status.symbol)` — still `.frame(width: SidebarRowMetrics.iconWidth)` — and the same `Text(status.displayName).foregroundStyle(.primary)`, in place of the two-closure `Label`. Every modifier after it is untouched: `.padding(.leading, SidebarRowMetrics.headerLeadingInset)`, then `.frame(maxWidth: .infinity, alignment: .leading)`, the conditional `.background` and the `.dropDestination`/`isTargeted` pair. |

The indent is derived, not chosen. The header's title starts at
`headerLeadingInset + iconWidth + labelIconSpacing`; the row already carries, as list inset, the
`headerLeadingInset` the header has to add back (that is what decision 16 established), so the
indent that lands a row's icon on the header's title is `iconWidth + labelIconSpacing` and nothing
else. Writing it as that sum is what stops the two drifting.

`Label`'s icon-to-title gap is not a public constant and cannot be set, so leaving the header a
`Label` would have made `labelIconSpacing` a guess about SwiftUI's default — the drift the operator's
brief asked to rule out. The `HStack` owns the gap instead, which makes the sum true by construction
whatever value the constant takes. The icon keeps its `.frame(width: iconWidth)` rather than being
left-aligned in a 24-wide slot, so the header's glyph stays centred on the same axis as the
destination rows' and the worktree rows' glyphs above and below it.

`WorktreeRow` stays a `Label`: its own icon-to-title spacing is irrelevant to this alignment (only
where its icon *starts* matters), and its two-line variant relies on `Label`'s vertical alignment of
the icon against a multi-line title. `worktreeRowView`'s `leadingIndent` parameter, its default of 0
and the content-side `.padding(.leading,)` before `.tag` are exactly as dfe41ae left them, so the
highlight still spans the full sidebar and the group and none groupings are pixel-identical.

**Deviations from the plan**

This is not a plan task; it postdates T1–T3, the palette change, the row-grid alignment and
dfe41ae's first indent.

**Evidence**

No test. The indent is SwiftUI view geometry inside a rendered `SidebarView`, reachable only with a
live `WorktreeGroupManager` and `TerminalManager`; there is no failure to watch, so none is quoted
rather than a test written after the fact. The composition is the guarantee instead: both sides of
the alignment now read the same two constants.

**The gate**

`./scripts/ci.sh` after the last edit: `Test Succeeded` / `==> CI passed.`, **`EXIT:0`, 459 tests, 0
failures** in 58.4 s. `xcodegen generate` and `swiftlint lint --quiet` pass (the script runs under
`set -euo pipefail`, so `==> CI passed.` prints only when every step did).

It took three runs, and the two red ones are worth recording because they do not carry the flake's
usual signature. Both runs after the last *source* edit exited 65 with 459 tests and 3 failures, all
three in `ShellPathResolverTests`, all of the documented `.degraded`-where-`.full` shape, and — unlike
T1's and T2's red runs — the **same** three methods both times:

```
✖ testAProfileThatFloodsStderrStillResolves, XCTAssertEqual failed: ("degraded("/opt/homebrew/bin:/usr/bin:/bin")") is not equal to ("full("/opt/homebrew/bin:/usr/bin:/bin")")
✖ testExtraLinesAroundThePathDoNotBreakResolution, XCTAssertEqual failed: ("degraded("/opt/homebrew/bin:/usr/bin:/bin")") is not equal to ("full("/opt/homebrew/bin:/usr/bin:/bin")")
✖ testTheResolvedValueIsTheSanitizedOne, XCTAssertEqual failed: ("degraded("/usr/bin:/bin")") is not equal to ("full("/usr/bin:/bin")")
```

Every other suite was green in both. A repeated method set is what a real regression looks like, so
it was settled rather than asserted: `-only-testing:ClearwayTests/ShellPathResolverTests` was then
run three times back to back against this same code and exited **0, 65, 0**, and the next full
`./scripts/ci.sh` — same code, only this log appended since — was green. A regression does not pass
three times out of four with no edit between runs. The suite spawns real shell processes and asserts
against a 0.5 s timeout, so under load the interactive attempt overruns and the resolver falls
through to the login attempt; the machine was at load average 3.4 with another repository's build
holding cores, and the green run came once it dropped. This change edits one metrics enum and one
SwiftUI view builder and cannot reach `ShellPathResolver`.

`git status --porcelain` before the commit listed only the two sources above, the spec and this plan.
No `default.profraw` — the app was not launched here; the operator owns the visual check.

### 2026-09-18 — Operator change from the hands-on check: align the row icons on the header's title

Requested by the operator after trying d551971 by hand: "The icons of indented worktrees are not
starting at the same level as the text of the status." The rule they gave: a row's icon column — the
icon, or the `⌘N` badge that replaces it — must start at the same x as the header's title text.
Recorded here so no later stage reverts it as unintentional. Spec decision 17 carries the amended
ruling.

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | New `View.sidebarIconSlot()` beside `SidebarRowMetrics`: `frame(width: SidebarRowMetrics.iconWidth, alignment: .leading)`, the one home for the icon column's geometry. `WorktreeRow`'s icon `Group` calls it in place of its bare `.frame(width:)`. The four constants are unchanged — `statusRowIndent` is still `iconWidth + labelIconSpacing`. |
| `Sources/App/SidebarView.swift` | `destinationRow`'s icon `Group` and `statusSection`'s header `Image` call `sidebarIconSlot()` in place of the same bare `.frame(width:)`. Nothing else changes: the indent, the header's `HStack` spacing, its `headerLeadingInset` padding, the drop targets and every row modifier are as d551971 left them. |

**Which term was wrong**

Neither the indent nor the insets: the measurement in the previous entry was of frames, and the
operator's eye is on glyphs. Column positions read off the operator's screenshot (2x, leftmost ink
per band, decoded rather than eyeballed):

| Element | Ink x (px, 2x) |
| --- | --- |
| Main row `⌘1` badge | 38 |
| Header icon glyph | 35 |
| Header title text | 77 |
| Indented row `⌘2` / `⌘3` badge | 86 |
| Indented row worktree glyph | 85 |

The indent is exact: 86 − 38 = 48 px = 24 pt = `statusRowIndent`. And the frames do align — the
`⌘N` badge measures 20 px of ink in a 36 px slot, so centring puts its frame at 86 − 8 = 78, against
the header title's 77. What the operator sees is the 8 px of centring slack, not a double-counted
`headerLeadingInset`: the header's own icon is centred too (23 px of ink at 35 ⇒ frame at ~29, one
pixel off the main row's 30, which is decision 16 working as intended), but its *title* has no slot
and starts at its own leading edge. So the fix is at the slot, not at the sum: with the glyph flush
to the slot's leading edge the indented icon lands at ~78 against the title's 77, and every other
icon in the sidebar moves left by its own half-slack (2–4 px) while staying on the one axis it
shared before — the header's icon and the main row's icon end up at ~29 and 30 instead of 35 and 38.

Leading alignment rather than a smaller indent is what makes the rule hold for a glyph the app does
not have yet: a wider or narrower symbol changes its slack, and any indent tuned to today's badge
would drift the moment one arrives. It also keeps `statusRowIndent` the true header-title offset,
which a literal-shaving 20 would not have been.

**Deviations from the plan**

This is not a plan task; it postdates T1–T3 and the four earlier operator changes. It reverses one
sentence of the previous entry, which kept the header's glyph centred "so the header's glyph stays
centred on the same axis as the destination rows' and the worktree rows' glyphs" — they do stay on
one axis, because all three sites take the same slot.

**Evidence**

No test. This is SwiftUI view geometry inside a rendered `SidebarView`, reachable only with a live
`WorktreeGroupManager` and `TerminalManager`, so there is no failure to watch and none is quoted
rather than a test written after the fact. The proof is the screenshot measurement above plus the
composition: one modifier owns the slot, and all three call sites take it.

**The gate**

`./scripts/ci.sh` after the last source edit, first run: `Test Succeeded` / `==> CI passed.`,
**`EXIT:0`, 459 tests, 0 failures** in 60.3 s. `xcodegen generate` and `swiftlint lint --quiet` pass
(the script runs under `set -euo pipefail`). `ShellPathResolverTests` was green — no re-run needed.

`git status --porcelain` before the commit listed only the two sources above, the spec and this plan.
No `default.profraw` — the app was not launched here; the operator owns the visual check.

### 2026-09-18 — Operator change from the hands-on check: trim the indent by the title's leading bearing

Requested by the operator after trying 4fdcbf2 by hand: "it should be 3 px more to the left",
pointing at the indented worktree rows under a status header in Group by → Status. Read as 3 points.
Recorded here so no later stage reverts it as unintentional. Spec decision 17 carries the amended
ruling.

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | `SidebarRowMetrics` gains `titleLeadingBearing` (3) and `statusRowIndent` becomes `iconWidth + labelIconSpacing - titleLeadingBearing` (21) instead of 24. The type's comment names what the new constant compensates for. Nothing else in the file changes — `sidebarIconSlot()`, `iconWidth`, `labelIconSpacing` and `headerLeadingInset` are exactly as 4fdcbf2 left them. |

**What the 3 points are**

The remaining term is the header title's leading side bearing. After 4fdcbf2 both sides of the
alignment are flush with their own frames' leading edges — the row's icon by `sidebarIconSlot()`, the
header's title because a `Text` has no slot — but a `Text`'s frame is not where its ink starts: the
first glyph of "In progress", "Done" and the rest carries a left side bearing inside the frame, so a
row's icon sitting exactly at the title's frame reads a few points right of the letter the operator
is aligning to. Subtracting it is what puts the icon on the letter.

Keeping it a named term rather than writing 21 keeps the indent derived: the three geometric terms
still say where the header's title frame is, and the fourth says how far inside that frame its ink
begins. Only the new constant is a measured number, and it is the one the operator supplied.

Nothing else moves. `statusRowIndent` has one reader — `statusSection`'s `leadingIndent:` argument —
so the header, the destination rows, the top-level worktree rows, the group grouping and the none
grouping are untouched by construction.

**Deviations from the plan**

This is not a plan task; it postdates T1–T3 and the five earlier operator changes.

**Evidence**

No test. This is SwiftUI view geometry inside a rendered `SidebarView`, reachable only with a live
`WorktreeGroupManager` and `TerminalManager`, so there is no failure to watch and none is quoted
rather than a test written after the fact. The 3 is the operator's own measurement from the running
app, and it is a named constant in one place so a further nudge stays a one-line edit.

**The gate**

`./scripts/ci.sh` after the last source edit: `Test Succeeded` / `==> CI passed.`,
**459 tests, 0 failures** in 58.7 s, then a second confirming run after this log was written with
the exit status captured — `EXIT:0`, 459 tests, 0 failures. `xcodegen generate` and
`swiftlint lint --quiet` pass (the script runs under `set -euo pipefail`, so `==> CI passed.` prints
only when every step did). `ShellPathResolverTests` was green both times — no re-run for the flake
was needed.

`git status --porcelain` before the commit listed only the source above, the spec and this plan.
No `default.profraw` — the app was not launched here; the operator owns the visual check.

### 2026-09-18 — Simplify pass

`/simplify` over the branch. Quality only; no rendered outcome changes and the four
`SidebarRowMetrics` values and `statusRowIndent`'s composition are untouched.

- `Sources/App/SidebarIcon.swift` (new) now owns the icon column: `SidebarRowMetrics`, a
  `SidebarIcon` view, and `ShortcutBadge` (private, its only caller is now `SidebarIcon`). The
  metrics and the slot modifier previously sat in `WorktreeRow.swift`, which `SidebarView` reached
  into for three constants and a module-wide `View` extension it had no other reason to open.
- The `Group { if badge … else Image }.sidebarIconSlot()` block was written verbatim in
  `WorktreeRow`'s and `destinationRow`'s `icon:` closures. Both now call `SidebarIcon`, as does the
  status header, so the slot's geometry is a type rather than a convention each new icon site has
  to remember. `sidebarIconSlot()` is gone, folded into `SidebarIcon.body`.
- The metrics doc comment became one line per constant, dropping the prose that restated
  `statusRowIndent`'s expression and narrated the rejected centring experiment — that history is in
  the two changelog entries above.

Skipped: hoisting `worktreeRowView`'s `leadingIndent` to `statusSection`'s call site (it would pull
the indent gutter out of the row's `.contextMenu`/`.draggableIf` regions — an interaction change);
a `WorktreeStatus.icon` view (the three sites need the slot, `Label`'s own column, and no tint at
all respectively); dropping `testSymbols` in favour of `testSymbolsResolve` (T1 pins it as an
acceptance criterion).

### 2026-09-18 — Review finding: rename `labelIconSpacing` to `headerIconSpacing`

Not a plan task. A review of 7f5f80a found the constant's name and doc comment invoked `Label`,
while the value is the status header's own `HStack` spacing — no `Label` is involved at any reader.

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SidebarIcon.swift` | `SidebarRowMetrics.labelIconSpacing` renamed to `headerIconSpacing`; its doc comment now says what it is (the status header's icon-to-title gap, and a term of `statusRowIndent`) instead of explaining why it is not taken from `Label`. `statusRowIndent`'s expression follows the rename. |
| `Sources/App/SidebarView.swift` | `statusSection`'s header `HStack(spacing:)` reads the new name. |
| `docs/superpowers/specs/2026-09-18-status-section-icons.md` | Decision 17's four mentions renamed. |

Values are unchanged (6, and `statusRowIndent` still 18 + 6 − 3 = 21), so nothing renders
differently. The Build log entries above keep the old name: they record what landed at the time.

**The gate**

`./scripts/ci.sh` — see the report.
