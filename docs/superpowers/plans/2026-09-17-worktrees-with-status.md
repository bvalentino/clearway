# Worktrees with Status — implementation plan

**Date:** 2026-09-17
**Base:** c19e44ac9f624e305bbe4e72e0cefdcfceb553de

Breaks down `docs/superpowers/specs/2026-09-17-worktrees-with-status.md`. Every design decision
below is carried from that spec; this document only orders the work and says how each piece is
verified.

## Architecture decisions carried from the spec

- Statuses are a fixed list — Todo, In progress, In review, Done, On hold — plus "no status", which
  is the default. Not customisable, not renameable, not reorderable.
- Status is per project, stored in the project's `.clearway/groups.json`, keyed by `Worktree.id`
  (the path), exactly as group membership is. It is independent of `TASK.md`'s `status` frontmatter.
- The main worktree has no status: `setStatus` guards on `isMain`, its row never shows a badge, and
  its context menu has no Status submenu.
- One file, one store: `WorktreeGroupsPayload` widens to carry `statuses` and `grouping`. The file
  keeps the name `groups.json`; `WorktreeGroupStore`, `WorktreeGroupManager` and `groups.json` are
  not renamed.
- The widened payload gets a **hand-written lenient `init(from:)`**. This is load-bearing: the
  synthesised initialiser throws `keyNotFound` on every existing `groups.json`, the legacy
  `[WorktreeGroup]` fallback would then also throw, and `load()` would reset to `.empty` — wiping
  every project's groups and order.
- An unrecognised status slug is dropped at load; the rest of the map survives. `statuses` therefore
  decodes as `[String: String]` and maps through `WorktreeStatus(rawValue:)`. An unrecognised
  `grouping` slug falls back to `.group` the same way, for the same reason.
- One ordering function, then a partition. `.group` is today's order (default section, then each
  group). `.none` is the identical list rendered under one header. `.status` is that same list
  stably partitioned into six buckets: no status first, then the five statuses in fixed order.
  So `⌘1…9` and the `⌘N` badge read one list per mode, and a status section's rows keep their
  default/group relative order for free.
- `sidebarOrderedWorktrees` gains a `grouping:` **parameter**; both callers pass
  `groupManager.grouping`. The function stays pure over its inputs.
- Visibility (`Worktree.visible`) is applied before ordering, so the detached-worktree rule is
  inherited by every view mode without extra work.
- The row search predicate moves out of the `SidebarView` closure onto
  `WorktreeGroupManager.matches(_:query:taskTitle:)` so it is reachable from XCTest. It gains a
  status-display-name branch and keeps its branch-name, task-title and group-name branches.
- The gear becomes a `Menu`: an inline `Picker` titled "Group by" with Group / Status / None, then
  a "Worktree Settings…" item opening the existing `WorktreeSettingsSheet` unchanged.
- The Status submenu is `Menu("Status")` wrapping an inline `Picker` bound to `WorktreeStatus?`,
  with a "None" row tagged `WorktreeStatus?.none` — a picker gives the native checkmark, six
  `Button`s would not.
- Drag/drop per mode: `.group` unchanged (rows drag between sections, `.onMove` reorders within
  one); `.status` rows drag onto section headers and `.onMove` is disabled; `.none` rows are not
  draggable and the header is not a drop target. The Worktrees header's drop clears whichever axis
  the current view sections by — group in `.group`, status in `.status` — never both.
- Status sections are all present when unfiltered, even when empty; a section with zero matches is
  hidden only while a search is active, the rule groups already follow.
- The badge is the `PrimaryBadge` shape: status name lowercased, `.caption2`, `.fixedSize()`, in a
  `Capsule()`, foreground the status colour and background that colour at `opacity(0.15)`. It
  occupies the same `WorktreeRow` slot as the primary badge, which main can never contest.
  It is not shown in `.status` view, where the sections already say it.
