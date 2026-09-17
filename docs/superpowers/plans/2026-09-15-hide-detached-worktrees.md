# Plan: Hide Detached Worktrees

**Date:** 2026-09-15
**Base:** d94b0b0f879606872a8b1a92e2f38ac144914339
**PR:** #217

Breaks down `docs/superpowers/specs/2026-09-15-hide-detached-worktrees.md`. Every design decision is
settled there; read it before starting a task, and read this file for what your task is and how it is
checked.

## Architecture decisions carried from the spec

1. **Hidden by default.** The Settings checkbox opts *in* to showing bare-detached worktrees.
   (Decision 1)
2. **The signal is `headStatus == .detached` and nothing else.** No path matching, no provenance
   heuristic, no Claude-Code directory shape. (Decision 3)
3. **A detached HEAD with a git operation in progress is never hidden, and needs no extra guard.**
   `applyHeadResolution` has already rewritten such an entry before any view sees the list — to
   `.rebasing`/`.bisecting` with the recovered branch name, or (post-review addition) to
   `.inProgress` for cherry-pick, revert, merge and `git am`, which record no branch — so
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

### T3: Filter the three sidebar-ordered call sites

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SidebarView.swift` | `@EnvironmentObject private var settings: SettingsManager` added to the existing environment-object block. `orderedWorktrees` and `sortedWorktrees` each now pass a `Worktree.visible(worktreeManager.worktrees, showingDetached: settings.showDetachedWorktrees, openIds: terminalManager.openWorktreeIds)` expression as the first argument to `sidebarOrderedWorktrees`; the `openIds:` label and both `matches` closures are byte-identical to base. |
| `Sources/App/ContentView.swift` | Same substitution in `sortedWorktrees`. No new property — the existing `settings` declaration is reused. |
| `CLAUDE.md` | One entry under `## Architecture` → `Sources/App/`, above the `WorktreeGroupStore.openFileWatcher` note: sidebar visibility is `Worktree.visible` on the `worktrees` argument at all three `sidebarOrderedWorktrees` call sites, filtering only some desynchronises the ⌘N badge from the ⌘N shortcut, and the order/reconcile/watch/prune paths deliberately keep the unfiltered list. |

**Evidence**

No watched failure for this task, and none was available: the plan states it adds no test, because all
three edited expressions are private computed properties of view types XCTest cannot instantiate. That
is the reason decision 6 lifted the rule into `Worktree.visible`, whose seven cases were watched red in
T1. The criteria that can be proved without the GUI were proved structurally:

```
$ git ls-files -- Sources | xargs grep -n 'sidebarOrderedWorktrees('
Sources/App/ContentView.swift:446:        groupManager.sidebarOrderedWorktrees(
Sources/App/SidebarView.swift:44:        return groupManager.sidebarOrderedWorktrees(
Sources/App/SidebarView.swift:70:        groupManager.sidebarOrderedWorktrees(
Sources/App/WorktreeGroupManager.swift:181:    func sidebarOrderedWorktrees(

$ git ls-files -- Sources | xargs grep -c 'Worktree.visible(' | grep -v ':0'
Sources/App/ContentView.swift:1
Sources/App/SidebarView.swift:2

$ grep -c 'var settings: SettingsManager' Sources/App/SidebarView.swift Sources/App/ContentView.swift
Sources/App/SidebarView.swift:1
Sources/App/ContentView.swift:1
```

Four lines for acceptance criterion 1 — the declaration plus exactly the three call sites, each with a
`Worktree.visible(` first argument. Three `Worktree.visible(` call sites for criterion 2, one `settings`
declaration per file for criterion 3, and criterion 5 follows from criterion 1: the row list and the
⌘1…9 targets are now the same filtered sequence by construction. No `onChange`, `@State` mirror or
refresh call was added; both properties re-evaluate off the existing `@Published` observation.

**Deviations**

Acceptance criterion 4 — the scripted `./scripts/run.sh` pass over spec criteria 1–5 — was **not run**.
A subagent cannot observe a SwiftUI sidebar, so launching the app would have produced a probe worktree
and an un-gitignored `default.profraw` with no observation to show for them. It is handed to the
operator as the Try line instead. Neither the probe worktree nor `default.profraw` exists; the tree is
clean apart from this task's three files.

