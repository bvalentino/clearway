# Plan: Hide Detached Worktrees

**Date:** 2026-09-15
**Base:** d94b0b0f879606872a8b1a92e2f38ac144914339

Breaks down `docs/superpowers/specs/2026-09-15-hide-detached-worktrees.md`. Every design decision is
settled there; read it before starting a task, and read this file for what your task is and how it is
checked.

## Architecture decisions carried from the spec

1. **Hidden by default.** The Settings checkbox opts *in* to showing bare-detached worktrees.
   (Decision 1)
2. **The signal is `headStatus == .detached` and nothing else.** No path matching, no provenance
   heuristic, no Claude-Code directory shape. (Decision 3)
3. **`.rebasing` and `.bisecting` are never hidden, and need no extra guard.**
   `applyHeadResolution` (`Worktree.swift:302-314`) has already rewritten a mid-rebase/mid-bisect
   entry to `.rebasing`/`.bisecting` with its recovered branch name before any view sees the list, so
   `.detached` at render time already means a bare detached HEAD. (Decision 4)
4. **Main is exempt unconditionally**, whatever its `headStatus`. `ContentView` uses main as the
   guaranteed selection fallback and `TerminalManager.isOpen` reports it open by definition; a hidden
   main row would leave the window with a selection it cannot render. (Decision 5)
5. **A `.detached` worktree whose id is in `TerminalManager.openWorktreeIds` stays visible**
   regardless of the toggle. Nothing the user is working in vanishes. (Decision 2)
6. **The rule is a pure static helper on `Worktree`** — `Worktree.visible(_:showingDetached:openIds:)`
   — applied to the `worktrees` *argument* at each call site. Not inside
   `WorktreeGroupManager.sidebarOrderedWorktrees`: that type owns grouping and order, not visibility
   policy, and its `matches` closure is the search predicate. Pure and static is what makes it
   testable, matching the split the project already makes for untestable view code. (Decision 6)
7. **All three call sites get the filter, or the ⌘N badge and the ⌘N shortcut disagree:**
   `SidebarView.orderedWorktrees`, `SidebarView.sortedWorktrees`, `ContentView.sortedWorktrees`.
   (Decision 7)
8. **Hidden worktrees still reach everything that is not rendering.** `seedDefaultOrder`,
   `reconcile`, `pruneStale`, `ClaudeActivityMonitor.updateWorktrees`, `syncWatchedWorktrees` and
   `prunePRStatuses` keep taking the *unfiltered* list. Persisted order is display order, not display
   membership, and `reconcile` self-heals against the live id set. Hiding a row is a display rule, not
   a change to what the app tracks. (Decision 8, Out of scope)
9. **One preference, process-wide.** `SettingsManager.showDetachedWorktrees`, identical in shape to
   `openSecondaryOnStart`. No per-project or per-window variant. (Decision 11, Out of scope)
10. **One label, no helper text.** `Toggle("Show detached worktrees", isOn:)` in the existing
    `Section("Appearance")`, below the two toggles already there. No new section, no footer.
    (Decisions 9, 10)
11. **Nothing surfaces the hidden count.** No badge, no "N hidden" row, no log line. The toggle is
    the whole affordance. (Decision 12)
12. **No new file, so `project.yml` is not edited.** `ci.sh` runs `xcodegen generate` regardless.

## Regression check

Every task's check is the project's one runner (CLAUDE.md, `## Pipeline`):

```bash
./scripts/ci.sh
```

It runs `xcodegen generate`, SwiftLint, the build and the full test suite. Do not hand-write an
`xcodebuild` line: `build.sh`'s `PRODUCT_NAME` override breaks `TEST_HOST`.

## Dependency graph

```
T1 (Worktree.visible + its tests)            ──┐
                                               ├──> T3 (wire the filter at the three
T2 (showDetachedWorktrees + Settings row)    ──┘        call sites + CLAUDE.md note)
```

T1 and T2 touch disjoint files and can run in either order or in parallel. T3 needs both: it calls
`Worktree.visible` (T1) and reads `settings.showDetachedWorktrees` (T2), and it does not compile
until both exist.

**Checkpoint after T1 and T2:** `./scripts/ci.sh` exit 0. The app builds and behaves exactly as at
base — the helper has no caller and the new checkbox changes nothing yet. That is expected, not a
defect.

**Checkpoint after T3:** `./scripts/ci.sh` exit 0, and spec success criteria 1–7 hold.

## Tasks

### T1: `Worktree.visible` filter helper

**Files (2)**

- `Sources/App/Worktree.swift`
- `Tests/WorktreeTests.swift`

**What it does**

Add one pure static function beside `sorted(_:openIds:)` in the `Worktree` struct
(`Worktree.swift:28-38`):

