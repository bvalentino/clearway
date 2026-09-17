# Primary Badge in the Sidebar

**Date:** 2026-09-17
**Base:** ce3968526aa99a1c14926eeb4e84a279ad327d8f
**PR:** #218

The sidebar draws every worktree row the same way, so the primary worktree — the checkout the
other worktrees hang off — is only identifiable by the branch name being `main`. Rename that
branch, or open a project whose root branch is `master`, `trunk` or a release branch, and the row
is indistinguishable from the linked worktrees below it. This change marks that one row with a
**primary** badge rendered after the row's name, so the root checkout is identifiable by what it
is rather than by what it happens to be called.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Which row gets the badge? | The row whose `Worktree.isMain` is `true` (`Worktree.swift:19`). That is exactly one row per project — `WorktreeManager.parseWorktreeListOutput` sets it from `index == 0` of `git worktree list --porcelain` (`Worktree.swift:255`), and git lists the main working tree first. No new model state, no new lookup. | Spec author |
| 2 | Is the badge the literal text `[primary]` or a drawn badge reading `primary`? | A drawn badge reading `primary`: the word in `.caption2`, `.secondary` foreground, `.quaternary` `Capsule()` background. The operator's word was "badge"; `main [primary]` is how a badge is written in a sentence, and the brackets are the sentence's, not the UI's. This also reuses the only badge shape the codebase already has (`CommandsView.KindLabel`, `CommandsView.swift:128-139`). If the operator wanted the brackets literally, the change is one string. | Spec author |
| 3 | Where in the row does it sit? | In `WorktreeRow`'s outer `HStack`, between the text `VStack` and the `Spacer()` (`SidebarView.swift:466-480`), so it follows the name and stays left-aligned instead of being pushed to the row's trailing edge where the working/notification dots live. One insertion point covers both the one-line and two-line text layouts. | Spec author |
| 4 | What happens in the two-line layout, where a linked task title is the top line and the branch is the subtitle (`SidebarView.swift:468-476`)? | The badge sits beside the two-line block, vertically centred, rather than being duplicated onto the branch line. The badge marks the **row**, not the branch string. This case needs a task whose `worktree` frontmatter names the root branch, which the app never creates itself — `WorkTaskCoordinator` creates a worktree per task — so it is a rare hand-authored state, not the common one. | Spec author |
| 5 | Does the name truncate before the badge does? | Yes. The badge gets `.fixedSize()`; the name `Text`s already carry `.lineLimit(1)` (`SidebarView.swift:470,474,477`). At a narrow sidebar width the branch name ellipsises and the badge stays whole, which is the only ordering that keeps the badge useful. | Spec author |
| 6 | Does the badge get a `.help()` tooltip? | No. CLAUDE.md's no-helper-text rule: a tooltip here would restate the visible word. Tooltips in this codebase name icon-only controls (spec `2026-09-14-commands-view.md`, decision 25); this is a text label, not an icon. | Spec author |
| 7 | Is "primary" the right word, given the code calls it `isMain`? | Yes, and nothing is renamed. The app already exposes this checkout to users as "primary": `WorktreeHooks` substitutes `{{ primary_worktree_path }}` from `WorktreeHookContext.primaryWorktreePath` (`WorktreeHooks.swift:13,24`). `isMain` stays as-is — renaming a property that 20 call sites read is a separate change with no user-visible effect. | Spec author |
| 8 | Does the badge appear anywhere else — the window title, the worktree toolbar, the project selector? | No. The brief names the side panel. Everywhere else the primary worktree is either the only thing on screen or already named. | Spec author |
| 9 | Does this add a test? | No. The rule is `worktree.isMain` — a stored property with no derivation, already pinned where it is computed (`Tests/WorktreeTests.swift:26,45,86-88` assert `isMain` on the parsed list). `WorktreeRow` is a SwiftUI `View` with no inspectable output from XCTest, and lifting `wt.isMain` into a helper to assert `wt.isMain == wt.isMain` pins nothing. `./scripts/ci.sh` still runs the full suite as the regression check. | Spec author |
| 10 | Is `CommandsView.KindLabel` extracted into a shared badge component? | No. It is `private` to `CommandsView.swift` and the sidebar badge is a different size (`.caption2` against `.caption`) for a denser row. Extracting a shared component across two call sites that disagree on their metrics buys an abstraction and a parameter, not a saving. The sidebar badge is a private `View` in `SidebarView.swift` beside the existing private `ShortcutBadge` (`SidebarView.swift:515-523`). | Spec author |

