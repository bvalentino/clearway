# Worktrees with Status

**Date:** 2026-09-17
**Base:** c19e44ac9f624e305bbe4e72e0cefdcfceb553de

Groups give the sidebar one axis of organisation, but the thing an operator tracks per worktree is
a workflow state — todo, in progress, in review, done, on hold — which groups model badly. This
change adds an optional status to every non-main worktree, persisted per project beside the
groups, and lets the sidebar be grouped by group (today's view), grouped by status, or shown as
one flat list. Where the sidebar is not already sectioned by status, a row's status shows as a
coloured badge next to its name.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What are the statuses? | A fixed, non-customisable list: Todo, In progress, In review, Done, On hold. A worktree may also have none, which is the default. | Operator |
| 2 | Where does status live? | Per project, in the project's `.clearway` data, keyed by worktree the way groups are, independent of `TASK.md`'s `status` frontmatter. | Operator |
| 3 | Does the main worktree get a status? | No. It has no status and no Status submenu. | Operator |
| 4 | How is status changed? | Two ways: drag a row onto a status section header (by-status view only; dropping on the Worktrees header clears it), and a Status submenu in the worktree row's context menu, available in every view. No manual reorder within a status section. | Operator |
| 5 | How is the view mode chosen and remembered? | From a "Group by" control in the sidebar's worktree-settings gear next to the Worktrees header. Remembered per project. | Operator |
| 6 | What colours? | Todo gray, In progress blue, In review purple, Done green, On hold orange — SwiftUI system colours, never hex. | Operator |
| 7 | What does the by-status view render? | The Worktrees section first, then all five status sections in the fixed order Todo, In progress, In review, Done, On hold — present even when empty. | Operator |
| 8 | One file or two under `.clearway`? | One: `groups.json`'s `WorktreeGroupsPayload` (`WorktreeGroupStore.swift:8-13`) widens to carry `statuses` and `grouping`. A second file would need a second store, a second `DispatchSource` watcher pair and a second reconcile path for state that is written by the same drags and read by the same view. The file name stays `groups.json`; renaming it would need a migration for no user-visible gain. | Spec author |
| 9 | How do the new payload fields avoid breaking an existing `groups.json`? | With a hand-written `init(from:)` that reads both new keys through `decodeIfPresent` and defaults them. This is load-bearing, not defensive: the synthesised initialiser throws `keyNotFound` on a file written before this change, the `[WorktreeGroup]` legacy fallback (`WorktreeGroupStore.swift:67`) would then also throw, and `load()` would log "corrupt" and return `.empty` (`WorktreeGroupStore.swift:70-71`) — silently wiping every existing project's groups and order. A test pins the old wire format's literal bytes. | Spec author |
| 10 | What happens to a status slug the app does not recognise? | It is dropped at load. `statuses` decodes as `[String: String]` and maps through `WorktreeStatus(rawValue:)`, so one bad entry cannot throw the whole dictionary. The list is fixed and custom statuses are out of scope, so there is no forward-compatibility case to preserve — unlike `SettingsManager.openInApps`, where a rename throws the whole array and losing it is unrecoverable. | Spec author |
| 11 | How does the order stay consistent across the three views? | One ordering function, then a partition. `.group` is today's order (default section, then each group). `.none` is that same list, rendered under one header. `.status` is that same list stably partitioned into six buckets — no status, then the five statuses in fixed order. So a status section's rows keep their default/group relative order for free, and `⌘1…9` and the `⌘N` badge read one list per mode. | Spec author |
| 12 | Where does the view mode parameter go? | `WorktreeGroupManager.sidebarOrderedWorktrees` gains a `grouping:` parameter; both callers (`SidebarView.swift:44,67` and `ContentView.swift:464`) pass `groupManager.grouping`. Keeping it a parameter rather than reading the published property inside keeps the function pure over its inputs, which is what the existing tests exercise. | Spec author |
| 13 | Is `WorktreeGroupManager` renamed now that it owns statuses? | No. The rename touches ~10 call sites across `ProjectWindow`, `ContentView`, `SidebarView`, `SidebarSheets`, `ClearwayApp` and the tests, for no user-visible effect. Same reasoning as the primary-badge spec's decision 7. | Spec author |
| 14 | Is the gear a button or a menu? | It becomes a `Menu`: an inline `Picker` titled "Group by" with Group / Status / None, then a "Worktree Settings…" item that opens the existing `WorktreeSettingsSheet` unchanged. Today it is a `SidebarHeaderButton` that opens the sheet directly (`SidebarView.swift:276-278`). `GroupSectionHeader` already shows the borderless-menu-in-a-sidebar-header shape this copies (`SidebarView.swift:562-575`). | Spec author |
| 15 | How is the Status submenu drawn? | `Menu("Status")` wrapping an inline `Picker` bound to `WorktreeStatus?`, with a "None" row tagged `WorktreeStatus?.none` and one row per case. A picker gives the native checkmark on the current value; six plain `Button`s would not. | Spec author |
| 16 | What does the badge look like? | The `PrimaryBadge` shape (`SidebarView.swift:537-547`): the status name in lowercase, `.caption2`, `.fixedSize()`, in a `Capsule()`. Foreground is the status colour, background the same colour at `opacity(0.15)`. It occupies the same slot in `WorktreeRow` as the primary badge, which main can never contest (decision 3). | Spec author |
| 17 | Do status sections hide while searching? | Yes, on exactly the rule groups already follow: a section with zero matches is hidden only while a search is active (`SidebarView.swift:300`). Decision 7's "even when empty" governs the unfiltered view; leaving five empty headers under a query would bury the matches. | Spec author |
| 18 | What can be reordered and dragged in each view? | `.group`: unchanged — rows drag between sections and `.onMove` reorders within one. `.status`: rows drag onto section headers, `.onMove` is disabled (decision 4). `.none`: rows are not draggable and the header is not a drop target — a drop there would silently mutate group membership the view does not show. | Spec author |
| 19 | Does the Worktrees header's drop clear the group or the status? | Whichever the current view sections by: the group in `.group` (unchanged), the status in `.status`. It never clears both — a drag expresses one intent, and the other axis stays where the user put it. | Spec author |
| 20 | How is "search matches the status name" made testable? | The row predicate moves out of the `SidebarView.orderedWorktrees` closure (`SidebarView.swift:48-60`) onto `WorktreeGroupManager` as `matches(_:query:taskTitle:)`. Nothing in a SwiftUI `View` body is reachable from XCTest, and this is the same lift `TerminalManager.revealSecondaryForHook` and `AgentLaunch` make for their decision rules. | Spec author |
| 21 | Does `SidebarView.swift` get split? | Yes, before the feature lands. It is 676 lines against SwiftLint's 700-line `file_length` warning, and this change adds a menu, a section builder and a submenu. `WorktreeRow`, `ShortcutBadge`, `PrimaryBadge` and the new `StatusBadge` move to `Sources/App/WorktreeRow.swift`; `ShortcutBadge` loses `private` because `SidebarView.destinationRow` (`SidebarView.swift:214`) still uses it. No new `swiftlint:disable`. | Spec author |
| 22 | Is a removed worktree's status pruned? | Yes, in `WorktreeGroupManager.reconcile(knownWorktreeIds:)` (`WorktreeGroupManager.swift:157-174`) alongside `groups` and `defaultOrder`, so the one caller (`ContentView.swift:338`) and its empty-refresh guard (`ContentView.swift:337`) cover statuses too. | Spec author |
| 23 | Does the view mode get a menu command or keyboard shortcut? | No, so `AppKeyboardShortcuts` is untouched. | Operator |

## Assumptions

Each verified by reading the codebase at base `c19e44a`. No probe scripts or temporary files were
written — into the repo or the scratchpad; nothing here needed an empirical probe.

1. **A worktree's identity is its path, and that is the key groups already use.**
   `Worktree.id` is `path ?? branch ?? ""` (`Worktree.swift:19`), and `WorktreeGroup.worktreeIds`
   and `WorktreeGroupsPayload.defaultOrder` store exactly that string
   (`WorktreeGroupManager.swift:88,92`). Statuses key the same way, so "keyed like groups" needs
   no new identifier.
2. **Adding a non-optional field to `WorktreeGroupsPayload` would destroy existing group data.**
   `load()` tries `WorktreeGroupsPayload`, then the legacy `[WorktreeGroup]`, then resets to
   `.empty` with a warning (`WorktreeGroupStore.swift:64-71`). A synthesised `Decodable` throws
   `keyNotFound` for an absent key on a non-optional property, so both attempts would fail on
   every existing file. Decision 9 is the mitigation.
3. **The main worktree can never be dragged, so it can never be dropped into a status section.**
   `worktreeRowView` applies `.draggableIf(!wt.isMain, …)` (`SidebarView.swift:427`), and
   `addWorktree` already returns early for main (`WorktreeGroupManager.swift:74`). `setStatus`
   mirrors that guard rather than relying on the view.
4. **An empty `Section` keeps its header in the sidebar list.** `groupSection` deliberately renders
   empty groups and only hides one under an active filter (`SidebarView.swift:299-300`), which is
   shipped behaviour, so the five always-present status sections need no extra mechanism.
5. **`⌘1…9` and the `⌘N` badge already read one shared ordering.** `ContentView.sortedWorktrees`
   (`ContentView.swift:463-469`) and `SidebarView.sortedWorktrees` (`SidebarView.swift:66-72`)
   both call `sidebarOrderedWorktrees` with `matches: { _ in true }`, and the badge index comes
   from `shortcutIndex(for:)` over that list (`SidebarView.swift:385-388`). Threading `grouping:`
   through that one function therefore makes both follow the view mode.
6. **Visibility filtering happens before ordering, so it cannot be bypassed by a new view mode.**
   `sidebarOrderedWorktrees` applies `Worktree.visible(_:showingDetached:openIds:)` on its first
   line (`WorktreeGroupManager.swift:190`, `Worktree.swift:37-42`). A status partition applied to
   its output inherits the detached-worktree rule.
7. **External edits to the project's `.clearway` data already reload without a restart.**
   `WorktreeGroupManager.init` calls `store.startWatching` and re-reads the payload on every fire
   (`WorktreeGroupManager.swift:28-38`), comparing before assigning. Statuses and grouping ride
   that same reload.
8. **The store's durability shape is already what the brief asks for.** `save` writes a
   `0o600` temp file into a `0o700` `.clearway` directory and `replaceItemAt`s it into place
   (`WorktreeGroupStore.swift:88-98`). Nothing about it changes.
9. **`Color.gray/.blue/.purple/.green/.orange` are adaptive system colours available on the
   deployment target.** `project.yml` sets `MACOSX_DEPLOYMENT_TARGET: "13.0"`; these are SwiftUI
   colours from macOS 10.15. No hierarchical-colour API (macOS 14+) is used.
10. **`SidebarView.swift` is linted and close to the file-length warning.** `.swiftlint.yml`
    excludes only `Sources/Ghostty` and sets `file_length` warning 700 / error 1000; the file is
    676 lines. Decision 21 is what keeps the change from introducing a warning.
11. **A new Swift file is invisible to the build until `xcodegen generate` runs.** `project.yml`
    globs `Sources` and `Tests` by path, and `./scripts/ci.sh` regenerates the project, which is
    why it is the only verification command here.
12. **`WorktreeGroupManager` is constructed per project window and injected as an
    `@EnvironmentObject`.** `ProjectWindow.swift:91,114-115`. Per-project persistence needs no new
    plumbing; the manager already knows its `projectPath`.

## Objective

An operator can see, at a glance and without opening anything, which worktrees are waiting, being
worked, in review, done or parked — and can re-file one in two gestures — while keeping groups for
the orthogonal thing groups are good at.

### Success criteria

1. Right-clicking a non-main worktree row in any view shows a Status submenu with the five values
   and None; choosing one sets it, and in the by-group and none views the row shows the matching
   badge.
2. The main worktree's row never shows a status badge and its context menu has no Status submenu.
3. The gear's "Group by → Status" renders the Worktrees section then Todo, In progress, In review,
   Done and On hold, all present when unfiltered even if empty, with no status badge on any row.
4. Dragging a row onto a status section header in the by-status view sets that status; dropping on
   the Worktrees header clears it. Dragging between groups in the by-group view is unchanged.
5. "Group by → None" shows one flat list with main first; no worktree is lost or duplicated, and
   switching back to Group restores the same groups.
6. The view mode survives relaunch per project, and a project with no stored value opens by group.
7. Statuses survive relaunch, and an external edit to the project's `.clearway` data is reflected
   without restarting.
8. A `groups.json` written before this change still loads its groups and default order.
9. A worktree that no longer exists is pruned from the status map the way it is pruned from groups.
10. `⌘N` badges and `⌘1…9` match the visual order in every view mode, and worktrees hidden by
    Settings → Appearance → Show detached worktrees stay hidden in every view mode.
11. Searching "review" matches worktrees whose status is In review.
12. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports no new warnings or errors.

### Test coverage this requires

Criteria 1–5 and 10's badge rendering are SwiftUI view state and are confirmed by hand in the
running app. Everything else is pinned by XCTest:

- Ordering in each of the three modes, including a status section's rows keeping their
  default/group relative order (`WorktreeGroupManagerTests`).
- The by-status order with a hidden detached worktree and a closed worktree present.
- `setStatus` round-trips through the store and is ignored for the main worktree.
- `reconcile` prunes a vanished worktree's status.
- The pre-change `groups.json` wire format decodes to its groups and order with an empty status
  map and `.group` grouping — asserted over literal bytes, not a round trip
  (`WorktreeGroupStoreTests`), for the reason CLAUDE.md records for `OpenInAppTests`.
- An unrecognised status slug is dropped without losing the rest of the map.
- `matches(_:query:taskTitle:)` returns true for a status-name query and keeps its existing
  branch-name, task-title and group-name behaviour.

## Verification

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds and runs the test suite — the regression check for
every build task and the full gate at sign-off, per CLAUDE.md's `## Pipeline` section. It is the
only test runner; do not hand-write an `xcodebuild` line. New Swift files make `xcodegen generate`
mandatory, which is another reason nothing else will do.

The view-only criteria are confirmed against the running app (`./scripts/run.sh`), on a project
with at least one group, one ungrouped worktree and one detached worktree. Expect the
un-gitignored `default.profraw` in the repo root after any Debug launch; report it before sign-off
and never `git add -A`.

## Files touched

| File | Change |
| --- | --- |
| `Sources/App/WorktreeStatus.swift` (new) | `WorktreeStatus` (five cases, raw value, display name, colour) and `WorktreeGrouping` (`group`, `status`, `none`; never used as an `Optional`). |
| `Sources/App/WorktreeRow.swift` (new) | `WorktreeRow`, `ShortcutBadge`, `PrimaryBadge` moved out of `SidebarView.swift`, plus the new `StatusBadge`; `WorktreeRow` gains a `status` input. |
| `Sources/App/WorktreeGroupStore.swift` | `WorktreeGroupsPayload` gains `statuses` and `grouping` with a hand-written lenient `init(from:)` (decisions 9, 10). |
| `Sources/App/WorktreeGroupManager.swift` | Published `statuses` / `grouping`, `setStatus`, `setGrouping`, `status(for:)`, `matches(_:query:taskTitle:)`, `grouping:` on `sidebarOrderedWorktrees`, status pruning in `reconcile`, both persisted through the existing `save()`. |
| `Sources/App/SidebarView.swift` | Gear becomes a menu with the Group by picker; sections are built per view mode; the Status submenu joins the row context menu; header drops and drag/move gating follow decisions 18 and 19. Shrinks by the rows moved to `WorktreeRow.swift`. |
| `Sources/App/ContentView.swift` | Passes `grouping:` to `sidebarOrderedWorktrees` so `⌘1…9` follow the view mode. |
| `Tests/WorktreeGroupManagerTests.swift` | Ordering per mode, status round-trip, main-is-ignored, pruning, search predicate. |
| `Tests/WorktreeGroupStoreTests.swift` | Old wire format decodes; unknown slug is dropped. |
| `docs/superpowers/specs/2026-09-17-worktrees-with-status.md` | This document. |
| `docs/superpowers/plans/2026-09-17-worktrees-with-status.md` | The plan, written by the next stage. |

## Out of scope

- Custom, renamed or reordered statuses, and custom colours (decision 1).
- Any automatic status change — starting a task, opening a PR, merging or closing a worktree
  changes nothing.
- Any coupling to `TASK.md`'s `status` frontmatter, which CLAUDE.md records as written but never
  rendered.
- Filtering or hiding worktrees by status, including hiding Done.
- Status anywhere but the sidebar: no toolbar, task window or window-title surface.
- A View-menu command or keyboard shortcut for the view mode; `AppKeyboardShortcuts` is untouched
  (decision 23).
- Any change to groups' behaviour, to the on-disk shape of existing group data, or to the existing
  group context menus.
- Manual reorder inside a status section, and reorder in the none view (decisions 4, 18).
- Renaming `WorktreeGroupManager`, `WorktreeGroupStore` or `groups.json` (decisions 8, 13).
- The known `WorktreeGroupStore.openFileWatcher` fd leak recorded in CLAUDE.md; unrelated and owed
  its own task.