- Colours are SwiftUI system colours, never hex: gray, blue, purple, green, orange.
- A removed worktree's status is pruned in `reconcile(knownWorktreeIds:)` beside `groups` and
  `defaultOrder`, so the one caller and its empty-refresh guard cover statuses too.
- `SidebarView.swift` is split **before** the feature lands: `WorktreeRow`, `ShortcutBadge`,
  `PrimaryBadge` move to `Sources/App/WorktreeRow.swift` with the new `StatusBadge`.
  `ShortcutBadge` loses `private` because `SidebarView.destinationRow` still uses it. No new
  `swiftlint:disable`.
- No menu command and no keyboard shortcut for the view mode; `AppKeyboardShortcuts` is untouched.

## Decisions this plan makes that the spec left open

1. **Status raw values are the case names** — `todo`, `inProgress`, `inReview`, `done`, `onHold` —
   and `WorktreeGrouping`'s are `group`, `status`, `none`. These strings are the persisted form and
   must not change after T1. The spec fixes the display names and the drop-unknown-slug rule but
   not the slugs themselves.
2. **The Status submenu sits directly under "Remove Worktree", behind a `Divider()`**, above the
   existing Open in / Reveal in Finder / Copy Path block, so the two destructive worktree actions
   stay grouped.

## Regression command

Every task's verification is `./scripts/ci.sh` — the project's only runner of the test suite, and
the only thing that runs `xcodegen generate`, without which the two new Swift files are invisible to
the build.

## Dependency graph

```
T1 model
 ├──> T2 payload + store tests ──> T3 manager state ──> T4 ordering + search ──┐
 └──> T5 WorktreeRow extraction ───────────────────────────────────────────────┤
                                                                               ├──> T6 sidebar
                                                                               │     rendering
                                                                               └──> T7 sidebar
                                                                                     interactions
```

Order: T1 → (T2 and T5 in parallel) → T3 → T4 → T6 → T7.

---

### T1: `WorktreeStatus` and `WorktreeGrouping`

**Files**

- `Sources/App/WorktreeStatus.swift` (new)

**What it does**

Adds the two pure enums. No I/O, no views, no other file changes.

`WorktreeStatus`: `String`-raw-value, `Codable`, `CaseIterable`, `Identifiable`, `Hashable`, with
cases in this exact `allCases` order — `todo`, `inProgress`, `inReview`, `done`, `onHold` — raw
values equal to the case names. Each exposes:

| case | `displayName` | `color` |
| --- | --- | --- |
| `todo` | `Todo` | `.gray` |
| `inProgress` | `In progress` | `.blue` |
| `inReview` | `In review` | `.purple` |
| `done` | `Done` | `.green` |
| `onHold` | `On hold` | `.orange` |

`WorktreeGrouping`: `String`-raw-value, `Codable`, `CaseIterable`, `Identifiable`, `Hashable`, cases
`group`, `status`, `none` in that order, with `displayName` `Group` / `Status` / `None`. It is never
used as an `Optional` anywhere — `WorktreeGrouping?.none` would be ambiguous with the case.

The file imports SwiftUI for `Color`. `id` is `rawValue` on both.

**Acceptance criteria**

- `WorktreeStatus.allCases` is exactly `[.todo, .inProgress, .inReview, .done, .onHold]`.
- Raw values are `todo`, `inProgress`, `inReview`, `done`, `onHold`; `WorktreeStatus(rawValue:)`
  returns `nil` for anything else.
- Display names and colours are the table above; no hex colours anywhere in the file.
- `WorktreeGrouping.allCases` is `[.group, .status, .none]` with raw values `group`, `status`,
  `none`.

**Verification**

`./scripts/ci.sh` is green (the file compiles once `xcodegen generate` picks it up) and
`swiftlint lint --quiet` reports no new warnings. The raw values are pinned by the literal-bytes
tests in T2, not by a test file of their own.

---

### T2: Widen `WorktreeGroupsPayload` with a lenient decoder

**Files**

- `Sources/App/WorktreeGroupStore.swift`
- `Tests/WorktreeGroupStoreTests.swift`

