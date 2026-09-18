# Status Section Icons

**Date:** 2026-09-18
**Base:** 7ae81c1fca4c52beaf290a2035746c975ff95c69
**PR:** #222

A worktree's status is named in three places — the sidebar's status section headers, the row's
context-menu Status picker, and the row badge — and in all three it is text alone, so the operator
reads five words rather than recognising five shapes. This change gives `WorktreeStatus` one SF
Symbol per case, a Linear-style progress circle tinted with the status's existing colour, and
renders it ahead of the name in all three places. Nothing about what a status is, how it is set or
how it is stored changes.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Where does the icon appear? | All three places a status is named: before the title in a status section header (`SidebarView.statusSection`, `SidebarView.swift:379`), before each entry in the context-menu Status picker (`SidebarView.swift:411-424`), and inside the row pill (`StatusBadge`, `WorktreeRow.swift:93-101`). One mapping is used everywhere. | Operator |
| 2 | What icons? | Linear-style progress circles: Todo an empty circle, In progress a half-filled circle, In review a three-quarter-filled circle, Done a filled circle with a checkmark, On hold a circle with a pause. All SF Symbols, no custom assets, tinted with the case's existing `color`. | Operator |
| 3 | Does the picker's "None" row get an icon? | No. "None" is the absence of a status, so there is nothing to map. It stays a plain `Text("None")` and renders without a leading symbol; macOS indents the iconned rows past it, which is the intended reading — the row is not one of the five. | Operator |
| 4 | Which concrete symbol names? | `circle` (Todo), `circle.lefthalf.filled` (In progress), `circle.inset.filled` (In review), `checkmark.circle.fill` (Done), `pause.circle` (On hold). Availability verified, not guessed — see assumption 1. | Spec author |
| 5 | Why is In review not a three-quarter circle? | **SF Symbols ships no three-quarter-filled circle at this deployment target.** The catalogue's partial circles are halves only (`circle.lefthalf.filled`, `.righthalf`, `.tophalf`, `.bottomhalf`). The near alternatives were rejected: `chart.pie.fill` is an exploded pie whose detached wedge breaks the ring silhouette the other four share; `moonphase.waxing.gibbous` is a multicolour moon glyph, is new in macOS 13.0 (no margin under the target) and reads as weather, not progress; `circle.lefthalf.striped.horizontal`, `circle.dotted.circle` and `progress.indicator` are macOS 14+/15. `circle.inset.filled` is a ring with a filled disc inside it — one monotone step past half, one short of the solid Done mark — so the five read as a progression. Rendered and compared in the scratchpad (assumption 2). **This deviates from decision 2's literal wording; flagged as a question.** | Spec author |
| 6 | Is On hold filled or outlined? | Outlined: `pause.circle`, not `pause.circle.fill`. Decision 2 says "filled" only of Done. A solid disc is the vocabulary's terminal mark, and spending it on a parked worktree would make On hold read as complete at badge size. | Spec author |
| 7 | What is the property called? | `var symbol: String`, matching `Todo.Status.symbol` (`Todo.swift:24-29`), the one existing enum in the app that maps cases to SF Symbols. Not `systemImage`, which is the SwiftUI argument label, not a local convention. | Spec author |
| 8 | Does the Worktrees section header get an icon in the by-status view? | No. That section is the no-status bucket (`SidebarView.swift:226`) and its header is also the clear-status drop target (`SidebarView.swift:530`). It is the header form of decision 3's "None": no status, so no icon. | Spec author |
| 9 | How is the icon tinted in each place? | The same way: `status.color` on the image. In the header and the badge this is an ordinary `foregroundStyle`. In the context menu it may not survive — AppKit renders `NSMenuItem` images as templates — so the tint is applied uniformly and the menu is allowed to render monochrome. The icon still carries the shape, which is the part that distinguishes the row. Confirmed by hand in the running app at build. | Spec author |
| 10 | Does the badge change shape? | No. `StatusBadge`'s `Text` becomes an `HStack(spacing: 3)` of the image and the same lowercased name, still inside the existing `rowBadge` capsule (`WorktreeRow.swift:103-111`). `rowBadge` applies `.caption2` to the whole subtree, so the symbol scales with the label for free and `fixedSize()` keeps it from truncating. | Spec author |
| 11 | Does any file need splitting first? | No. `SidebarView.swift` is 653 lines and `WorktreeRow.swift` 111, against SwiftLint's 700-line `file_length` warning (`.swiftlint.yml`); this change adds a handful of lines to each and ~10 to `WorktreeStatus.swift`. No new `swiftlint:disable`. Superseded in part: one new file, `Sources/App/SidebarIcon.swift`, was added — see decision 16. | Spec author |
| 12 | Is a wrong symbol name catchable? | Yes, and it must be: `Image(systemName:)` on a name that does not resolve renders nothing, with no compiler error and no runtime log. A test asserts each `symbol` resolves through `NSImage(systemSymbolName:accessibilityDescription:)`. That proves the name is spelled correctly; it does **not** prove macOS 13 availability, which assumption 1 pins instead. | Spec author |
| 13 | Does anything else change? | No. The five cases, their slugs, their display names, the persisted format, the grouping rules, the drop targets and the `.status`-mode badge suppression (`SidebarView.swift:504`) are all untouched. Superseded in part by decision 15: the colours did change. | Spec author |
| 14 | What colour is a status section header's title? | Primary, the same as the sidebar's Tasks / Prompts / Commands rows (`SidebarView.destinationRow`), so the five section titles read as sidebar labels rather than as the secondary-toned system section headers they defaulted to. The icon keeps `status.color`. | Operator, hands-on check |
| 15 | What are the five colours? | Todo gray, In progress yellow, In review green, Done indigo, On hold gray. Replaces the palette decision 13 had frozen (blue / purple / green / orange for the middle four). On hold and Todo deliberately share gray — both are "not being worked on". | Operator, hands-on check |
| 16 | Where does a status section header sit horizontally? | On the row grid. A `Section` header is inset less than a list row, and a header `Label` sizes its icon slot to the glyph rather than to the column the rows use, so the header's icon and title rendered a few points left of `SidebarView.destinationRow`'s and `WorktreeRow`'s. `SidebarRowMetrics` (`Sources/App/SidebarIcon.swift`, its own file so that `SidebarView.destinationRow`, which draws no worktree row, does not depend on a file named for worktree rows) now holds both numbers — `iconWidth` (18), applied to the icon slot of every destination row, every worktree row and the header, and `headerLeadingInset` (4), the header's leading padding. The padding is applied before `.frame(maxWidth: .infinity)`, so the drop-target highlight still covers the full header width. No extra top spacing: the section's own header spacing already separates it. The picker rows and the badge keep their own layout. | Operator, hands-on check |
| 17 | Are the rows inside a status section indented under their header? | Yes, by one icon column less the header title's own leading bearing: `SidebarRowMetrics.statusRowIndent = iconWidth + headerIconSpacing - titleLeadingBearing` (18 + 6 − 3 = 21), with the icon column itself leading-aligned (the `SidebarIcon` view, `Sources/App/SidebarIcon.swift`), so a row's icon starts where its header's title starts. After decision 16 the header and its rows shared one leading edge, so the rows read as the header's siblings; a first attempt at a flat 8 was still too little. The value is **computed**, not chosen — the header title sits at `headerLeadingInset + iconWidth + headerIconSpacing` and the row already carries the `headerLeadingInset` worth of list inset the header has to add, leaving `iconWidth + headerIconSpacing`. Centring the glyph inside that column made the sum true of the column and false of the pixels — measured on the operator's screenshot, an indented row's column landed on the header's title (78 px against 77, at 2x) while the `⌘N` badge drawn in it started 8 px further right, half its own slack inside the 18-point column. The glyph is therefore flush with the column's leading edge at all three sites that draw one — worktree rows, destination rows and the header — which holds them on one axis and makes the indent true of what is drawn rather than only of the frames. `Label`'s icon-to-title gap is not a public constant, so the header is an explicit `HStack(spacing: SidebarRowMetrics.headerIconSpacing)` of the same tinted image and title rather than a `Label`: owning that gap is what makes the sum true by construction instead of a guess about SwiftUI's default. The indent is leading padding on the row's **content** — `worktreeRowView`'s `leadingIndent` parameter, applied before `.tag`, so the list row itself is unchanged and the selection highlight, hover and drop target still span the full sidebar width. It is passed only by `statusSection`; the parameter defaults to 0, so the Worktrees section, the group sections and the none grouping — which share the same `worktreeRowView` — are untouched. The last term is the operator's final 3-point correction: once the icon column was flush at its leading edge the row's icon still read 3 points right of the header's title, because the title is a `Text` and its first glyph's ink starts inside the `Text`'s own leading edge. `titleLeadingBearing` (3) names that and is subtracted from the sum, so the indent stays derived rather than becoming a tuned literal. | Operator, hands-on check |
| 18 | Do the Worktrees and group headers move onto the same axis? | No. `SidebarRowMetrics.headerLeadingInset` is applied only to the five status section headers, so the muted Worktrees header (`SidebarView.worktreesSectionHeader`) and the group headers keep the stock `Section` inset and sit 4 pt left of them in Group by → Status. This is intended: they are a different kind of header — muted, no icon, carrying the toolbar buttons — so they are not on the status headers' axis and do not need to be. The operator approved the screen with the offset in place. | Operator |