```swift
static func visible(_ worktrees: [Worktree], showingDetached: Bool, openIds: [String]) -> [Worktree]
```

When `showingDetached` is true, return `worktrees` unchanged. Otherwise drop every entry that is all
three of: `headStatus == .detached`, `!isMain`, and `id` absent from `openIds`. Every other entry is
kept, including `.attached`, `.rebasing` and `.bisecting`.

Keep the input order: this is a filter, not a sort. Ordering stays `sorted`'s and
`sidebarOrderedWorktrees`' concern, and preserving order is what lets T3 drop the call in front of
`sidebarOrderedWorktrees` without disturbing it.

Use `openIds.contains(...)` directly. Do not build a `Set` or any other index — the list is tens of
entries and its callers already sort the same data.

Write no comment restating the three conditions; the code says them. A one-line doc comment naming
the rule, in the style of the one above `sorted`, is the only prose this needs.

**Acceptance criteria**

New tests in `Tests/WorktreeTests.swift`, under a `// MARK: - Visibility` heading placed after the
existing `// MARK: - Sorting` block, using the existing `makeWorktree(branch:path:isMain:headStatus:)`
helper (`Tests/TestHelpers.swift:4-16`):

1. A non-main `.detached` worktree with no matching open id is dropped when `showingDetached` is
   false.
2. A `.rebasing` worktree is kept when `showingDetached` is false.
3. A `.bisecting` worktree is kept when `showingDetached` is false.
4. A non-main `.detached` worktree whose `id` is in `openIds` is kept when `showingDetached` is false.
5. A `.detached` worktree with `isMain: true` is kept when `showingDetached` is false.
6. With `showingDetached` true, the whole list passes through unchanged — assert on the full id
   sequence, so the case also pins that order is preserved.
7. An `.attached` worktree is kept in every combination of `showingDetached` and open/closed.

A `.detached` worktree's `id` is its `path` (`Worktree.swift:15`, `branch` being nil), which is the
key `TerminalManager` stores, so the `openIds` cases must pass the path as the id.

**Verification**

`./scripts/ci.sh` — exit 0, SwiftLint clean, test count up by the new cases with 0 failures. The
existing sorting tests (`WorktreeTests.swift:131-170`) and
`testParserAndResolverPipelineRecoversRebasingBranch` (`:265`) must still pass untouched: this task
adds a function and adds tests, and changes no existing behaviour.

### T2: `showDetachedWorktrees` preference and its Settings row

**Files (3)**

- `Sources/App/SettingsManager.swift`
- `Sources/App/SettingsView.swift`
- `Tests/SettingsManagerTests.swift`

**What it does**

Mirror `openSecondaryOnStart` exactly — it is the template, and deviating from its shape is a defect:

1. `SettingsKey.showDetachedWorktrees = "clearway.showDetachedWorktrees"` in the `SettingsKey` enum
   (`SettingsManager.swift:4-10`).
2. A `@Published var showDetachedWorktrees: Bool` whose `didSet` writes
   `defaults.set(showDetachedWorktrees, forKey: SettingsKey.showDetachedWorktrees)`, placed beside
   the `openSecondaryOnStart` property (`:77-81`).
3. In `init(defaults:)` (`:102-115`), read it back as
   `defaults.object(forKey: SettingsKey.showDetachedWorktrees) as? Bool ?? false`. `object(forKey:) as? Bool`
   rather than `bool(forKey:)` is deliberate and matches the neighbour — it distinguishes unset from
   stored-false, which is what lets the default be stated in one place.
4. In `SettingsView`, add `Toggle("Show detached worktrees", isOn: $settings.showDetachedWorktrees)`
   as the last row of `Section("Appearance")` (`SettingsView.swift:21-30`), below "Open secondary
   terminal on start". No footer, no helper text, no new section. Leave
   `.frame(width: 450, height: 420)` (`:47`) alone — the section has room for the row.

**Acceptance criteria**

Three tests in `Tests/SettingsManagerTests.swift`, under a `// MARK: - Show detached worktrees`
heading, mirroring the `openSecondaryOnStart` trio (`:86-105`) against the per-test injected suite
the fixture already builds (`:10-23`):

1. `showDetachedWorktrees` defaults to `false` on a fresh `SettingsManager(defaults:)`.
2. Setting it to `true` on one instance is visible on a second instance built from the same suite.
3. Setting it `true` then `false` reads back `false` on a second instance.

`SettingsView` must show exactly one new row; nothing else in the form changes.

**Verification**

`./scripts/ci.sh` — exit 0, SwiftLint clean, test count up by three with 0 failures. The three
`openSecondaryOnStart` tests and the colour-scheme tests must still pass: the new key is distinct, so
nothing existing moves.

### T3: Filter the three sidebar-ordered call sites

