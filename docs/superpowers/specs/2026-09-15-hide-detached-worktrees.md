# Hide Detached Worktrees

**Date:** 2026-09-15
**Base:** d94b0b0f879606872a8b1a92e2f38ac144914339

Subagents create short-lived worktrees with a bare detached HEAD. Clearway lists every worktree
`git worktree list --porcelain` reports, so those arrive in the sidebar as rows labelled
"(detached)" with no indication of where they came from, and they leave when the subagent does.
This change hides a bare-detached worktree from the sidebar by default and adds one Settings
checkbox to bring them back. A worktree that is detached because a rebase or bisect is in progress
is never hidden — the user is mid-operation on real work — and neither is one whose terminals are
currently open.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Is the default to show or hide detached worktrees? | Hidden. The Settings checkbox opts **in** to showing them, for when something looks wrong. | Operator |
| 2 | Does a detached worktree the user has open disappear when the toggle is off? | No. A detached worktree whose id is in `TerminalManager.openWorktreeIds` stays visible regardless of the toggle; it is hidden only while it has no open terminals. Nothing the user is actively working in vanishes, while stray subagent worktrees they never opened stay hidden. | Operator |
| 3 | Is any path heuristic used to identify subagent worktrees? | No. The signal is `headStatus == .detached` and nothing else — no matching on Claude Code's worktree directory or any other path shape. | Operator |
| 4 | Which `HeadStatus` values can be hidden? | Only `.detached`. `.rebasing` and `.bisecting` are always shown. This needs no extra guard: `applyHeadResolution` already rewrites a mid-rebase/mid-bisect entry to `.rebasing`/`.bisecting` with its recovered branch name before the list reaches any view (`Worktree.swift:302-314`), so `.detached` at render time means a bare detached HEAD. | Operator |
| 5 | Is the main worktree ever hidden? | No — main is exempt unconditionally, even if its HEAD is detached. `ContentView` treats main as the guaranteed selection fallback (`ContentView.swift:629-630`) and `TerminalManager.isOpen` reports it open by definition (`TerminalManager.swift:466-467`); a hidden main row would leave the window with a selection it cannot render. | Spec author |
| 6 | Where does the filter live? | A pure static helper on `Worktree` — `Worktree.visible(_:showingDetached:openIds:)` — applied to the `worktrees` argument at each of the three sites that build a sidebar-ordered list. Keeping it pure and static is what makes it testable, matching the split the project already makes for untestable view code (CLAUDE.md, `Ghostty.SurfaceView`/`revealSecondaryForHook`). Putting the rule inside `WorktreeGroupManager.sidebarOrderedWorktrees` was rejected: that type owns grouping and order, not visibility policy, and its existing `matches` closure is the search predicate. | Spec author |
| 7 | Which call sites get the filter? | All three, or the ⌘N badge and the ⌘N shortcut disagree: `SidebarView.orderedWorktrees` (`:41-60`, the rendered rows), `SidebarView.sortedWorktrees` (`:64-70`, feeds `shortcutIndex`), and `ContentView.sortedWorktrees` (`:445-452`, feeds the hidden ⌘1…9 buttons at `:344-358`). | Spec author |
| 8 | Do hidden worktrees still reach `seedDefaultOrder` / `reconcile` / `pruneStale`? | Yes — those keep taking the unfiltered list (`ContentView.swift:318-327`). Persisted order is display *order*, not display *membership*, so seeding a hidden id costs nothing and means a worktree that later becomes visible already has a stable position. Self-healing: `reconcile` prunes `defaultOrder` against the live id set (`WorktreeGroupManager.swift:164-170`), so a subagent worktree's id leaves the store when the worktree does. | Spec author |
| 9 | Where in Settings does the checkbox go? | The existing `Section("Appearance")` (`SettingsView.swift:21-30`), below the two toggles already there. That section is already the app's behaviour-toggle section — "Open secondary terminal on start" is not appearance either — so a new one-row "Sidebar" section would add structure without adding clarity. | Spec author |
| 10 | What does the checkbox say? | `Toggle("Show detached worktrees", isOn: $settings.showDetachedWorktrees)`. One label, no footer or helper text, per the project's UI-copy rule. | Spec author |
| 11 | How is the preference stored? | `SettingsManager.showDetachedWorktrees`, a `@Published var` with a `didSet` writing `UserDefaults` under `SettingsKey.showDetachedWorktrees = "clearway.showDetachedWorktrees"`, read back in `init` as `defaults.object(forKey:) as? Bool ?? false`. Identical in shape to `openSecondaryOnStart` (`SettingsManager.swift:9, 77-81, 106`). | Spec author |
| 12 | Is the hidden count surfaced anywhere? | No. No badge, no "N hidden" row, no log line. The toggle is the whole affordance. | Spec author |

## Assumptions

Each verified against the codebase at base `d94b0b0`.