## Assumptions

Each verified against the codebase at base `ce39685`. Nothing empirical was needed beyond reading;
no probe scripts or temporary files were written into the repo or the scratchpad.

1. **Exactly one worktree per project has `isMain == true`.** `parseWorktreeListOutput` sets
   `let isMain = index == 0` over the porcelain records (`Worktree.swift:255`), and
   `applyHeadResolution` carries the flag through unchanged when it recovers a branch from an
   in-progress rebase or bisect (`Worktree.swift:310`).
2. **The primary worktree only ever renders in the default (ungrouped) sidebar section.**
   `WorktreeGroupManager.addWorktree` returns early for it (`WorktreeGroupManager.swift:74`) and
   `restoreOrder` re-pins it into the default slice (`WorktreeGroupManager.swift:189-195`), so one
   row site covers every case.
3. **`WorktreeRow` has exactly one construction site.** `SidebarView.worktreeRowView`
   (`SidebarView.swift:409`); the type is declared at `SidebarView.swift:455` and used nowhere
   else in `Sources/` or `Tests/`.
4. **The primary row is always sorted first and always considered open.**
   `Worktree.sorted` orders `isMain` first (`Worktree.swift:31`) and `TerminalManager.isOpen`
   returns `true` for it unconditionally (`TerminalManager.swift:494`), so the row is never dimmed
   by the `opacity(isOpen ? 1.0 : 0.5)` modifier (`SidebarView.swift:418`) and the badge is never
   rendered at half opacity.
5. **The primary row's name is normally the branch name on a single line.**
   `rowTexts` promotes a linked task title to the primary label only when
   `WorkTaskManager.titlesByBranch` has an entry for the row's branch (`SidebarView.swift:386-393`,
   `WorkTaskManager.swift:109-118`); tasks link to worktrees the app creates for them, not to the
   root checkout.
6. **`SidebarView.swift` is linted.** Only `Sources/Ghostty` is excluded from SwiftLint
   (`.swiftlint.yml`), so the new view must pass `swiftlint lint` with zero errors.

## Objective

A user who has renamed their root branch — or who works in a repo whose root branch is not `main` —
can identify the primary worktree in the sidebar at a glance.

### Success criteria

1. The sidebar row for the worktree with `isMain == true` renders a badge reading `primary`
   immediately after the row's name.
2. No other worktree row renders the badge.
3. The badge is independent of the branch name: renaming the root branch from `main` to anything
   else leaves the badge in place.
4. At a narrow sidebar width the name truncates and the badge stays fully visible.
5. `./scripts/ci.sh` is green, and `swiftlint lint --quiet` reports zero errors for the change.

## Verification

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds and runs the test suite — the regression check for
every build task and the full gate at sign-off, per CLAUDE.md's `## Pipeline` section. Do not
hand-write an `xcodebuild` line.

Because the change is view-only and `WorktreeRow` is not reachable from XCTest (decision 9),
success criteria 1–4 are confirmed by a hands-on check of the running app
(`./scripts/run.sh`), on a project whose root branch is **not** named `main`. Expect the
un-gitignored `default.profraw` in the repo root after any Debug launch; report it before
sign-off and do not `git add -A`.

## Files touched

| File | Change |
| --- | --- |
| `Sources/App/SidebarView.swift` | `WorktreeRow.body` gains the badge, gated on `worktree.isMain`; a private `PrimaryBadge` view is added beside `ShortcutBadge`. |
| `docs/superpowers/specs/2026-09-17-primary-badge-in-sidebar.md` | This document. |
| `docs/superpowers/plans/2026-09-17-primary-badge-in-sidebar.md` | The plan, written by the next stage. |

No new Swift files, so nothing depends on `xcodegen generate` picking up a new source — but
`./scripts/ci.sh` runs it regardless.

## Out of scope

- Renaming `Worktree.isMain` to `isPrimary` (decision 7).
- Extracting a shared badge component from `CommandsView.KindLabel` (decision 10).
- Any badge outside the sidebar — window title, worktree toolbar, project selector (decision 8).
- Badges for any other row state (open/closed, dirty, PR status). The brief names one badge.
- The known `WorktreeGroupStore.openFileWatcher` fd leak recorded in CLAUDE.md; unrelated and
  owed its own task.