**Files (3)**

- `Sources/App/SidebarView.swift`
- `Sources/App/ContentView.swift`
- `CLAUDE.md`

**Depends on** T1 and T2. Does not compile without both.

**What it does**

All three sites call `groupManager.sidebarOrderedWorktrees(worktreeManager.worktrees, openIds:)`.
Replace the first argument with the filtered list at each, leaving `openIds` and the `matches`
closure exactly as they are:

```swift
Worktree.visible(
    worktreeManager.worktrees,
    showingDetached: settings.showDetachedWorktrees,
    openIds: terminalManager.openWorktreeIds
)
```

1. `SidebarView` — add `@EnvironmentObject private var settings: SettingsManager` to the existing
   environment-object block (`SidebarView.swift:13-18`). `ClearwayApp` already injects it via
   `clearwayChrome(_:)`'s `environmentObject(settings)`, and `SidebarView` renders inside
   `ContentView`, so no wiring is needed at any call site of `SidebarView`.
2. `SidebarView.orderedWorktrees` (`:41-60`) — the rendered rows. Substitute the argument; the search
   `matches` closure is untouched.
3. `SidebarView.sortedWorktrees` (`:64-70`) — feeds `shortcutIndex(for:)` (`:372-375`) and so the row
   badge (`:398`, `:409`).
4. `ContentView.sortedWorktrees` (`:445-452`) — feeds the hidden ⌘1…9 buttons (`:344-358`).
   `ContentView` already declares `settings` (`:60`); do not add a second property.

**What this task must not touch.** Every other consumer of `worktreeManager.worktrees` keeps the
unfiltered list (decision 8). Specifically leave alone: `seedDefaultOrder` and
`reconcile(knownWorktreeIds:)` (`ContentView.swift:318-327`),
`ClaudeActivityMonitor.updateWorktrees` (`:319`, `:375`), `syncWatchedWorktrees`,
`TerminalManager.pruneStale`, `WorktreeManager.prunePRStatuses`, `ContentView.currentWorktree`
(`:456-459`) and `selectFallback` (`:614-630`). A diff that filters any of these is a defect.

**No reactivity machinery.** Both views hold `terminalManager` and `settings` as
`@EnvironmentObject`, and `openWorktreeIds` and `showDetachedWorktrees` are both `@Published`, so
these computed properties already re-evaluate when a terminal closes or the toggle flips. Adding an
`onChange`, a `@State` mirror or a manual refresh is a defect — success criterion 3's "without a
manual refresh" is satisfied by the existing observation, not by new code.

**CLAUDE.md.** There is no existing sidebar-visibility text to correct — `grep -ni detached CLAUDE.md`
matches only the unrelated dispatch-source note at `:90`. So add, under
`## Architecture` → `Sources/App/`, one short entry recording the invariant a future agent would
otherwise break: that sidebar visibility is `Worktree.visible` applied to the `worktrees` argument at
all three `sidebarOrderedWorktrees` call sites, that filtering only some of them desynchronises the
⌘N badge from the ⌘N shortcut, and that the order/reconcile/watch/prune paths deliberately keep the
unfiltered list. Match the surrounding entries' density. Do not restate the spec.

**Acceptance criteria**

1. `git ls-files -- Sources | xargs grep -n 'sidebarOrderedWorktrees('` returns exactly four lines:
   the declaration in `WorktreeGroupManager.swift:181` and the three call sites, and every one of
   those three passes a `Worktree.visible(` expression as its first argument.
2. `git ls-files -- Sources | xargs grep -c 'Worktree.visible('` totals 3 — two in `SidebarView.swift`,
   one in `ContentView.swift`. No fourth site.
3. `SidebarView.swift` declares `settings` once; `ContentView.swift` still declares it once.
4. Spec success criteria 1–5 confirmed in the running app, once:
   `git worktree add --detach /tmp/clearway-detached-probe HEAD`, then `./scripts/run.sh`. With the
   toggle off the probe row is absent from the sidebar and no ⌘1…9 selects it; opening it (from the
   toggle-on state) keeps it visible and closing its last terminal makes it vanish with no refresh;
   main and any `.rebasing`/`.bisecting` row are unaffected; with the toggle on the list matches base.
   Then `git worktree remove --force /tmp/clearway-detached-probe`, and **delete the
   `default.profraw`** the Debug launch drops in the repo root — it is not gitignored and an untracked
   file blocks sign-off.
5. Spec success criterion 6: the badge and the shortcut are drawn from the same filtered sequence,
   which criterion 1 above proves structurally.

**Verification**

`./scripts/ci.sh` — exit 0, SwiftLint clean, build succeeded, the T1+T2 test count with 0 failures
(this task adds no test: all three edited call sites are inside view types that XCTest cannot reach,
which is exactly why decision 6 lifted the rule into the pure helper T1 tests). Then
`git status --porcelain` — only the files this branch changed, no `default.profraw`.