**Gate**

`./scripts/ci.sh` — exit 0, SwiftLint clean (no output between `==> Linting...` and
`==> Building and testing...`), build succeeded, `Executed 316 tests, with 0 failures` (unchanged from
T2, as expected for a task that adds no test). Run after the last edit. `git status --porcelain`
immediately after: `CLAUDE.md`, `Sources/App/ContentView.swift`, `Sources/App/SidebarView.swift` and
nothing else — no `default.profraw`.

### Simplify

`Worktree.visible` moved from the `worktrees` argument of all three `sidebarOrderedWorktrees` call
sites into the top of `sidebarOrderedWorktrees` itself, which now takes `showingDetached: Bool`
(existing test call sites pass `false`). Behaviour-identical — filtering the argument and filtering
the parameter are the same operation — but success criterion 6 becomes structural instead of a
CLAUDE.md rule, so that note shrank from 11 lines to 7 and the eight-name list of non-rendering
callers went with it. This **reverses spec Decision 6**: the rejection rested on the manager owning
"grouping and order, not visibility policy", but it already applies the `matches` search predicate
and pins main first, and `sidebarOrderedWorktrees` turned out to have exactly three callers, all
rendering — none of the must-stay-unfiltered paths reaches it. Also deleted
`testVisibilityKeepsAttachedWorktreeInEveryCombination`: 16 lines whose four iterations exercised
the same branch, pinning no success criterion.

`./scripts/ci.sh` — exit 0, SwiftLint clean, `Executed 315 tests, with 0 failures` (316 − the
deleted case). Run after the last edit; `git status --porcelain` shows six modified files and
nothing untracked.

### Post-review fix: reordering a filtered subset, and a test for the filter itself

Not a numbered plan task — two findings from the review pass, recorded in `## Changelog` as well.

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | F1: `setDefaultOrder` and `setGroupOrder` now reposition the ids they are given instead of replacing the stored list wholesale, through a new `private static func repositioned(_:with:)` — each incoming id takes the next slot the stored list gives the incoming set, and stored ids the caller omitted stay where they were; ids the store has not seen are appended. Nit: `sidebarOrderedWorktrees` now takes `showingDetached:` before `openIds:`, matching `Worktree.visible(_:showingDetached:openIds:)`, and the doc comment lost the three lines restating the CLAUDE.md visibility note. |
| `Sources/App/SidebarView.swift` | Both `.onMove` closures lost `guard !isSearching else { return }` — reordering a filtered subset is now safe in general. Argument order at the two `sidebarOrderedWorktrees` call sites follows the new signature. |
| `Sources/App/ContentView.swift` | Same argument-order change at its one call site. |
| `Tests/WorktreeGroupManagerTests.swift` | `// MARK: - Reordering a filtered subset`: a hidden id keeps its group and slot (`setGroupOrder`), the same for `setDefaultOrder`, and an id the store has not yet recorded is added rather than discarded. `// MARK: - Visibility`: F2 — `sidebarOrderedWorktrees` drops a closed bare-detached worktree with `showingDetached: false` and keeps it with `true`. |
| `docs/superpowers/specs/…` | The review pass's edits to Decisions 6/7, Assumption 4, criterion 6 and the files table, committed here. |

**Evidence**

F1, red on the wholesale-replacement code (`./scripts/ci.sh`, exit 65):

```
    ✖ testSetDefaultOrderKeepsIdsAbsentFromTheNewOrder, XCTAssertEqual failed: ("["/tmp/last", "/tmp/first"]") is not equal to ("["/tmp/last", "/tmp/hidden", "/tmp/first"]")
    ✖ testSetGroupOrderKeepsIdsAbsentFromTheNewOrder, XCTAssertEqual failed: ("Optional(["/tmp/last", "/tmp/first"])") is not equal to ("Optional(["/tmp/last", "/tmp/hidden", "/tmp/first"])") - the omitted id must stay in the group, in its original slot
```

That is the bug itself: `/tmp/hidden` is a closed bare-detached worktree, absent from the rendered
rows, and dragging a visible row dropped it from the stored order for good.
`testSetDefaultOrderRecordsAnIdItHasNotStored` passes against wholesale replacement by construction
— it guards the merge against a fix that only ever *keeps* stored ids.

