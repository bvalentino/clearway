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