1. **`HeadStatus` already distinguishes the four states and needs no change.**
   `enum HeadStatus { case attached, rebasing, bisecting, detached }`
   (`Sources/App/Worktree.swift:6-11`). The parser only ever emits `.attached` or `.detached`
   (`:257`); `applyHeadResolution` (`:302-314`) upgrades a `.detached` entry to `.rebasing` or
   `.bisecting` via `branchFromInProgressOp` (`:282-300`), which reads
   `rebase-merge/head-name`, `rebase-apply/head-name` and `BISECT_START` from the worktree's
   gitdir. `fetchWorktrees` runs the resolver on every refresh (`:316-321`), so no view ever sees
   an unresolved mid-operation worktree. Pinned by
   `WorktreeTests.testParserAndResolverPipelineRecoversRebasingBranch` (`Tests/WorktreeTests.swift:265`).

2. **"(detached)" is only ever rendered for `headStatus == .detached`.**
   `displayName` is `branch ?? "(detached)"` (`Worktree.swift:22`) and the parser nils out `branch`
   exactly when the `detached` line is present (`:256-257`). A recovered rebase/bisect entry is
   rebuilt with the recovered branch name (`:307-312`), so it renders its branch, not "(detached)".

3. **Open worktrees are tracked by id in one published array.**
   `TerminalManager.openWorktreeIds: [String]` (`Sources/App/TerminalManager.swift:25`), with
   `isOpen(_:)` = `worktree.isMain || openWorktreeIds.contains(worktree.id)` (`:466-467`). A
   detached worktree's `id` is its path (`Worktree.swift:15`, `branch` being nil), which is the
   same key `TerminalManager` stores, so the openIds lookup works for detached entries.

4. **The sidebar rows and the ⌘N shortcuts are built from three separate expressions over the
   same source.** `SidebarView.orderedWorktrees` (`:41-60`) → the two section row lists
   (`:213`, `:289`); `SidebarView.sortedWorktrees` (`:64-70`) → `shortcutIndex(for:)` (`:372-375`)
   → the row badge (`:398`, `:409`); `ContentView.sortedWorktrees` (`:445-452`) → the hidden ⌘1…9 buttons
   (`:344-358`). All three call `WorktreeGroupManager.sidebarOrderedWorktrees(_:openIds:matches:)`
   (`WorktreeGroupManager.swift:181-218`) with `worktreeManager.worktrees`. Filtering that argument
   at each site is therefore sufficient and keeps badge and shortcut in agreement.

5. **A selected worktree is always open or main, so hiding cannot orphan the selection.**
   `ContentView.onChange(of: terminalManager.openWorktreeIds)` calls `selectFallback()` whenever
   the selected non-main worktree leaves `openWorktreeIds` (`:335-341`), and `selectFallback`
   itself only restores a previous worktree selection when `fresh.isMain ||
   openWorktreeIds.contains(fresh.id)` (`:614-626`). Combined with Decision 2, a visible-because-open
   detached worktree stays selectable, and one that closes is deselected by the existing path
   before it is hidden.

6. **`SettingsManager` is an app-wide environment object reachable from both views that need it.**
   `@StateObject private var settings: SettingsManager` in `ClearwayApp` (`:128`), injected by
   `clearwayChrome(_:)` via `environmentObject(settings)` (`:241-242`). `ContentView` already reads
   it as `@EnvironmentObject private var settings: SettingsManager` (`:60`); `SidebarView` renders
   inside `ContentView` and will declare the same property.

7. **`SettingsView` takes the manager directly and has an Appearance section of plain toggles.**
   `@ObservedObject var settings: SettingsManager` (`SettingsView.swift:4`), `Section("Appearance")`
   containing the colour-scheme picker plus two `Toggle`s (`:21-30`). One more `Toggle` fits with no
   restructuring; the form is a fixed `frame(width: 450, height: 420)` (`:47`) with room for the row.

8. **Persisted sidebar order tolerates ids for worktrees that are not rendered.**
   `seedDefaultOrder` appends any non-main, ungrouped worktree missing from `defaultOrder`
   (`WorktreeGroupManager.swift:125-135`); `sidebarOrderedWorktrees` renders from the intersection of
   `defaultOrder` and the list it is handed (`:190-200`), so an id with no matching worktree in the
   filtered list simply produces nothing. `reconcile(knownWorktreeIds:)` prunes both group membership
   and `defaultOrder` (`:154-176`), and `ContentView` calls it with the *unfiltered* live id set
   (`:322-323`), so filtering the render path cannot cause stale ids to accumulate.

9. **`SettingsManager` is unit-testable against an injected `UserDefaults` suite.**
   `init(defaults: UserDefaults = .standard)` (`SettingsManager.swift:102`), and
   `SettingsManagerTests` builds a per-test suite name and tears down the persistent domain
   (`Tests/SettingsManagerTests.swift:10-23`). The default/round-trip/turn-back-off trio already
   exists for `openSecondaryOnStart` (`:86-105`) and is the template for the new preference.