F2, red with the `Worktree.visible` call commented out of `sidebarOrderedWorktrees` (exit 65),
which is the deletion the finding said CI would not notice:

```
    ✖ testSidebarOrderedHidesClosedDetachedWorktreeUnlessShowing, XCTAssertEqual failed: ("["/tmp/main", "/tmp/detached"]") is not equal to ("["/tmp/main"]") - a closed bare-detached worktree must be dropped
```

The filter line was restored immediately after.

**Deviations**

`moveDisabled: isSearching` on the rows is left as it is: with the guards gone, reordering during a
search is correct but still disabled at the row level, which is a UX decision this fix does not make.

Two `./scripts/ci.sh` runs before the gate failed on `ShellPathResolverTests` — three cases each run,
but *different* cases each time (`testAHealthyShellGivesFullFromOneInteractiveAttempt`,
`testAProfileThatFloodsStderrStillResolves`, then `testATrailingPathShapedLineIsNotMistakenForThePath`,
`testExtraLinesAroundThePathDoNotBreakResolution`), always `degraded` where `full` was expected. That
suite drives fake shell scripts under a 0.5 s per-attempt timeout
(`Tests/ShellPathResolverTests.swift:9-12`), so a loaded machine times the interactive attempt out and
falls through to the login attempt. Load average was 3.3 with other sessions building. Unrelated to
this change — it was green in both red runs above, which exercised the same code — and it passed on
the gate run.

**Gate**

`./scripts/ci.sh` — exit 0, SwiftLint clean, build succeeded, `Executed 319 tests, with 0 failures`
(315 before this fix, +4). Run after the last edit. `git status --porcelain` clean afterwards, no
`default.profraw` (no Debug launch was made).

### Post-review addition: in-progress ops that record no branch

Not a numbered plan task. The PR review pass declined this as a scope change (`## PR review stage`
→ Declined, errors 1); the operator has since decided it in, so a worktree detached because *any*
git operation is in progress is never hidden. Recorded in `## Changelog` too.

**What landed**