## Assumptions

Each verified at base `7ae81c1`. Empirical work was done in the session scratchpad only — no probe
script or temporary file was written into the repo.

1. **All five chosen symbols predate the macOS 13.0 deployment target.** `project.yml:11` sets
   `MACOSX_DEPLOYMENT_TARGET: "13.0"`. Availability read from Apple's own catalogue on this
   machine, `/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist`
   (macOS 26.6.2, build 25G83, read 2026-09-18), which maps each symbol to a release year and each
   year to a per-platform OS version:

   | Status | Symbol | Introduced (macOS) |
   | --- | --- | --- |
   | Todo | `circle` | 10.15 |
   | In progress | `circle.lefthalf.filled` | 12.0 |
   | In review | `circle.inset.filled` | 12.0 |
   | Done | `checkmark.circle.fill` | 10.15 |
   | On hold | `pause.circle` | 10.15 |

   Every one is at least a full major version below the target.
2. **The five render as a legible progression at icon size.** Drawn with
   `NSImage(systemSymbolName:)` at 34pt in a scratchpad Swift script and inspected, alongside the
   rejected `chart.pie.fill` and `moonphase.waxing.gibbous` alternatives of decision 5. The
   scratchpad script is not part of the change.
3. **`WorktreeStatus` already carries its own presentation, so the mapping has one home.**
   `displayName` (`WorktreeStatus.swift:19-27`) and `color` (`WorktreeStatus.swift:29-37`) are
   properties on the enum and every rendering site reads them. `symbol` joins them, which is what
   makes decision 1's "one mapping used everywhere" structural rather than a convention.