## Build log

### T1: `Worktree.visible` filter helper

**What landed**

| File | State |
| --- | --- |
| `Sources/App/Worktree.swift` | `static func visible(_:showingDetached:openIds:)` added above `sorted(_:openIds:)`, with a one-line doc comment. Pure filter, input order preserved, `openIds.contains` used directly — no `Set`. |
| `Tests/WorktreeTests.swift` | `// MARK: - Visibility` block after `// MARK: - Sorting`: seven cases covering acceptance criteria 1–7, plus a private `makeDetached(path:isMain:)` wrapper over the shared `makeWorktree` helper. |
| `docs/superpowers/plans/…` / `specs/…` | Untracked on entry; committed with this task. |

**Evidence**

The helper was first landed as a deliberate non-filtering stub (`{ worktrees }`) so the RED was an
assertion failure rather than a compile error. `./scripts/ci.sh` against that stub, exit 65:

```
	WorktreeTests.testVisibilityHidesClosedDetachedWorktree()
    ✖ testVisibilityHidesClosedDetachedWorktree, XCTAssertTrue failed
Executed 313 tests, with 1 failure (0 unexpected) in 34.155 seconds
```

The other six cases pass against the stub by construction — each asserts a worktree is *kept*, which
is what a pass-through does. They pin the conditions the real filter must not over-apply, so they are
guards, not watched failures, and the plan asks for them.

**Deviations**

None in the code. One environment step outside the plan: `ghostty/` was empty in this worktree, so
the first `./scripts/ci.sh` failed with `Unable to resolve module dependency: 'GhosttyKit'`. The
project's own `./scripts/worktree-post-create.sh` had never been run here; running it copied the
submodule from the primary worktree and created `Sources/App/BuildInfo.generated.swift`. No repo
file was hand-edited for this. `Clearway.xcodeproj/project.pbxproj` went briefly dirty because the
failed run's `xcodegen generate` had no `BuildInfo.generated.swift` to include; the next run restored
it and the file is clean again.

**Gate**

`./scripts/ci.sh` — exit 0, SwiftLint clean, build succeeded, `Executed 313 tests, with 0 failures`
(306 at base, +7 from this task). Run after the last edit. `git status --porcelain` shows only
`Sources/App/Worktree.swift`, `Tests/WorktreeTests.swift` and the two untracked doc files this commit
adds; no `default.profraw` (no Debug launch was made).

### T2: `showDetachedWorktrees` preference and its Settings row

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SettingsManager.swift` | `SettingsKey.showDetachedWorktrees = "clearway.showDetachedWorktrees"` added to the enum; `@Published var showDetachedWorktrees: Bool` with a `didSet` write placed directly below `openSecondaryOnStart`; `init(defaults:)` reads it back as `object(forKey:) as? Bool ?? false`. Mirrors `openSecondaryOnStart` line for line. |
| `Sources/App/SettingsView.swift` | One `Toggle("Show detached worktrees", isOn:)` appended to `Section("Appearance")`, below "Open secondary terminal on start". No footer, no helper text, no new section; the `.frame(width: 450, height: 420)` is untouched. |
| `Tests/SettingsManagerTests.swift` | `// MARK: - Show detached worktrees` block with the default / persists-across-instances / turned-back-off trio, against the per-test injected suite. |

**Evidence**

The property was first landed with an empty `didSet`, so the RED was an assertion failure rather than
a compile error. `./scripts/ci.sh` against that stub, exit 65:

```
Test Suite 'SettingsManagerTests' started at 2026-09-15 00:31:18.272.
    ✖ test_showDetachedWorktrees_persistsAcrossInstances, XCTAssertTrue failed
Executed 15 tests, with 1 failure (0 unexpected) in 1.596 (1.604) seconds
Executed 316 tests, with 1 failure (0 unexpected) in 34.879 (35.044) seconds
```

`test_showDetachedWorktrees_defaultsToFalse` and `test_showDetachedWorktrees_canBeTurnedBackOff` pass
against that stub by construction — a value that is never written always reads back false. They pin
the default and the clear-on-false path against a future `didSet` that writes only the true case, so
they are guards, not watched failures, and the plan asks for all three.

**Deviations**

None.

**Gate**

`./scripts/ci.sh` — exit 0, SwiftLint clean, build succeeded, `Executed 316 tests, with 0 failures`
(313 after T1, +3 from this task). Run after the last edit. `git status --porcelain` shows only
`Sources/App/SettingsManager.swift`, `Sources/App/SettingsView.swift` and
`Tests/SettingsManagerTests.swift`; no `default.profraw` (no Debug launch was made).
