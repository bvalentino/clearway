# Plan: Improve title

Breaks down `docs/superpowers/specs/2026-09-23-improve-title.md`.

**Date:** 2026-09-23
**Base:** 66145eb (Release v2.0.0)

## Architecture decisions carried from the spec

- Titles: Tasks → "Tasks", Prompts → "Prompts", Commands → "Commands"; a worktree → its sidebar
  row's primary text; no destination selected → the project name (D1, D2, D4).
- The project name appears in the title only when no destination is selected. No subtitle, no
  combined "X — project" title (D3).
- The title is resolved only in `ContentView.navigationTitle`, which feeds the existing
  `.navigationTitle` modifier outside the split view. No `.navigationTitle` in any detail view (D5).
- `WorktreeRow.rowTexts(for:name:taskTitle:)` is the one precedence rule. It returns a
  non-optional `primaryText` (`name ?? taskTitle ?? wt.displayName`) and an optional `subtitle`
  (`wt.displayName`, set only when a name or task title won). `WorktreeRow.primaryText` becomes a
  non-optional `String` and the body's `primaryText ?? worktree.displayName` fallback is deleted (D6).
- The title's worktree inputs are exactly the sidebar's: `groupManager.name(for: wt)` and
  `workTaskManager.titlesByBranch[branch]` via `wt.branch.flatMap { ... }` (D7).
- The per-destination switch is a pure, exhaustive
  `static func windowTitle(for selection: DetailSelection?, projectName: String, worktreeTitle: (Worktree) -> String) -> String`
  on `DetailSelection`, beside `bottomPanelAction(for:)`. `ContentView.navigationTitle` calls it (D8).
- Live updates need no extra wiring: `ContentView` already observes both managers (D9).
- `ContentView.swift` keeps its file-wide `// swiftlint:disable file_length` (D10).
- Never: a second copy of the name/task/branch precedence; any change to the text the sidebar row
  renders.

## Dependency graph

```
T1: rowTexts owns the whole precedence rule
  └── T2: per-destination window title
```

T2 calls `rowTexts(...).primaryText` as a non-optional `String`, which only exists after T1.

## Tasks

### T1: rowTexts owns the whole precedence rule

**Files:**
- `Sources/App/WorktreeRow.swift`
- `Tests/WorktreeRowTests.swift`
- `Sources/App/SidebarView.swift` (only if the call site at ~526-540 fails to compile; it should not
  need a change, since it passes `rowTexts`' result straight through)

**What:**
- Change `rowTexts` to return `(primaryText: String, subtitle: String?)`. With a name or task title:
  `(that, wt.displayName)`. With neither: `(wt.displayName, nil)`.
- Update its doc comment to state it is the whole rule, now also read by the window title, and drop
  the sentence saying the body falls back to `displayName`.
- `WorktreeRow.primaryText` becomes `var primaryText: String` with no default (the only construction
  site, `SidebarView.swift:531`, always passes it).
- The body's two-line branch becomes `if let subtitle, !subtitle.isEmpty`; the one-line branch
  renders `Text(primaryText)`. What the row displays must not change for any input.
- Tests (`WorktreeRowTextTests`): replace `testNeitherLeavesBothNil` with a case expecting
  `primaryText == "feature-x"`, `subtitle == nil`. Add: a detached worktree with neither name nor
  task title → `"(detached)"`, `nil`; a main worktree (`isMain: true`, branch `main`, name nil,
  task title nil) → `"main"`, `nil`. Keep the existing four cases unchanged.

**Acceptance criteria:**
- `rowTexts`' return type has a non-optional `primaryText`, and no other code computes
  `name ?? taskTitle ?? displayName` or `primaryText ?? worktree.displayName`.
- The sidebar row renders the same text as before for name, task title, neither, detached, and main.
- `./scripts/ci.sh` exits 0.

**Verification:**
- `grep -n "displayName" Sources/App/WorktreeRow.swift` shows it only inside `rowTexts`.
- `./scripts/ci.sh` exits 0 with the updated and new `WorktreeRowTextTests` cases passing.

### T2: Per-destination window title

**Files:**
- `Sources/App/ContentView.swift`
- `Tests/WindowTitleTests.swift` (new)
- `Sources/App/CLAUDE.md`

**What:**
- Add to `DetailSelection`, directly after `bottomPanelAction(for:)`:
  `static func windowTitle(for selection: DetailSelection?, projectName: String, worktreeTitle: (Worktree) -> String) -> String`,
  a `switch` with one arm per case and no `default`: `.tasks` → "Tasks", `.prompts` → "Prompts",
  `.commands` → "Commands", `.worktree(let wt)` → `worktreeTitle(wt)`, `.none` → `projectName`.
  Give it a short doc comment in the style of `bottomPanelAction`'s (pure for XCTest, exhaustive so a
  new destination names its title).
- Replace the body of `ContentView.navigationTitle` (~line 523) with a call to it, passing
  `detailSelection`, `projectName`, and a closure that returns
  `WorktreeRow.rowTexts(for: wt, name: groupManager.name(for: wt), taskTitle: wt.branch.flatMap { workTaskManager.titlesByBranch[$0] }).primaryText`.
  Keep the existing doc comment about why the title is resolved here.
- New `Tests/WindowTitleTests.swift`, modelled on `Tests/BottomPanelActionTests.swift` (uses the
  shared `makeWorktree` helper): Tasks → "Tasks"; Prompts → "Prompts"; Commands → "Commands";
  `.worktree(wt)` returns the closure's value for that `wt` (assert the closure receives that
  worktree); `nil` → the project name passed in.