4. **A section header can hold more than a `Text` without losing its drop target.** The header is
   already a `Text` carrying `.frame(maxWidth: .infinity, alignment: .leading)`, a conditional
   `.background` and `.dropDestination` (`SidebarView.swift:379-385`); the modifiers attach to
   whatever view precedes them, so swapping the `Text` for a `Label` leaves the full-width hit area
   and the targeting highlight exactly as they are.
5. **The picker rows are ordinary SwiftUI views and can carry a `Label`.** The Status submenu is a
   `Picker` with `.pickerStyle(.inline)` over `Text` rows tagged with `Optional(status)`
   (`SidebarView.swift:412-423`); the tag, not the row's content, is what the selection binds to, so
   replacing `Text` with `Label` changes the drawing and nothing else. `NSMenuItem` carries a state
   checkmark and an image independently, so the picker keeps its checkmark on the current value.
6. **`rowBadge` sets the font for the whole badge subtree.** `WorktreeRow.swift:104-109` applies
   `.font(.caption2)` first, then padding, background and `fixedSize()`. An `Image(systemName:)`
   inside inherits that font and scales with it, so the badge needs no explicit `imageScale`.
7. **`Todo.Status.symbol` is the existing naming precedent.** `Todo.swift:24-29`. It is the only
   case-to-SF-Symbol map in `Sources/App`, and it is named `symbol`.
8. **A new test method needs no project regeneration, but the suite still only runs one way.**
   `project.yml` globs `Sources` and `Tests` by path and `./scripts/ci.sh` runs `xcodegen generate`
   before building, which CLAUDE.md's `## Pipeline` names as the only runner of the test suite.
9. **The test target can reach `NSImage`.** `Tests/WorktreeStatusTests.swift:1-3` already imports
   `SwiftUI` and `@testable import Clearway`; the tests are a macOS bundle, so `import AppKit` is
   available for decision 12's resolution check.