No empirical probing was needed; nothing was written to the repo or the scratchpad during this stage.

## Objective

A user running subagents sees only the worktrees they care about. Bare-detached worktrees — the
shape a subagent's temporary worktree takes — are absent from the sidebar unless the user has opened
them or has ticked one Settings checkbox to see them.

## Success criteria

1. With `showDetachedWorktrees` off (the default), a worktree with `headStatus == .detached`, not
   main, and whose id is absent from `openWorktreeIds` does not appear in the sidebar, is not
   assigned a ⌘N badge, and is not targeted by any ⌘1…9 shortcut.
2. With the toggle off, a worktree with `headStatus == .rebasing` or `.bisecting` appears exactly as
   it does today.
3. With the toggle off, a `.detached` worktree whose id is in `openWorktreeIds` appears; it
   disappears once its last terminal closes, without a manual refresh.
4. The main worktree always appears, whatever its `headStatus` and whatever the toggle.
5. With the toggle on, the sidebar list is identical to today's.
6. The sidebar row list and the ⌘1…9 targets are drawn from the same filtered sequence, so the badge
   on a row and the shortcut that selects it never disagree.
7. Settings → Appearance shows one new checkbox, "Show detached worktrees", off on first launch,
   persisted across app restarts.
8. `./scripts/ci.sh` passes.

## Verification

Both the per-task regression check and the sign-off gate are the same command (CLAUDE.md,
`## Pipeline`):

```bash
./scripts/ci.sh
```

It runs `xcodegen generate`, SwiftLint, the build and the test suite. New Swift files are invisible
to the build until `xcodegen generate` runs, so no hand-written `xcodebuild` line substitutes for it.

Before any CI stamp or sign-off, run `git status --porcelain` and report untracked or ignored files.
Expect an un-gitignored `default.profraw` in the repo root after any Debug launch.

## Testing strategy

XCTest, one file per unit under test, in `Tests/`. The new behaviour is a pure function plus a
persisted preference, so both are covered directly and no view is instantiated.

- `Tests/WorktreeTests.swift` — `Worktree.visible(_:showingDetached:openIds:)`: hides a non-main
  `.detached` worktree with no open id; keeps `.rebasing`; keeps `.bisecting`; keeps `.detached` when
  its id is in `openIds`; keeps main when main is `.detached`; passes the whole list through when
  `showingDetached` is true; keeps `.attached` worktrees in every combination. Ordering is
  `Worktree.sorted`'s concern and stays pinned by the existing tests (`:131-170`).
- `Tests/SettingsManagerTests.swift` — `showDetachedWorktrees` defaults to false, persists across
  instances, and can be turned back off, mirroring the `openSecondaryOnStart` trio (`:86-105`).

## Files this change touches

| File | Change |
| --- | --- |
| `Sources/App/Worktree.swift` | Add `static func visible(_:showingDetached:openIds:) -> [Worktree]` beside `sorted(_:openIds:)`. |
| `Sources/App/SettingsManager.swift` | Add `SettingsKey.showDetachedWorktrees`, the `@Published var` with its `didSet`, and the `init` read defaulting to `false`. |
| `Sources/App/SettingsView.swift` | Add the `Toggle` to `Section("Appearance")`. |
| `Sources/App/SidebarView.swift` | Add `@EnvironmentObject private var settings: SettingsManager`; filter the `worktrees` argument in `orderedWorktrees` and `sortedWorktrees`. |
| `Sources/App/ContentView.swift` | Filter the `worktrees` argument in `sortedWorktrees`. |
| `Tests/WorktreeTests.swift` | Tests for the new helper. |
| `Tests/SettingsManagerTests.swift` | Tests for the new preference. |
| `CLAUDE.md` | Note the visibility rule where the sidebar/worktree behaviour is described, if the build stage finds the existing text now misleading. |

No file is added, so the change is visible to the build without a `project.yml` edit — but `ci.sh`
runs `xcodegen generate` regardless.

## Out of scope

- Any path or provenance heuristic for identifying subagent worktrees (Decision 3).
- Hiding, warning about, or cleaning up the worktrees themselves. Clearway continues to list, watch
  and prune exactly what git reports; only the sidebar's rendering changes.
- `ClaudeActivityMonitor.updateWorktrees` (`ContentView.swift:319`, `:375`), `syncWatchedWorktrees`,
  `TerminalManager.pruneStale` and `WorktreeManager.prunePRStatuses` keep receiving the unfiltered
  list. Hiding a row is a display rule, not a change to what the app tracks.
- A per-project or per-window variant of the preference. It is a single process-wide `UserDefaults`
  value like every other entry in `SettingsManager`.
- `WorktreeGroupStore.openFileWatcher`'s known fd leak (CLAUDE.md) — unrelated, and it has its own
  task.
- Showing the hidden count or any other new sidebar affordance (Decision 12).
