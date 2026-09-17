# Plan: Primary Badge in the Sidebar

**Date:** 2026-09-17
**Base:** ce3968526aa99a1c14926eeb4e84a279ad327d8f
**PR:** #218

Breaks down `docs/superpowers/specs/2026-09-17-primary-badge-in-sidebar.md`.

## Architecture decisions carried from the spec

1. The badge is gated on `worktree.isMain` — a stored `Bool` set from `index == 0` of
   `git worktree list --porcelain` (`Worktree.swift:255`). No new model state, no branch-name test.
2. The badge is drawn, not literal text: the word `primary` in `.caption2`, `.secondary`
   foreground, `.quaternary` `Capsule()` background. Confirmed again after the spec — it is a
   capsule badge, not the string `[primary]`.
3. It sits in `WorktreeRow`'s outer `HStack`, between the text `VStack` and the `Spacer()`
   (`SidebarView.swift:466-480`), so it follows the name and is left-aligned. One insertion point
   serves both the one-line and two-line text layouts; in the two-line layout it sits beside the
   block, vertically centred, and is not duplicated onto the branch line.
4. The badge carries `.fixedSize()` so the name truncates first (the name `Text`s already have
   `.lineLimit(1)`).
5. No `.help()` tooltip — it would restate the visible word.
6. `Worktree.isMain` is not renamed, and `CommandsView.KindLabel` is not extracted into a shared
   component. The sidebar badge is a new private `View` in `SidebarView.swift` beside the existing
   private `ShortcutBadge` (`SidebarView.swift:515-523`).
7. No new test. `WorktreeRow` is a SwiftUI `View` with no output XCTest can inspect, and the rule
   is a stored property already pinned in `Tests/WorktreeTests.swift`. `./scripts/ci.sh` is the
   regression check.
8. No badge outside the sidebar, and no badge for any other row state.

## Dependency graph

```
T1 (the only task)
```

The change is one view in one file. Nothing unblocks anything else.

## Task list

### T1: Render a `primary` badge on the main worktree's sidebar row

**Files touched**

- `Sources/App/SidebarView.swift`

**What it does**

Adds a private `PrimaryBadge` view to `SidebarView.swift`, placed beside the existing private
`ShortcutBadge` (currently `SidebarView.swift:515-523`), and renders it from `WorktreeRow.body`.

`PrimaryBadge` mirrors `CommandsView.KindLabel` (`CommandsView.swift:128-139`) at the sidebar's
denser scale:

- `Text("primary")`
- `.font(.caption2)`
- `.foregroundStyle(.secondary)`
- `.padding(.horizontal, 6)` / `.padding(.vertical, 2)` — `KindLabel`'s 8/3 scaled down with the
  font; the spec fixes the font, foreground and background, not the padding
- `.background(.quaternary, in: Capsule())`
- `.fixedSize()`

In `WorktreeRow.body`, immediately after the text `VStack` and before the `Spacer()` in the outer
`HStack` (`SidebarView.swift:466-480`):

```swift
if worktree.isMain {
    PrimaryBadge()
}
```

The enclosing `HStack(spacing: 4)` already supplies the gap after the name; add no extra spacing
and no other modifier. Write no comment — the code is self-explanatory, and CLAUDE.md treats a
comment here as a smell.

**Acceptance criteria**

1. The sidebar row for the worktree with `isMain == true` renders a capsule badge reading
   `primary` immediately after the row's name.
2. No other worktree row renders it.
3. The condition is `worktree.isMain` alone — no branch string is read, so renaming the root
   branch leaves the badge in place.
4. At a narrow sidebar width the name ellipsises and the badge stays whole.
5. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports zero errors for the change.

**How the criteria are verified**

- Criteria 1, 2 and 4: run `./scripts/run.sh` and look at the sidebar. The primary row (sorted
  first, `Worktree.sorted` orders `isMain` first) carries the badge; the linked worktrees below it
  do not. Drag the sidebar divider narrow and confirm the name truncates while the badge stays
  whole.
- Criterion 3: read the diff. The gate is `worktree.isMain`; no branch name appears in it. A repo
  whose root branch is not `main` is not needed to prove a condition that reads no branch.
- Criterion 5: `./scripts/ci.sh` — the regression check named in CLAUDE.md's `## Pipeline`
  section. Do not hand-write an `xcodebuild` line. SwiftLint runs inside it; `SidebarView.swift`
  is linted (only `Sources/Ghostty` is excluded). The file is 652 lines and the change adds
  roughly 14, so it stays under the `file_length` warning threshold of 700.

**Notes for the build agent**

- A Debug launch drops an un-gitignored `default.profraw` in the repo root. Never `git add -A`;
  report the file rather than committing it.
- `WorktreeRow` has exactly one construction site, `SidebarView.worktreeRowView`
  (`SidebarView.swift:409`), so no call site changes.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Badge pushes the working/notification dots off a narrow row | Low | The badge is `.fixedSize()` and precedes the `Spacer()`; the name `Text`s truncate first. Confirmed visually in T1's narrow-width check. |

## Out of scope

Everything the spec's "Out of scope" section lists: renaming `Worktree.isMain`, extracting a shared
badge component, badges elsewhere in the app, badges for other row states, and the
`WorktreeGroupStore.openFileWatcher` fd leak.

## Build log

### T1: Render a `primary` badge on the main worktree's sidebar row

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SidebarView.swift` | `WorktreeRow.body` renders `PrimaryBadge()` when `worktree.isMain`, between the text `VStack` and the `Spacer()` in the outer `HStack`. New `private struct PrimaryBadge` added below `ShortcutBadge`: `Text("primary")`, `.caption2`, `.secondary`, 6/2 padding, `.quaternary` `Capsule()` background, `.fixedSize()`. |
| `docs/superpowers/specs/2026-09-17-primary-badge-in-sidebar.md` | Added (was untracked); committed with this task. |
| `docs/superpowers/plans/2026-09-17-primary-badge-in-sidebar.md` | Added (was untracked), plus this build log. |

**Evidence**

No regression test was added, and none is claimed. Spec decision 9 and plan note 7 settle this:
the rule is the stored property `worktree.isMain`, already pinned in `Tests/WorktreeTests.swift`,
and `WorktreeRow` is a SwiftUI `View` with no output XCTest can inspect — so there is no failure to
watch go red. Criteria 1, 2 and 4 are visual and are handed to the operator's hands-on check.
Criterion 3 is read off the diff: the gate is `worktree.isMain` and no branch string appears in it.

**Deviations from the plan**

None.

**Gate**

`./scripts/ci.sh` — exit status 0, "CI passed", 352 tests, 0 failures. `swiftlint lint --quiet`
reports 0 errors. Working tree after the run held only this task's three files; no
`default.profraw` (the Debug app was not launched by this agent).

### Simplify

Nothing changed. The four cleanup angles turned up one candidate each and all four were declined:
extracting a shared pill with `CommandsView.KindLabel` (different font and padding; plan decision 6
already settled it), inlining `PrimaryBadge` into `WorktreeRow.body` (`WorktreeDragChip` is the same
parameterless single-call-site shape in this file, so the extracted view is the local convention),
`.fixedSize()` (plan decision 4), and passing `isMain` as a row parameter (`WorktreeRow` has one call
site). `./scripts/ci.sh` — exit status 0, "CI passed", 352 tests, 0 failures.