- `Sources/App/CLAUDE.md`, at the `.navigationTitle` note (~lines 149-151): add one sentence saying
  a worktree's title is `WorktreeRow.rowTexts`' primary text, so the title and the sidebar row share
  one rule.

**Acceptance criteria:**
- Tasks, Prompts and Commands titles are "Tasks", "Prompts", "Commands"; a worktree's title is
  `rowTexts(...).primaryText` from the same inputs `SidebarView.worktreeRowView` passes; no selection
  yields the project name.
- No `.navigationTitle` is added anywhere other than the existing one in `ContentView`.
- `windowTitle(for:...)` has no `default` arm.
- `./scripts/ci.sh` exits 0.

**Verification:**
- `./scripts/ci.sh` exits 0 with `WindowTitleTests` passing.
- `grep -rn "navigationTitle" Sources/App` shows no new modifier sites.
- Live updates on rename, task-title edit, link and unlink (spec criterion 6) are checked by hand
  by the operator; build agents do not launch the app.

## Build log

### T1: rowTexts owns the whole precedence rule

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | `rowTexts` returns `(primaryText: String, subtitle: String?)`; with neither name nor task title it returns `(wt.displayName, nil)`. `primaryText` is a non-optional `String` with no default. The body branches on `if let subtitle, !subtitle.isEmpty` and the one-line branch renders `Text(primaryText)`; the `primaryText ?? worktree.displayName` fallback is gone. Doc comment states it is the whole rule, read by the row and the window title. |
| `Tests/WorktreeRowTests.swift` | `testNeitherLeavesBothNil` replaced by `testNeitherFallsBackToTheBranchWithNoSubtitle` (`"feature-x"`, nil). Added `testADetachedWorktreeWithNeitherShowsDetached` (`"(detached)"`, nil) and `testMainShowsItsBranch` (`"main"`, nil). The four other cases are unchanged. |
| `Sources/App/SidebarView.swift` | Unchanged; the call site passes `rowTexts`' result straight through and compiles as is. |

Row output is unchanged for every input: with a name or task title and a non-empty subtitle it is two lines as before; in every other case it is one line of `name ?? taskTitle ?? displayName`, which is what the old body's `primaryText ?? worktree.displayName` produced.

**Evidence.** The updated tests were run with `./scripts/ci.sh` against the unfixed `rowTexts` (exit 65):

```
✖ testADetachedWorktreeWithNeitherShowsDetached, XCTAssertEqual failed: ("nil") is not equal to ("Optional("(detached)")")
✖ testMainShowsItsBranch, XCTAssertEqual failed: ("nil") is not equal to ("Optional("main")")
✖ testNeitherFallsBackToTheBranchWithNoSubtitle, XCTAssertEqual failed: ("nil") is not equal to ("Optional("feature-x")")
```

`grep -n "displayName" Sources/App/WorktreeRow.swift` shows it only inside `rowTexts` and its doc comment (plus the unrelated `status.displayName` in `StatusBadge`).

**Deviations.** None.

**Gate.** `./scripts/ci.sh` after the last code edit: exit 0, "Test Succeeded", no failing tests.

### T2: Per-destination window title

| File | State |
| --- | --- |
| `Sources/App/ContentView.swift` | `DetailSelection.windowTitle(for:projectName:worktreeTitle:)` added after `bottomPanelAction(for:)`: an exhaustive `switch` with no `default` (`.tasks` → "Tasks", `.prompts` → "Prompts", `.commands` → "Commands", `.worktree(wt)` → `worktreeTitle(wt)`, `.none` → `projectName`). `ContentView.navigationTitle` calls it with a closure returning `WorktreeRow.rowTexts(for:name:taskTitle:).primaryText` from `groupManager.name(for: wt)` and `wt.branch.flatMap { workTaskManager.titlesByBranch[$0] }`, the inputs `SidebarView.worktreeRowView` passes. Existing doc comment kept. |
| `Tests/WindowTitleTests.swift` | New. Tasks, Prompts, Commands, a worktree (returns the closure's value and asserts the closure received that worktree), and no selection (project name). |
| `Sources/App/CLAUDE.md` | One sentence at the `.navigationTitle` note: a worktree's title is `rowTexts`' primary text, shared with the sidebar row. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` for the new test file. |

**Evidence.** The tests were run with `./scripts/ci.sh` against a stub `windowTitle` that returned `projectName` for every case (exit 65):

```
✖ testCommands, XCTAssertEqual failed: ("clearway") is not equal to ("Commands")
✖ testPrompts, XCTAssertEqual failed: ("clearway") is not equal to ("Prompts")
✖ testTasks, XCTAssertEqual failed: ("clearway") is not equal to ("Tasks")
✖ testWorktreeUsesTheWorktreeTitleForThatWorktree, XCTAssertEqual failed: ("clearway") is not equal to ("Row text")
✖ testWorktreeUsesTheWorktreeTitleForThatWorktree, XCTAssertEqual failed: ("nil") is not equal to ("Optional(Clearway.Worktree(branch: Optional("feature"), ...))")
```

`testNoSelectionShowsTheProjectName` passed against the stub, as expected.

`grep -rn "navigationTitle" Sources/App` shows no new modifier sites: `ContentView.swift`'s existing one, plus the pre-existing `SettingsView`, `WorkTaskWindow` and `PromptWindow` ones.

**Deviations.** None. `ContentView.swift` is now 1018 lines, under the file-wide `swiftlint:disable file_length` (D10).

**Gate.** `./scripts/ci.sh` after the last code edit: exit 0, "Test Succeeded", 847 tests, 0 failures.