## Objective

An operator scanning the sidebar recognises a worktree's status by shape and colour before reading
any word, and sees the same mark in the menu they set it from and on the row it lands on.

### Success criteria

1. In the by-status view, each of the five section headers shows its status's symbol, tinted with
   the status's colour, before the section title. The Worktrees section header shows none.
2. Right-clicking a non-main worktree and opening Status shows the five entries each with its
   symbol; "None" shows no symbol; the checkmark still marks the current value and choosing an
   entry still sets the status.
3. In the by-group and none views, a row's status badge shows the symbol and the lowercased name
   together inside the existing capsule, both in the status colour, with the pill still sized to
   its content and not truncating or wrapping.
4. In the by-status view no row shows a badge, unchanged.
5. The main worktree's row still shows the primary badge and no status badge, and its context menu
   still has no Status submenu.
6. Every symbol renders — no blank icon slot anywhere — and the five read as a progression from
   empty to filled with On hold visibly outside it.
7. Nothing about status slugs, display names, colours, persistence, drag-and-drop, search or
   grouping changes; `groups.json` files written before this change load identically.
8. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports no new warnings or errors.

### Test coverage this requires

Criteria 1–6 are SwiftUI view state and are confirmed by hand in the running app. In
`Tests/WorktreeStatusTests.swift`:

- `WorktreeStatus.allCases.map(\.symbol)` equals the five names of decision 4, in case order —
  the pin that makes a silent change to the vocabulary fail the suite.
- Each `symbol` resolves through `NSImage(systemSymbolName:accessibilityDescription:)`
  (decision 12).
- The existing `displayName` and `color` assertions stay as they are, which is criterion 7's pin
  on the enum.

## Verification

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds and runs the test suite — the regression check for
every build task and the full gate at sign-off, per CLAUDE.md's `## Pipeline` section. It is the
only test runner; do not hand-write an `xcodebuild` line.

The view-only criteria are confirmed against the running app (`./scripts/run.sh`), in all three
Group by modes, with at least one worktree in each status. Expect the un-gitignored
`default.profraw` in the repo root after any Debug launch; report it before sign-off and never
`git add -A`.

## Files touched

| File | Change |
| --- | --- |
| `Sources/App/WorktreeStatus.swift` | `WorktreeStatus` gains `var symbol: String` beside `displayName` and `color` (decisions 4, 7). |
| `Sources/App/SidebarView.swift` | `statusSection`'s header becomes a `Label` with the tinted symbol; the Status picker's five rows become `Label`s and "None" stays a `Text` (decisions 1, 3, 8, 9). |
| `Sources/App/WorktreeRow.swift` | `StatusBadge`'s `Text` becomes an `HStack` of the symbol and the lowercased name inside the same `rowBadge` capsule (decision 10); `ShortcutBadge` and the icon slot move out to `SidebarIcon.swift` (decisions 16, 17). |
| `Sources/App/SidebarIcon.swift` | New. `SidebarRowMetrics`, the `SidebarIcon` slot every sidebar glyph draws through, and the now-`private` `ShortcutBadge` (decisions 16, 17). |
| `Tests/WorktreeStatusTests.swift` | Pins the five symbol names in case order and asserts each resolves (decision 12). |
| `docs/superpowers/specs/2026-09-18-status-section-icons.md` | This document. |
| `docs/superpowers/plans/2026-09-18-status-section-icons.md` | The plan, written by the next stage. |

## Out of scope

- Any change to the statuses themselves: cases, slugs, order, display names or colours.
- Custom, user-chosen or per-project icons; a settings surface for them.
- Icons for `WorktreeGrouping`, for groups, for the Worktrees section, or for the "None" picker row
  (decisions 3, 8).
- Status anywhere it is not already rendered: no toolbar, task window, window title or tab surface.
- Any change to persistence, drag-and-drop, search, the ⌘N badge or ⌘1…9.
- `AppKeyboardShortcuts`; this change declares no shortcut.
- Fixing `Todo.Status.symbol`'s `circle.dotted.circle`, which is macOS 14.0 and therefore blank on
  the 13.0 deployment target. A pre-existing defect in the Todos panel, unrelated to worktree
  status, and owed its own task.
