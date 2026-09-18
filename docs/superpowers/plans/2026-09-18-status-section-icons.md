# Plan: Status Section Icons

**Date:** 2026-09-18
**Base:** 7ae81c1fca4c52beaf290a2035746c975ff95c69

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