**What it does**

Adds `var statuses: [String: WorktreeStatus]` and `var grouping: WorktreeGrouping` to
`WorktreeGroupsPayload`, and hand-writes `init(from:)` so no existing file is rejected:

- `groups` and `defaultOrder` keep `try container.decode(...)` — their absence still means "this is
  not a payload", which is what sends a legacy bare-array file down the `[WorktreeGroup]` fallback.
- `statuses` is read as `try container.decodeIfPresent([String: String].self, forKey: .statuses) ?? [:]`
  then `compactMapValues(WorktreeStatus.init(rawValue:))`, so one unrecognised slug drops that entry
  and nothing else.
- `grouping` is read as `try container.decodeIfPresent(String.self, forKey: .grouping)`, mapped
  through `WorktreeGrouping(rawValue:)`, defaulting to `.group` for both an absent key and an
  unrecognised slug. Decoding it straight into the enum would throw `dataCorrupted` on a bad slug
  and take the whole payload — and every project's groups — down with it.

`encode(to:)` stays synthesised: a `[String: WorktreeStatus]` and a raw-representable enum encode to
exactly the `[String: String]` / string wire shape the decoder reads.

A memberwise `init(groups:defaultOrder:statuses:grouping:)` with `statuses: [:]` and
`grouping: .group` defaults keeps existing construction sites (`load()`'s legacy branch, `.empty`,
`WorktreeGroupManager.save()`) compiling and behaving as before. `.empty` becomes
`WorktreeGroupsPayload(groups: [], defaultOrder: [], statuses: [:], grouping: .group)`.

Nothing about `save`, the watcher, the temp-file/`replaceItemAt` durability shape or the file's
permissions changes.

**Acceptance criteria**

- A `groups.json` written before this change — literal bytes
  `{"groups":[{…}],"defaultOrder":["/a","/b"]}` — decodes with its groups and default order intact,
  `statuses == [:]` and `grouping == .group`.
- A payload carrying `"statuses":{"/a":"todo","/b":"bogus"}` decodes to `["/a": .todo]`; the bogus
  entry is dropped and the rest of the payload survives.
- A payload carrying `"grouping":"bogus"` decodes with `grouping == .group` and its groups intact.
- A payload with `"grouping":"status"` decodes to `.status`.
- A payload encoded and re-decoded round-trips `statuses` and `grouping` unchanged.
- The existing legacy bare-array fallback, missing-file and corrupt-file behaviours are unchanged.

**Verification**

`./scripts/ci.sh` is green, with new cases in `Tests/WorktreeGroupStoreTests.swift` covering each
criterion. The wire-format cases assert over **literal bytes**, not a round trip — a round trip
cannot catch a renamed key or slug, which is the exact failure decision 9 guards against. The
existing tests in that file must keep passing untouched.

---

### T3: Manager state — `statuses`, `grouping`, `setStatus`, pruning

**Files**

- `Sources/App/WorktreeGroupManager.swift`
- `Tests/WorktreeGroupManagerTests.swift`

**What it does**

Gives `WorktreeGroupManager` the new state and its mutators. Ordering and search are T4; this task
changes no signature that `SidebarView` or `ContentView` call.

- `@Published private(set) var statuses: [String: WorktreeStatus] = [:]` and
  `@Published private(set) var grouping: WorktreeGrouping = .group`.
- `init`'s load Task assigns both from the loaded payload. The `startWatching` reload compares
  before assigning, exactly as it does for `groups` and `defaultOrder`, so an external edit to
  `.clearway/groups.json` reaches the UI without a restart and without a redundant publish.