| File | State |
| --- | --- |
| `Sources/App/Worktree.swift` | `HeadStatus` gains one case, `.inProgress`: a git operation is in progress and recorded no branch name. `branchFromInProgressOp` is now `inProgressOp(gitdir:) -> (branch: String?, status: HeadStatus)?` — the three branch-recovering probes are unchanged, followed by four existence probes (`rebase-apply/applying`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`) that return `(nil, .inProgress)`. `applyHeadResolution` passes `op.branch` straight through, so such a row keeps its "(detached)" display name and never stays `.detached`. `removeWorktree`'s refusal message says "git operation in progress" instead of naming only rebase/bisect. |
| `Tests/WorktreeTests.swift` | One case per new marker; `testInProgressOpPrefersRebaseOverCherryPick` (a conflicted `rebase -i` writes `CHERRY_PICK_HEAD` beside `rebase-merge/head-name` — the branch must still be recovered); `testVisibilityKeepsWorktreeWithOperationInProgress`; `testParserAndResolverPipelineMarksCherryPickingWorktreeInProgress`, which runs parser → resolver → `Worktree.visible` over a real temp gitdir and is the test that pins the operator's rule end to end. The six existing probe cases were renamed and re-pointed at `inProgressOp`, asserting through `XCTUnwrap` so `branch: String?` does not read as a double optional. |
| `Sources/App/Worktree.swift` (doc) + `CLAUDE.md` | The marker list and its precedence, and the note that `.inProgress` keeps the "(detached)" name. |
| `docs/superpowers/specs/…` | Decision 4 rewritten, criterion 2 widened, Assumption 2 marked superseded in part, testing strategy and files table updated. |

**Why these markers, and nothing else.** Git's own shipped prompt script,
`/Applications/Xcode.app/Contents/Developer/usr/share/git-core/git-prompt.sh` (git 2.54.0), reads
exactly these files and in this order:

```sh
	if [ -d "$g/rebase-merge" ]; then
		__git_eread "$g/rebase-merge/head-name" b
		...
		r="|REBASE"
	else
		if [ -d "$g/rebase-apply" ]; then
			...
			if [ -f "$g/rebase-apply/rebasing" ]; then
				__git_eread "$g/rebase-apply/head-name" b
				r="|REBASE"
			elif [ -f "$g/rebase-apply/applying" ]; then
				r="|AM"
			...
		elif [ -f "$g/MERGE_HEAD" ]; then
			r="|MERGING"
		elif __git_sequencer_status; then
```

and `__git_sequencer_status` is `test -f "$g/CHERRY_PICK_HEAD"` → `|CHERRY-PICKING`,
`test -f "$g/REVERT_HEAD"` → `|REVERTING`. `rebase-apply/applying` is what separates `git am` from
`git rebase --apply`, which is why it is the `am` marker and not the `rebase-apply` directory
itself. Only `rebase-merge`/`rebase-apply` (and `BISECT_START`, which the existing code reads) hold
a branch name at all, which is the whole reason `.inProgress` carries none.

**Evidence.** The new tests were written against the widened signature *before* the four probes
existed, so they failed on behaviour rather than on compilation (`./scripts/ci.sh`, exit 65,
`Executed 330 tests, with 6 failures`):

```
    ✖ testInProgressOpRecognizesCherryPick, XCTUnwrap failed: expected non-nil value of type "(branch: Optional<String>, status: HeadStatus)"
    ✖ testInProgressOpRecognizesGitAm, XCTUnwrap failed: expected non-nil value of type "(branch: Optional<String>, status: HeadStatus)"
    ✖ testInProgressOpRecognizesMerge, XCTUnwrap failed: expected non-nil value of type "(branch: Optional<String>, status: HeadStatus)"
    ✖ testInProgressOpRecognizesRevert, XCTUnwrap failed: expected non-nil value of type "(branch: Optional<String>, status: HeadStatus)"
    ✖ testParserAndResolverPipelineMarksCherryPickingWorktreeInProgress, XCTAssertEqual failed: ("detached") is not equal to ("inProgress")
    ✖ testParserAndResolverPipelineMarksCherryPickingWorktreeInProgress, XCTAssertEqual failed: ("[]") is not equal to ("[…/picked-wt"]") - a worktree with a cherry-pick in progress is never hidden
```

The last line is the bug itself: before this change a worktree stopped on a cherry-pick conflict
was filtered out of the sidebar.

**Deviations**

- One new `HeadStatus` case rather than one per operation. Nothing distinguishes them downstream:
  `visible` hides only `.detached`, `canRemove`/`canFetchPR` admit only `.attached`, no view reads
  `headStatus`, and none of the four records a branch to display. Four cases would be four names
  with identical behaviour.
- The four branchless probes are appended after the existing three rather than interleaved into
  git's precedence, which puts `MERGE_HEAD` before rebase and bisect last. The orderings differ only
  when markers coexist, and the one coexistence that actually happens — a conflicted `rebase -i`
  writing `CHERRY_PICK_HEAD` — resolves to `.rebasing` either way, pinned by
  `testInProgressOpPrefersRebaseOverCherryPick`. Reordering the three existing probes would have
  changed behaviour this task did not ask about.

**Gate**

`./scripts/ci.sh` — exit 0, SwiftLint clean, build succeeded,
`Executed 330 tests, with 0 failures` (323 before this addition, +7). Run after the last code edit.
The run before it failed on the documented `ShellPathResolverTests` flake — exit 65,
`testExtraLinesAroundThePathDoNotBreakResolution`, `degraded` where `full` was expected, the same
0.5 s-per-attempt timeout under load recorded in the post-review-fix section above — and passed on
the re-run with no edit in between. `git status --porcelain` shows only the five files this addition
touched; nothing untracked, no `default.profraw` (no Debug launch).

## PR review stage (`/pr-review-toolkit:review-pr code tests errors types`)

Four agents over `d94b0b0..cbd0094`. No Critical findings from any of them.

**Fixed**

| Finding | Source | Change |
| --- | --- | --- |
| `repositioned` amplified a duplicate stored id where the old wholesale replace healed one: `stored == [a,a,b]` + drag `[b,a]` gave `[b,a,b]`, and `orderedNonMain` maps `defaultOrder` through `defaultById`, so the same `Worktree` reached the `List` twice. | types (F5) + tests (nit 6), independently | A moving slot with no id left to take it is dropped instead of re-emitting the stored id, so a duplicated `groups.json` heals on the next drag. `testSetDefaultOrderCollapsesADuplicateStoredId` pins it. |
| `Worktree.visible` restated `TerminalManager.isOpen`'s predicate verbatim, unpinned — widening "open" in one would have let the sidebar hide a row `worktreeRowView` still styles as open. | types (F2) | `Worktree.isOpen(openIds:)` holds the rule; `visible` and `TerminalManager.isOpen` both call it. Keeps `visible` pure, so Decision 6 is untouched. |
| `openIds` reached the filter at the seam with nothing asserting it — a stale array there would hide a worktree the user has terminals open in, failing criterion 3 with the suite green. | tests (1) | `testSidebarOrderedKeepsOpenDetachedWorktreeWhileHiding`. |
| A *grouped* bare-detached worktree was never tested, so narrowing the filter to `defaultSlice` — close to the original Decision 6 wording — would pass CI. | tests (2) | `testSidebarOrderedHidesDetachedWorktreeInsideAGroup`. |
| Every `visible` case passed a one-element list, so the filter was never asked to keep and drop in one call; the spec's listed "keeps `.attached` in every combination" case was absent. | tests (4, 5) | One mixed-list case replaces neither: `testVisibilityKeepsEveryExemptShapeInOneCall`. |
| `result.reserveCapacity(max(stored.count, ids.count))` was speculative and wrong — the result can be as long as `stored.count` plus the count of ids `stored` does not hold, so it reallocated anyway. | code (2) | Line deleted. |
| `visible`'s doc comment transcribed the boolean under it. | code (1) | Deleted. The `setDefaultOrder` / `repositioned` comments stay: they encode a caller contract the signature cannot. |
| `setDefaultOrder`'s comment claimed search produces a subset here; `moveDisabled` makes that unreachable. Two reorder tests' comments claimed the detached filter was in their call path, which it is not — the store only ever sees `[String]`. | types (F6) + tests | Reworded to name only what is true. |
| CLAUDE.md: "Nothing that is not rendering goes through that method, and none should" says the opposite of what it means. | code (3) | "Only rendering paths go through that method, and only they should". |

**Evidence for the `repositioned` fix.** A standalone Swift comparison of the two versions in the
scratchpad: old `[a,a,b]`+`[b,a]` → `["b","a","b"]`, new → `["b","a"]`; and over all 14,113
duplicate-free inputs (stored orders to 5 ids × every hidden subset × 0-2 fresh ids × every
permutation) the two agree exactly, so the fix changes nothing but the duplicate case.

**Declined**

- *Extend the in-progress probe table to cherry-pick / revert / merge / `am`* (errors 1). Decision 4
  scopes hiding to `.detached` and names rebase and bisect only; a new `HeadStatus` case plus parser
  probes is a scope change. Recorded as a follow-up — it is a real gap, not a wrong reading.
- *Persist `openWorktreeIds` so Decision 2's exemption survives a relaunch* (errors 2). Follows the
  letter of Decisions 2 and 12; the restart case is a product decision for the operator.
- *`defaults.bool(forKey:)` instead of `object(forKey:) as? Bool ?? false`* (errors 3). Decision 11
  prescribes the shape, and diverging one of three sibling preferences is worse than the coercion gap.
- *Restore `guard !isSearching` in the two `.onMove` closures* (errors 4). The post-review fix removed
  them deliberately and two other reviewers confirmed the removal: `moveDisabled` blocks the drag and
  `repositioned` now handles a filtered subset, so the guard is dead code.
- *Rename `showingDetached:` to `showDetachedWorktrees:`* (types F3). Naming only; Decision 6 fixes
  the helper's parameter name and 11 call sites would churn.
- *A `reconcile` test with a `.detached` id in the known set* (tests 3). Vacuous by construction:
  `reconcile(knownWorktreeIds: Set<String>)` receives strings and cannot see `headStatus`, so it
  could not filter on detachedness however it were written. The real invariant — `ContentView`
  passing the unfiltered list — stays a review-only one.
- *Delete the sleeps in the three new reorder tests* (tests, quality note). They are load-bearing:
  `setUp:16-18` and `testReconcileDropsPhantomIds:191-196` document the store's watcher callback
  reloading a just-written file over newer in-memory state.
- *`HeadStatus` carrying its branch as a payload* (types F1) and *`id` being `""`-able* (types F4).
  Assumption 1 puts the first out of this PR; the second is pre-existing. Both follow-ups.
- *A group whose only members are hidden renders as a bare header* (errors 5). Consistent with the
  existing "empty (new) groups stay visible" rule, and the code reviewer independently read it as
  in-design. Follow-up.

**Gate.** `./scripts/ci.sh` — exit 0, SwiftLint clean, build succeeded,
`Executed 323 tests, with 0 failures` (319 before this stage, +4). Run after the last edit.
`git status --porcelain` shows only the six files this stage modified; nothing untracked, no
`default.profraw` (no Debug launch).

## Changelog

- **Rebased onto `origin/main` (this branch, after `ed65624`).** `main` had gained `ce39685` "Add saved commands and a worktree Run dropdown (#216)". One conflict, in `CLAUDE.md` only: both
  sides edited the `TerminalManager.appendLauncherTab` bullet's tail — `main` rewrote the promote
  rule around `startsAsLoginShell` and appended the saved-command bullets, this branch carried the
  older `mainCommandProvider() == nil` wording and appended the sidebar-visibility bullet. Resolved
  by keeping `main`'s rewrite and all three of its bullets, then the sidebar-visibility bullet on
  top. `ContentView.swift` and `SidebarView.swift` auto-merged; no code changed beyond the conflict,
  and the new `RunCommandMenu` takes a single selected worktree rather than a worktree list, so the
  visibility filter does not apply to it. `./scripts/ci.sh` green, 376 tests, exit 0.
- **Post-review addition (this branch, after `fe73508`).** Operator decision: a worktree detached
  because *any* git operation is in progress must never be hidden by the toggle, not just rebase and
  bisect. `HeadStatus` gains `.inProgress` and `branchFromInProgressOp` becomes
  `inProgressOp(gitdir:)`, probing `rebase-apply/applying` (`git am`), `MERGE_HEAD`,
  `CHERRY_PICK_HEAD` and `REVERT_HEAD` — markers that carry no branch, so those rows keep the
  "(detached)" name while `applyHeadResolution` stops leaving them `.detached`. Reverses the
  `## PR review stage` "Declined, errors 1" entry. Spec Decision 4 and criterion 2 updated. Full
  detail in the `## Build log` section above. Persisting opened detached worktrees across a relaunch
  (errors 2) stays deferred to a follow-up task.
- **PR review stage (this branch, after `cbd0094`).** `repositioned` no longer amplifies a duplicate
  stored id, and `Worktree.isOpen(openIds:)` now holds the one copy of the open-worktree rule that
  `visible` and `TerminalManager.isOpen` share. Four tests added at the seams the filter passes
  through: `openIds` reaching the filter, a grouped detached worktree, a mixed keep-and-drop list,
  and the duplicate-id heal. Plus three comment/doc corrections and a dead `reserveCapacity`.
  Detail, and the nine declined findings with reasons, in the `## PR review stage` section above.
- **Post-review fix (this branch, after `b449541`).** F1: a drag inside a group or the ungrouped
  section dropped every worktree the rendered rows omitted — with the toggle off, a closed
  bare-detached worktree lost its group permanently. `setDefaultOrder` / `setGroupOrder` now
  reposition the ids they receive instead of replacing the stored list, so both `!isSearching`
  guards in `SidebarView`'s `.onMove` closures could go. F2: `sidebarOrderedWorktrees`'s
  `Worktree.visible` call had no test, so deleting it left CI green; it now has one. Plus the
  reviewer's two nits — `showingDetached:` precedes `openIds:` in `sidebarOrderedWorktrees` to match
  `Worktree.visible`, and the doc comment restating the CLAUDE.md visibility note is gone. Full
  detail in the `## Build log` section above.