- `func status(for worktreeId: String) -> WorktreeStatus?` reads `statuses[worktreeId]`.
- `func setStatus(_ status: WorktreeStatus?, for wt: Worktree)` returns early for `wt.isMain`
  (mirroring `addWorktree`'s guard rather than relying on the view), returns early when the value is
  unchanged, removes the key for `nil`, and saves.
- `func setGrouping(_ grouping: WorktreeGrouping)` returns early when unchanged, assigns, saves.
- `reconcile(knownWorktreeIds:)` prunes `statuses` to the known IDs alongside `groups` and
  `defaultOrder`, and its `guard changed` includes the status change, so a status-only prune still
  saves.
- `save()` builds the payload with `statuses` and `grouping`.

**Acceptance criteria**

- `setStatus(.inReview, for: wt)` publishes it, `status(for: wt.id)` returns it, and a fresh
  `WorktreeGroupStore(projectPath:).load()` on the same project path reports it.
- `setStatus(nil, for: wt)` removes the entry and persists the removal.
- `setStatus(_:for:)` on a worktree with `isMain == true` leaves `statuses` empty and writes nothing.
- `setGrouping(.status)` publishes and persists it; calling it again with the same value is a no-op.
- `reconcile(knownWorktreeIds:)` drops the status of a worktree absent from the set and keeps the
  rest, and a reconcile whose only change is a status prune still persists.

**Verification**

`./scripts/ci.sh` is green, with new cases in `Tests/WorktreeGroupManagerTests.swift` covering each
criterion. Follow the file's existing shape: build worktrees with its `makeWorktree` helper and
`try await Task.sleep(nanoseconds: 100_000_000)` after each mutation before asserting, because
`save()` is fire-and-forget.

---

### T4: Ordering per view mode and the liftable search predicate

**Files**

- `Sources/App/WorktreeGroupManager.swift`
- `Sources/App/SidebarView.swift`
- `Sources/App/ContentView.swift`
- `Tests/WorktreeGroupManagerTests.swift`

**What it does**

Threads the view mode through the one ordering function and lifts the row predicate out of the view.

`sidebarOrderedWorktrees` gains a `grouping: WorktreeGrouping` parameter, placed before `matches:`.
Its existing body becomes the base ordering, which `.group` and `.none` both return unchanged —
`.none` differs only in how the view renders it. For `.status`, the base list is **stably
partitioned** into six buckets in this order: worktrees with no status, then `.todo`, `.inProgress`,
`.inReview`, `.done`, `.onHold`. A stable partition is what makes a status section's rows keep their
default/group relative order, and it keeps main first (main can have no status). The `matches`
predicate stays applied where it already is, so filtering is unaffected by the partition.

`func matches(_ wt: Worktree, query: String, taskTitle: String?) -> Bool` moves the closure body
from `SidebarView.orderedWorktrees` onto the manager:

- an empty/whitespace-only `query` returns `true`;
- otherwise true when `wt.displayName`, the passed `taskTitle`, the name of the group containing
  `wt.id`, or the `displayName` of `status(for: wt.id)` case-insensitively contains the query.

Call sites:

- `SidebarView.orderedWorktrees` passes `grouping: groupManager.grouping` and
  `matches: { groupManager.matches($0, query: searchText, taskTitle: $0.branch.flatMap { titles[$0] }) }`.
- `SidebarView.sortedWorktrees` and `ContentView.sortedWorktrees` pass
  `grouping: groupManager.grouping` and keep `matches: { _ in true }`.

**Acceptance criteria**

- `.group` and `.none` return the identical array, and it equals what the function returned before
  this change for the same inputs.
- `.status` returns the same worktrees, none lost and none duplicated, ordered no-status first then
  the five statuses in fixed order, with each bucket preserving the `.group` relative order of its
  members (a grouped and an ungrouped worktree sharing a status keep their `.group` order).
- `.status` applies `Worktree.visible` first: a bare-detached, unopened worktree is absent with
  `showingDetached: false` and present with `true`, and a closed worktree still appears.
- `matches(_:query:taskTitle:)` returns true for an empty query; for a branch-name substring; for a
  task-title substring; for a containing group's name; and for `"review"` against a worktree whose
  status is `.inReview`. It returns false for a query matching none of those.

**Verification**

`./scripts/ci.sh` is green, with new cases in `Tests/WorktreeGroupManagerTests.swift` covering each
criterion and the file's existing `sidebarOrderedWorktrees` cases updated to pass
`grouping: .group` and still assert the same results.

---

### T5: Split `WorktreeRow` out of `SidebarView.swift` and add `StatusBadge`

**Files**

- `Sources/App/WorktreeRow.swift` (new)
- `Sources/App/SidebarView.swift`

**What it does**

Moves `WorktreeRow`, `ShortcutBadge` and `PrimaryBadge` verbatim out of `SidebarView.swift` into
`Sources/App/WorktreeRow.swift`, then adds the status badge. No behaviour changes, no call-site
changes beyond the move.

- `ShortcutBadge` loses `private` (it stays internal, no other change) because
  `SidebarView.destinationRow` still uses it. `PrimaryBadge` stays `private` — only `WorktreeRow`,
  which moves with it, refers to it.
- `WorktreeRow` gains `var status: WorktreeStatus? = nil`, defaulted so every existing construction
  site compiles untouched.
- A new `private struct StatusBadge: View` takes a `WorktreeStatus` and renders
  `Text(status.displayName.lowercased())`, `.font(.caption2)`,
  `.foregroundStyle(status.color)`, `.padding(.horizontal, 6)`, `.padding(.vertical, 2)`,
  `.background(status.color.opacity(0.15), in: Capsule())`, `.fixedSize()` — the `PrimaryBadge`
  shape with the status colour swapped in.
- In `WorktreeRow.body`, the badge slot between the text `VStack` and the `Spacer()` renders
  `PrimaryBadge()` when `worktree.isMain` and `StatusBadge(status:)` when a non-nil `status` is
  passed. Main can never carry a status, so the two can never contest the slot.

**Acceptance criteria**

- `SidebarView.swift` no longer declares `WorktreeRow`, `ShortcutBadge` or `PrimaryBadge`, and its
  behaviour is unchanged — nothing is passed for `status` yet.
- `swiftlint lint --quiet` reports no new warnings or errors, and neither file carries a new
  `swiftlint:disable`.
- `StatusBadge` uses only SwiftUI system colours reached through `WorktreeStatus.color`.

**Verification**

`./scripts/ci.sh` is green. Since the move changes no behaviour, the existing suite passing is the
proof; there is nothing new for XCTest to reach — a SwiftUI `View` body is not inspectable, which is
why the spec puts the decision rules on the manager instead.

---

### T6: Render the three view modes in the sidebar

**Files**

- `Sources/App/SidebarView.swift`

**What it does**

Turns the gear into the Group by menu and builds the list per view mode. Status mutation gestures
are T7; this task only renders.

**Gear → menu.** The `SidebarHeaderButton(systemImage: "gearshape")` in the Worktrees header becomes
a `Menu` carrying an inline `Picker("Group by", selection:)` over `WorktreeGrouping.allCases` and,
after a `Divider()`, a `Button("Worktree Settings…") { activeSheet = .worktreeSettings }` — the
existing sheet, unchanged. The selection binding reads `groupManager.grouping` and writes
`groupManager.setGrouping`. The menu copies `GroupSectionHeader`'s borderless-in-a-sidebar-header
shape: `.menuStyle(.borderlessButton)`, `.menuIndicator(.hidden)`, `.fixedSize()`, with the same
`Image(systemName: "gearshape")` label styling `SidebarHeaderButton` gives it.

**List content per mode.** The `List`'s content switches on `groupManager.grouping`:

- `.group` — `defaultWorktreeSection` then `ForEach(groupManager.groups) { groupSection($0) }`,
  exactly as today.
- `.none` — one section: the Worktrees header (refresh, gear menu, plus), the `SearchField`, every
  row of `orderedWorktrees`, and the existing loading and error blocks. No `.onMove`.
- `.status` — the Worktrees section holding only the rows whose `groupManager.status(for:)` is
  `nil`, then one section per `WorktreeStatus.allCases` case in order, each holding that status's
  rows. The search field and the loading/error blocks stay in the Worktrees section.

The Worktrees section's rows are therefore mode-dependent: all ungrouped rows in `.group`, all rows
in `.none`, all unstatused rows in `.status`. Extract that into one helper rather than duplicating
the section body three times.

**Empty sections and search.** All five status sections render when unfiltered, even when empty. A
status section with zero rows is hidden only while `isSearching`, the same rule and the same
`if !(isSearching && rows.isEmpty)` shape `groupSection` already uses.

**Badge.** `worktreeRowView` passes `status:` to `WorktreeRow` as
`groupManager.grouping == .status ? nil : groupManager.status(for: wt.id)` — the by-status view's
sections already say it, and main never has one to pass.

**Acceptance criteria**

- Switching Group by re-renders the list without losing or duplicating a worktree, and switching
  back to Group restores the same groups.
- `.status` renders the Worktrees section first, then Todo, In progress, In review, Done, On hold,
  all present when unfiltered even if empty, and no row carries a status badge.
- `.none` renders one flat list with main first and every row's badge showing its status.
- `.group` renders exactly as before, now with status badges on rows that have one.
- Under an active filter, a status section with no matches is hidden and one with matches is not.
- `⌘N` badges and `⌘1…9` match the visible order in all three modes, and worktrees hidden by
  Settings → Appearance → Show detached worktrees stay hidden in all three.
- `swiftlint lint --quiet` reports no new warnings and `SidebarView.swift` carries no new
  `swiftlint:disable`.

**Verification**

`./scripts/ci.sh` is green. The rendering criteria are SwiftUI view state, unreachable from XCTest,
so they are confirmed by hand against `./scripts/run.sh` on a project with at least one group, one
ungrouped worktree and one detached worktree — switching all three modes, with and without a filter,
and holding ⌘ to compare the badges against the visible order. Expect the un-gitignored
`default.profraw` in the repo root after any Debug launch; never `git add -A`.

---

### T7: Status submenu, header drops, and drag gating

**Files**

- `Sources/App/SidebarView.swift`

**What it does**

Adds the two ways a status is set, and gates dragging per mode.

**Status submenu.** In `worktreeContextMenu`, for a non-main worktree only, a `Divider()` then
`Menu("Status")` wrapping an inline `Picker` bound to
`Binding<WorktreeStatus?>(get: { groupManager.status(for: wt.id) }, set: { groupManager.setStatus($0, for: wt) })`,
with a `Text("None").tag(WorktreeStatus?.none)` row and one `Text(status.displayName)` row per
`WorktreeStatus.allCases`, each tagged `Optional(status)` so the tag type matches the selection.
`.pickerStyle(.inline)` and `.labelsHidden()`. Placed immediately after "Remove Worktree", above the
existing Open in / Reveal in Finder / Copy Path block. The submenu is available in every view mode.

**Header drops.**

- `.status` — each status section header is a `dropDestination(for: String.self)` that resolves each
  dropped ID to a worktree and calls `setStatus(<that section's status>, for:)`, with the same
  `Color.accentColor.opacity(0.12)` targeted highlight the group headers use and its own
  `@State` targeted-status. The Worktrees header's drop calls `setStatus(nil, for:)` — it clears the
  status, never the group.
- `.group` — unchanged: the Worktrees header clears group membership, group headers add to a group.
- `.none` — the header is not a drop destination at all. A drop there would silently mutate group
  membership the view does not show.

Every drop handler defers its mutation with `DispatchQueue.main.async`, as `dropIntoGroup` and
`dropIntoDefault` already do, to stay out of the `NSTableView` drop delegate.

**Drag and move gating.**

- `.draggableIf(!wt.isMain && groupManager.grouping != .none, …)` — rows are undraggable in `.none`.
- `.moveDisabled` is true for every row in `.status` and `.none`; `.onMove` is declared only on the
  `.group` sections, so there is no reorder to disable elsewhere.

**Acceptance criteria**

- Right-clicking a non-main row in any view shows a Status submenu with None and the five values,
  the current one checked; choosing one sets it and the badge updates in `.group` and `.none`.
- Right-clicking the main worktree's row shows no Status submenu, and its row never shows a badge.
- In `.status`, dragging a row onto a status section header sets that status and the row moves into
  that section; dropping on the Worktrees header clears it and the row moves back to the top section.
- In `.group`, dragging between group headers and the Worktrees header behaves exactly as before,
  and a row's status is unchanged by it.
- In `.none`, a row cannot be dragged and the header accepts no drop.
- No reorder is possible inside a status section or in the flat list; `.group` reorder is unchanged.

**Verification**

`./scripts/ci.sh` is green. These are all gesture and view-state criteria, unreachable from XCTest
(the mutation they drive — `setStatus` and its main guard — is already pinned by T3), so they are
confirmed by hand against `./scripts/run.sh` on the same project T6 used: exercise the submenu in
all three modes, drag onto each status header and the Worktrees header, drag between groups in
`.group`, and confirm rows refuse to drag in `.none`.

## Checkpoints

- **After T2** — `./scripts/ci.sh` green, and the literal-bytes test proves an existing project's
  `groups.json` still loads its groups. This is the highest-risk point in the change: getting it
  wrong destroys user data silently, which is why it lands second and is pinned over raw bytes.
- **After T4** — `./scripts/ci.sh` green with the full manager suite. Everything XCTest can reach is
  now pinned; from here the remaining work is view state confirmed by hand.
- **After T7** — `./scripts/ci.sh` green, `swiftlint lint --quiet` clean, and all twelve success
  criteria in the spec walked through in the running app.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The widened payload rejects an existing `groups.json` and `load()` resets to `.empty`, wiping every project's groups and default order | High | T2's hand-written lenient `init(from:)`, pinned by a literal-bytes test rather than a round trip |
| `SidebarView.swift` crosses SwiftLint's 700-line `file_length` warning again after T6 and T7 | Medium | T5's extraction removes roughly 85 lines first. If the file still crosses, report it rather than adding a `swiftlint:disable` — the spec forbids one — and propose moving the status section header or the gear menu into their own file |
| `.status` partition disagrees with `⌘1…9` or the `⌘N` badge | Medium | One ordering function serves all three readers; T4 pins the partition and both call sites pass `groupManager.grouping` |
| A `Picker` bound to `WorktreeStatus?` mis-tags and the checkmark lands on the wrong row | Low | Tag every case as `Optional(status)` and None as `WorktreeStatus?.none` so the tag type matches the selection type exactly; confirmed by hand in T7 |

## Build log

### T1: `WorktreeStatus` and `WorktreeGrouping`

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeStatus.swift` | New. `WorktreeStatus` (`todo`, `inProgress`, `inReview`, `done`, `onHold`) and `WorktreeGrouping` (`group`, `status`, `none`), both `String`-raw-value, `Codable`, `CaseIterable`, `Identifiable`, `Hashable`, with `id == rawValue`, `displayName`, and — on `WorktreeStatus` — `color`. |
| `Tests/WorktreeStatusTests.swift` | New. Nine cases pinning `allCases` order, raw values, `rawValue:` returning nil for an unrecognised slug, `id`, display names and colours for both enums. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` so the two new files reach the build. |

Raw values are left implicit rather than written out: SwiftLint's `redundant_string_enum_value`
rule is enabled here, so `case todo = "todo"` would have added a warning, and the acceptance
criteria forbid new warnings. The implicit derivation is exactly the case name the plan requires.
The doc comment on each enum records that the case names are the persisted slugs, since that is
what makes a rename a data-format change.

**Evidence**

The test file was written first and watched fail against the absent enums:

```
❌ Tests/WorktreeStatusTests.swift:11:24: cannot find 'WorktreeStatus' in scope
❌ Tests/WorktreeStatusTests.swift:41:24: cannot find 'WorktreeGrouping' in scope
```

**Deviation from the plan**

The plan gave T1 no test file, on the grounds that the raw values are pinned by T2's
literal-bytes cases. `Tests/WorktreeStatusTests.swift` was added anyway: T2's payload tests reach
only the `todo` / `status` slugs they happen to embed, and nothing in T2–T7 pins the `allCases`
order or the display names, both of which T4's status partition and T6's section headers depend
on. The file is additive and does not change what T2 is asked to assert.

**Gate**

`./scripts/ci.sh` — green. `Executed 429 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`swiftlint lint --quiet` — exit 0, no output.

### T2: Widen `WorktreeGroupsPayload` with a lenient decoder

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupStore.swift` | `WorktreeGroupsPayload` gains `statuses: [String: WorktreeStatus]` and `grouping: WorktreeGrouping`, a memberwise `init` defaulting them to `[:]` / `.group`, and a hand-written lenient `init(from:)`. `encode(to:)` stays synthesised. `.empty` spells all four fields. Nothing else in the file changed — save, the watcher, the temp-file durability shape and the permissions are untouched. |
| `Tests/WorktreeGroupStoreTests.swift` | Seven new cases over literal bytes plus a `writeGroupsFile` helper: pre-statuses file decodes and survives `load()`, unrecognised status slug dropped, unrecognised `grouping` slug falls back to `.group`, `"status"` reads back, encode/decode round trip, legacy bare-array file still keeps its groups. The five existing cases are untouched. |

`Clearway.xcodeproj/project.pbxproj` did not change: no file was added or removed, so
`xcodegen generate` produced no diff.

**Evidence**

The tests were added first, against a payload widened with the *synthesised* decoder, and the gate
was run to watch them fail. The decisive one is the data-loss case — `load()` fell all the way
through to `.empty`, losing the groups and the default order of a file written before this change:

```
✖ testLoadKeepsGroupsOfFileWrittenBeforeStatusesExisted, XCTAssertEqual failed: ("0") is not equal to ("1")
✖ testLoadKeepsGroupsOfFileWrittenBeforeStatusesExisted, XCTAssertEqual failed: ("nil") is not equal to ("Optional("Feature")")
✖ testLoadKeepsGroupsOfFileWrittenBeforeStatusesExisted, XCTAssertEqual failed: ("[]") is not equal to ("["/a", "/b"]")
✖ testDecodesFileWrittenBeforeStatusesExisted, failed: caught error: "DecodingError.keyNotFound: Key 'statuses' not found in keyed decoding container."
✖ testDecodeDropsUnrecognisedStatusSlug, failed: caught error: "DecodingError.dataCorrupted: Data was corrupted. Path: statuses./b. Debug description: Cannot initialize WorktreeStatus from invalid String value bogus"
✖ testDecodeFallsBackToGroupForUnrecognisedGroupingSlug, failed: caught error: "DecodingError.keyNotFound: Key 'statuses' not found in keyed decoding container."
✖ testDecodeReadsGroupingSlug, failed: caught error: "DecodingError.keyNotFound: Key 'statuses' not found in keyed decoding container."
Executed 436 tests, with 8 failures (4 unexpected)
```

`testLoadLegacyBareArrayFileKeepsGroups` passed in that run too — the bare-array fallback was
already catching its own case — so it is a pin on unchanged behaviour, not a watched failure.
Adding the lenient `init(from:)` turned all of the above green with no other edit.

**Deviations from the plan**

None in the implementation. The plan named six acceptance criteria and no test for the legacy
bare-array fallback; `testLoadLegacyBareArrayFileKeepsGroups` was added anyway, because the
criterion "the existing legacy bare-array fallback … behaviours are unchanged" had nothing pinning
it in this file.

**Gate**

`./scripts/ci.sh` — green after the last edit. `Executed 436 tests, with 0 failures (0 unexpected)`,
`==> CI passed.` `swiftlint lint --quiet` — exit 0, no output. `git status --porcelain` — only the
two files above plus this build log; no untracked files.
